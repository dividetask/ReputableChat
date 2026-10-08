# frozen_string_literal: true

require "roda"
require "json"
require "yaml"
require "securerandom"
require_relative "params"
require_relative "server_config"
require_relative "origin"
require_relative "cryptography/signature"
require_relative "cryptography/canonical"
require_relative "cryptography/payload"
require_relative "cryptography/seed"
require_relative "chain/mirror"
require_relative "chain/connection"
require_relative "chain/service"
require_relative "file_peers"
require_relative "chain_client"
require_relative "genesis"
require_relative "host"
require_relative "store/database"
require_relative "store/images"

module ReputableChat
  # The server does as little as it can. The chain is its agnostic server's:
  # that judges every record against the rules, stores it and syncs it. This
  # signs people in, keeps their vaults and images, holds its own clients to
  # its own terms, and keeps a copy of the records the chat shows. It
  # never sees a seed, holds a private key, or computes a reputation --
  # reputation is subjective per viewer, so it belongs on the client.
  class App < Roda
    MAX_BATCH = 256
    # How far a record's own timestamp may be from this server's clock when one
    # of its clients sends it. The rules verify ts only between heartbeats; this
    # is the guideline that servers refuse records whose ts is far from theirs.
    CLIENT_CLOCK_SKEW = 3_600
    MESSAGES  = 100
    REACTIONS = 5_000

    opts[:root] = File.expand_path("../..", __dir__)

    plugin :json, classes: [Array, Hash]
    # The narrow content-type match matters: the permissive default would let a
    # cross-origin form post (which cannot set an exotic content type) reach a
    # JSON handler.
    plugin :json_parser,
           content_type_regexp: %r{\Aapplication/json\b}i,
           error_handler: ->(r) { r.halt(400, '{"error":"malformed json"}') }
    plugin :halt
    plugin :all_verbs
    # "no-cache" means cache but always revalidate, not "do not cache" -- an
    # unchanged file still answers 304. Without it browsers fall back to
    # heuristic caching and cache each module independently, so a deploy can
    # leave someone running a new app.js against a stale session.js. For signed
    # payloads that is the silent-failure case: mismatched shapes produce
    # signature errors with no obvious cause.
    plugin :public, root: "public", headers: { "Cache-Control" => "no-cache" }
    plugin :default_headers,
           "Content-Type" => "application/json",
           "X-Content-Type-Options" => "nosniff",
           "X-Frame-Options" => "DENY",
           "Referrer-Policy" => "no-referrer",
           # The private key lives in this origin's IndexedDB, so the origin
           # boundary is what keeps other sites away from it. A strict CSP is
           # what keeps injected script inside this origin from using it.
           "Content-Security-Policy" => [
             "default-src 'self'", "script-src 'self' 'wasm-unsafe-eval'",
             "style-src 'self'", "img-src 'self' data:", "connect-src 'self'",
             "object-src 'none'", "base-uri 'none'", "frame-ancestors 'none'"
           ].join("; ")

    plugin :sessions,
           key: "_reputablechat",
           secret: ENV.fetch("SESSION_SECRET") { SecureRandom.hex(64) },
           cookie_options: { same_site: :strict, http_only: true, secure: ENV["RACK_ENV"] == "production" }

    # Loaded once at require time rather than memoized on first request:
    # config.ru freezes the app class, and a lazy `@defaults ||=` raises
    # FrozenError on the first real request while passing every unfrozen test.
    DEFAULTS = YAML.safe_load_file(File.join(opts[:root], "config", "reputation.yml")).freeze
    EMOTES   = YAML.safe_load_file(File.join(opts[:root], "config", "emotes.yml")).freeze
    NOTICES  = YAML.safe_load_file(File.join(opts[:root], "config", "notices.yml")).freeze
    NOTICE_KINDS = NOTICES.fetch("kinds").freeze
    # The image types a client may name as its avatar: those the image store
    # serves. The rules allow any extension; this server is stricter with its
    # own clients.
    AVATAR = /\A[0-9a-f]{64}\.(png|jpg|gif|webp)\z/

    class << self
      # `host` is nil when this server runs without a host account. `chain`
      # is the agnostic server (a ChainClient), and `mirror` the chat's copy
      # of the records it shows.
      attr_accessor :store, :images, :genesis, :host, :chain, :mirror, :files
      attr_writer :limits, :origins

      # Defaulted rather than required, so a test or a script can build the app
      # without assembling a config first.
      def limits = @limits || ServerConfig::LIMITS

      # The origins a login may be signed for. Empty means whichever origin the
      # request arrived at -- see Origin.
      def origins = @origins || []
    end

    def store = self.class.store
    def images = self.class.images
    def origins = self.class.origins
    def genesis = self.class.genesis
    def host = self.class.host
    def chain = self.class.chain
    def mirror = self.class.mirror
    def files = self.class.files
    def limits = self.class.limits
    def limit(name) = limits.fetch(name.to_s)

    route do |r|
      r.public

      r.root { serve_index }
      # The same page: the client picks the screen from the path, so a direct
      # visit or a refresh on /new-account works rather than 404ing.
      r.get("new-account") { serve_index }

      # Served from config/ rather than copied into public/ so the wordlist has
      # exactly one source of truth shared with the Ruby reference.
      r.get("wordlist.txt") { serve_wordlist }
      r.get("images", String) { |name| serve_image(r, name) }

      r.on "api" do
        r.post("challenge") { { "nonce" => store.issue_nonce } }

        # The client does the reputation maths, so it needs the parameters.
        # Serving them (rather than baking them into the JS) is what lets a
        # default change reach every user who never pinned that setting.
        r.get("defaults") { DEFAULTS }
        r.get("emote-kinds") { EMOTES }
        # The kinds a client has to be able to render, served for the same
        # reason the emotes are: baking them into the JS means a new kind
        # cannot reach anyone already running an old copy.
        r.get("notice-kinds") { NOTICES }
        # Served so a client knows the ceilings before it tries to save,
        # rather than discovering them by being refused. `seen_entries` is
        # advice: nothing rejects a vault for exceeding it, but a client that
        # ignores it will eventually write one too large to store.
        r.get("limits") { limits }
        # The bottom of the chain. Served so a client can check the hash it
        # was built with against the one this server is running, rather than
        # discovering a mismatch as signatures that will not verify.
        r.get("genesis")  { genesis.to_h }
        # This server's own account, or null. Served beside the genesis so a new
        # account can start with both as friends before it has fetched anything else.
        r.get("host")     { { "host" => host&.to_h } }
        r.post("session")   { open_session(r) }
        r.post("image")     { upload_image(r) }

        # Takes no pubkey on either verb: it uses the session's, so asking for
        # somebody else's vault is not expressible through the API.
        r.on "vault" do
          r.get { own_vault(r) }
          r.put { put_vault(r) }
        end

        # The chain. A record is sent whole -- the payload exactly as signed,
        # and the signature -- and passed to the agnostic server, which judges
        # it against the rules.
        r.post("record") { post_record(r) }
        # Any record, by its hash, to anyone: walking the chain back to the
        # genesis passes through records whose authors a viewer would never
        # display, so resolution cannot depend on who is asking.
        r.get("record", String) { |hash| fetch_record(hash) }

        r.on "identity" do
          r.post("batch") { batch(r, "declaration", "identities") }
          r.get(String) { |account| { "identity" => newest(account, "declaration") } }
        end

        r.on "attestation" do
          r.post("batch") { batch(r, "attestation", "attestations") }
          r.get(String) { |account| { "attestation" => newest(account, "attestation") } }
        end

        r.get("notices", String) { |account| fetch_notices(account) }
        r.get("messages") { { "messages" => with_states(mirror.chat(:message, MESSAGES)) } }
        r.get("reactions") { { "reactions" => with_states(mirror.chat(:reaction, REACTIONS)).map { |rec| as_reaction(rec) } } }
      end
    end

    private

    # --- handlers ---------------------------------------------------------

    # Challenge-response. The signed payload covers the nonce, the pubkey, the
    # origin and a timestamp. The nonce is what stops a signature harvested by
    # one server being replayed against another; the origin also stops a live
    # relay, but only when the operator has listed the server's origins (see
    # Origin for why that is optional).
    def open_session(r)
      pubkey    = Params.pubkey(r.params["pubkey"])      or bad_request(r, "bad pubkey")
      signature = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      nonce     = Params.string(r.params["nonce"], max: 128) or bad_request(r, "bad nonce")
      issued_at = Params.integer(r.params["ts"])          or bad_request(r, "bad timestamp")

      fresh = (Time.now.to_i - issued_at).abs <= Store::Database::CLOCK_SKEW
      bad_request(r, "stale timestamp") unless fresh

      verified = login_origins(r).any? do |origin|
        payload = Cryptography::Payload.login(pubkey: pubkey, nonce: nonce, origin: origin, issued_at: issued_at)
        Cryptography::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)
      end
      r.halt(401, { "error" => login_failure(r) }) unless verified

      # Claimed last, so a failed signature does not burn the challenge.
      r.halt(401, { "error" => "challenge expired or already used" }) unless store.claim_nonce(nonce)

      session["pubkey"] = pubkey
      account = chain.account_for(pubkey)
      session["account"] = account

      { "pubkey" => pubkey, "account" => account, "registered" => !account.nil?,
        "latest" => account && chain.account(account)&.fetch("latest") }
    end

    # The filename is derived from a SHA-256 of the bytes, and the type is
    # sniffed from them, so nothing a client claims about an upload is trusted.
    def upload_image(r)
      declared = r.env["CONTENT_LENGTH"].to_i
      r.halt(413, { "error" => "image too large" }) if declared > images.max_bytes

      case (result = images.store(r.body.read))
      when :too_large   then r.halt(413, { "error" => "image too large" })
      when :unsupported then bad_request(r, "unsupported image type")
      else { "icon" => result }
      end
    end

    def own_vault(r)
      row = store.vault(current_pubkey(r))
      return { "vault" => nil } unless row

      { "vault" => { "revision" => row[:revision], "payload" => row[:payload],
                     "signature" => row[:signature] } }
    end

    # The server verifies the signature over the ciphertext and rejects a
    # rollback, and that is everything it can do. It cannot read the contents,
    # so it cannot check their shape -- the byte bound on the ciphertext is the
    # only limit it has.
    def put_vault(r)
      pubkey     = current_pubkey(r)
      revision   = Params.integer(r.params["revision"], min: 1) or bad_request(r, "bad revision")
      ciphertext = Params.sealed(r.params["ciphertext"], max: limit(:vault_bytes)) or bad_request(r, "bad ciphertext")
      iv         = Params.iv(r.params["iv"])                     or bad_request(r, "bad iv")
      sig        = Params.signature(r.params["signature"])       or bad_request(r, "bad signature")
      ts         = Params.integer(r.params["ts"])                or bad_request(r, "bad timestamp")

      payload = Cryptography::Payload.vault(
        pubkey: pubkey, revision: revision, ciphertext: ciphertext, iv: iv, issued_at: ts
      )
      verify!(r, pubkey, sig, payload)

      result = store.store_vault(
        pubkey: pubkey, revision: revision,
        payload: Cryptography::Canonical.dump(payload), signature: sig
      )
      r.halt(409, { "error" => "revision is not newer than the stored one" }) if result == :stale

      { "stored" => true, "revision" => revision }
    end

    # --- chain records -----------------------------------------------------

    # A record from one of this server's own clients. This server's terms
    # first -- signed by the session's own key for the session's own account,
    # a record the chat keeps, timestamped near this server's clock, within
    # the limits in config/server.yml -- and then the agnostic server, which
    # judges it against the rules and stores it, or says why not.
    def post_record(r)
      pubkey = current_pubkey(r)
      record = parse_record(r, r.params)

      unless record["pubkey"] == pubkey &&
             Cryptography::Signature.verify(pubkey_b64: pubkey, signature_b64: record.signature, payload: record.fields)
        bad_request(r, "a record sent from this session is signed with the session's key, carried as pubkey")
      end

      account = session["account"]
      if record.first_declaration?
        bad_request(r, "this session already has an account, #{account}") if account
      elsif record.account != account
        bad_request(r, account ? "that record is not this session's account's" : "this key has no account yet; declare one first")
      end

      client_terms!(r, record)
      submit!(r, record)

      session["account"] = record.record_hash if record.first_declaration?
      { "stored" => true, "hash" => record.record_hash, "account" => record.account }
    end

    # The largest integer JavaScript reads exactly, as the agnostic server
    # holds every record to.
    MAX_INTEGER = (2**53) - 1

    def client_terms!(r, record)
      refuse = ->(message) { bad_request(r, message) }

      unless record.relevant?(NOTICE_KINDS)
        refuse.call("this server takes records about the chain and the chat's own records, typed " \
                    "#{Cryptography::Payload.type('message', 'chat')} and the like; not #{record['type'].inspect}")
      end
      refuse.call("ts is not an integer") unless record["ts"].is_a?(Integer)
      if (Time.now.to_i - record["ts"]).abs > CLIENT_CLOCK_SKEW
        refuse.call("ts is more than #{CLIENT_CLOCK_SKEW} seconds from this server's clock")
      end
      refuse.call("the record holds an integer beyond #{MAX_INTEGER}") if beyond?(record.fields)

      body = record["body"].to_s
      case record.kind
      when "identity"
        refuse.call("a bio is at most #{limit(:bio_bytes)} bytes") if body.bytesize > limit(:bio_bytes)
        files = Array(record["file"])
        refuse.call("an identity declaration names one file, the avatar") if files.size > 1
        refuse.call("an avatar is an image this server stores") if files.any? { |f| !f.to_s.match?(AVATAR) }
      when "message", "reaction"
        refuse.call("#{record.kind} body is empty") if body.empty?
        refuse.call("#{record.kind} body is over #{limit(:message_bytes)} bytes") if body.bytesize > limit(:message_bytes)
      when "attestation"
        refuse.call("attestation is larger than #{limit(:attestation_bytes)} bytes") if
          record.payload.bytesize > limit(:attestation_bytes)
      when "notice"
        refuse.call("a chat server announces itself; its clients do not") if record.service?
        refuse.call("notice body is over #{limit(:notice_bytes)} bytes") if body.bytesize > limit(:notice_bytes)
      end
    end

    def beyond?(value)
      case value
      when Integer then value.abs > MAX_INTEGER
      when Hash then value.each_value.any? { |v| beyond?(v) }
      when Array then value.any? { |v| beyond?(v) }
      else false
      end
    end

    def parse_record(r, params)
      Chain::Envelope.parse(params["payload"], params["signature"])
    rescue Chain::Envelope::Unreadable => e
      bad_request(r, e.message)
    end

    # The agnostic server's verdict, passed on: refused with the rules the
    # record breaks, a conflict when it is already held or waits on records
    # the chain does not have yet.
    def submit!(r, record)
      result = chain.submit(record.payload, record.signature)
      case result.status
      when "accepted" then mirror.sync
      when "known" then r.halt(409, { "error" => "that record has already been stored" })
      when "pending"
        r.halt(409, { "error" => "the chain does not hold #{result.missing.map { |h| h[0, 12] }.join(', ')}, " \
                                 "which this record acknowledges; send it first" })
      else bad_request(r, result.problems.join("; "))
      end
    end

    def fetch_record(hash)
      return { "record" => nil } unless Params.record_hash(hash)

      wire = chain.record(hash)
      { "record" => wire && present(wire, wire["state"]) }
    end

    # An account's newest declaration or attestation, as the agnostic server
    # judges newest.
    def newest(account, which)
      return nil unless Params.record_hash(account)

      wire = chain.account(account)&.fetch(which)
      wire && with_states([wire]).first
    end

    def batch(r, which, name)
      accounts = Params.array_of(r.params["accounts"], max: MAX_BATCH) { |v| Params.record_hash(v) }
      bad_request(r, "bad accounts") unless accounts

      { name => with_states(chain.accounts(accounts).filter_map { |summary| summary[which] }) }
    end

    # Newest first, every kind the chat keeps: a client shows the kinds it knows.
    def fetch_notices(account)
      return { "notices" => [] } unless Params.record_hash(account)

      { "notices" => with_states(mirror.notices(account)) }
    end

    # --- helpers ----------------------------------------------------------

    def verify!(r, pubkey, signature, payload)
      return if Cryptography::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)

      r.halt(400, { "error" => "signature did not verify" })
    end

    # Configured origins when there are any; otherwise the one this request
    # arrived at, so a server needs no configuration to run at a new address.
    def login_origins(r)
      return origins unless origins.empty?

      [Origin.from_request(r)].compact
    end

    # A signature for the wrong origin is indistinguishable from a bad one, but
    # the browser's Origin header usually says which it was. It only chooses
    # the wording of the error; nothing is accepted because of it.
    def login_failure(r)
      browser = Origin.normalize(r.get_header("HTTP_ORIGIN"))
      expected = login_origins(r)
      return "signature did not verify" if browser.nil? || expected.include?(browser)

      fix = if origins.empty?
              "If a reverse proxy is in front, it must pass Host and X-Forwarded-Proto."
            else
              "Use that address, or add this one to ORIGIN on the server."
            end
      "signature did not verify: this server signs in at #{expected.join(' or ')}, " \
        "but this page is at #{browser}. #{fix}"
    end

    def current_pubkey(r)
      pubkey = Params.pubkey(session["pubkey"])
      r.halt(401, { "error" => "not signed in" }) unless pubkey

      pubkey
    end

    def bad_request(r, message)
      r.halt(400, { "error" => message })
    end

    # Signed blobs go out exactly as they came in, with the record hash. A
    # reader re-derives it from the same two strings, so a server that
    # invented one would be caught. `state` is the agnostic server's reading
    # of section 1 -- valid, tentative, disputed, confirmed or void -- as seen
    # by everything it holds, and is not part of the record. Asked for each
    # time, since a record's state moves as other records arrive.
    def with_states(records)
      wires = records.map { |rec| rec.is_a?(Hash) && rec.key?("payload") ? rec : { "payload" => rec[:payload], "signature" => rec[:signature] } }
      envelopes = wires.map { |w| Chain::Envelope.parse(w["payload"], w["signature"]) }
      states = chain.states(envelopes.map(&:record_hash))
      envelopes.map { |e| present_envelope(e, states[e.record_hash]) }
    end

    def present(wire, state) = present_envelope(Chain::Envelope.parse(wire["payload"], wire["signature"]), state)

    def present_envelope(envelope, state)
      { "hash" => envelope.record_hash, "account" => envelope.account, "payload" => envelope.payload,
        "signature" => envelope.signature, "state" => state }
    end

    # What a client needs to count a reaction, without parsing every payload.
    def as_reaction(presented)
      payload = JSON.parse(presented["payload"])
      presented.slice("hash", "account", "state").merge("target" => Array(payload["target"]), "body" => payload["body"])
    end

    # Content-addressed, so the bytes can never change under a given name.
    # One this server lacks is asked of the other chat servers (FilePeers) --
    # unless another chat server is the one asking, which is answered from
    # what is here so that two servers cannot ask each other in circles.
    def serve_image(r, name)
      bytes = images.read(name)
      if bytes.nil? && files && Store::Images::NAME.match?(name) && !r.get_header("HTTP_X_REPUTABLECHAT_PEER")
        bytes = files.fetch(name) && images.read(name)
      end
      response.status = 404 unless bytes
      return "" unless bytes

      response["Content-Type"] = images.content_type(name)
      response["Cache-Control"] = "public, max-age=31536000, immutable"
      bytes
    end

    def serve_wordlist
      response["Content-Type"] = "text/plain; charset=utf-8"
      response["Cache-Control"] = "public, max-age=31536000, immutable"
      File.read(Cryptography::Seed::WORDLIST_PATH)
    end

    def serve_index
      response["Content-Type"] = "text/html; charset=utf-8"
      File.read(File.join(opts[:root], "public", "index.html"))
    end
  end
end
