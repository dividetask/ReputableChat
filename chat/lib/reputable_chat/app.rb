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
require_relative "chain/book"
require_relative "genesis"
require_relative "host"
require_relative "store/database"
require_relative "store/images"

module ReputableChat
  # The server does as little as it can: it judges records against the rules,
  # stores the ones that are valid, and serves them back byte-identical. It
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
      # `host` is nil when this server runs without a host account. `book` is
      # the chain: the records this server holds, and the ledger judging them.
      attr_accessor :store, :images, :genesis, :host, :book
      attr_writer :limits, :origins, :peer_tokens

      # Defaulted rather than required, so a test or a script can build the app
      # without assembling a config first.
      def limits = @limits || ServerConfig::LIMITS

      # The origins a login may be signed for. Empty means whichever origin the
      # request arrived at -- see Origin.
      def origins = @origins || []

      # Bearer tokens other servers present to pass records on. Empty closes
      # the route.
      def peer_tokens = @peer_tokens || []
    end

    def store = self.class.store
    def images = self.class.images
    def origins = self.class.origins
    def genesis = self.class.genesis
    def host = self.class.host
    def book = self.class.book
    def ledger = (@ledger ||= book.ledger)
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
      r.get("images", String) { |name| serve_image(name) }

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
        # and the signature -- and the server judges it against the rules.
        r.post("record") { post_record(r) }
        # Any record, by its hash, to anyone: walking the chain back to the
        # genesis passes through records whose authors a viewer would never
        # display, so resolution cannot depend on who is asking.
        r.get("record", String) { |hash| fetch_record(hash) }

        # Other servers passing records on. Any valid record of any type.
        r.post("peer", "records") { peer_records(r) }

        r.on "identity" do
          r.post("batch") { batch(r, :declaration, "identities") }
          r.get(String) { |account| { "identity" => present_record(latest(:declaration, account)) } }
        end

        r.on "attestation" do
          r.post("batch") { batch(r, :attestation, "attestations") }
          r.get(String) { |account| { "attestation" => present_record(latest(:attestation, account)) } }
        end

        r.get("notices", String) { |account| fetch_notices(account) }
        r.get("messages") { { "messages" => chat(:message, MESSAGES).map { |rec| present_record(rec) } } }
        r.get("reactions") { { "reactions" => chat(:reaction, REACTIONS).map { |rec| present_reaction(rec) } } }
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
      account = ledger.account_for(pubkey)
      session["account"] = account

      { "pubkey" => pubkey, "account" => account, "registered" => !account.nil?,
        "latest" => account && ledger.records_of(account).last&.record_hash }
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

    # A record from one of this server's own clients. Held to the rules, and
    # then to this server's stricter terms: only the records the chat makes,
    # signed by the session's own key for the session's own account, within
    # the limits in config/server.yml.
    def post_record(r)
      pubkey = current_pubkey(r)
      record = parse_record(r, r.params)

      unless record.signers.include?(["pubkey", pubkey])
        bad_request(r, "a record sent from this session is signed with the session's key, carried as pubkey")
      end

      account = session["account"]
      if record.first_declaration?
        bad_request(r, "this session already has an account, #{account}") if account
      elsif record.account != account
        bad_request(r, account ? "that record is not this session's account's" : "this key has no account yet; declare one first")
      end

      client_terms!(r, record)
      result = judge(r, record)
      r.halt(409, { "error" => "that record has already been stored" }) if result == :duplicate

      session["account"] = record.record_hash if record.first_declaration?
      { "stored" => true, "hash" => record.record_hash, "account" => record.account }
    end

    CLIENT_KINDS = %w[identity attestation message reaction notice].freeze

    def client_terms!(r, record)
      refuse = ->(message) { bad_request(r, message) }

      refuse.call("this server takes #{CLIENT_KINDS.join(', ')} records from its clients, not #{record.kind}") unless
        CLIENT_KINDS.include?(record.kind)
      if %w[message reaction].include?(record.kind) && !record.app?(Cryptography::Payload::CHAT)
        refuse.call("this server takes messages and reactions for the chat, typed #{Cryptography::Payload.type(record.kind, 'chat')}")
      end
      %w[transfer endorse adjudicators].each do |field|
        refuse.call("this server does not take #{field} from its clients") if record.fields.key?(field)
      end
      if (Time.now.to_i - record["ts"]).abs > CLIENT_CLOCK_SKEW
        refuse.call("ts is more than #{CLIENT_CLOCK_SKEW} seconds from this server's clock")
      end

      body = record["body"]
      case record.kind
      when "identity"
        refuse.call("a bio is at most #{limit(:bio_bytes)} bytes") if body.bytesize > limit(:bio_bytes)
        files = record["file"] || []
        refuse.call("an identity declaration names one file, the avatar") if files.size > 1
        refuse.call("an avatar is an image this server stores") if files.any? { |f| !f.match?(AVATAR) }
      when "message", "reaction"
        refuse.call("#{record.kind} body is empty") if body.empty?
        refuse.call("#{record.kind} body is over #{limit(:message_bytes)} bytes") if body.bytesize > limit(:message_bytes)
      when "attestation"
        refuse.call("attestation is larger than #{limit(:attestation_bytes)} bytes") if
          record.payload.bytesize > limit(:attestation_bytes)
      when "notice"
        refuse.call("unknown notice kind #{record['kind'].inspect}") unless NOTICE_KINDS.include?(record["kind"])
        refuse.call("notice body is over #{limit(:notice_bytes)} bytes") if body.bytesize > limit(:notice_bytes)
      end
    end

    # Records another server passes on: any valid record, in the order given,
    # so a record can arrive after what it acknowledges in the same request.
    def peer_records(r)
      token = r.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer (.+)\z/, 1]
      r.halt(404, { "error" => "this server takes no records from other servers" }) if self.class.peer_tokens.empty?
      r.halt(401, { "error" => "not a peer of this server" }) unless
        token && self.class.peer_tokens.any? { |t| Rack::Utils.secure_compare(t, token) }

      list = r.params["records"]
      bad_request(r, "records is a list of at most #{MAX_BATCH}") unless list.is_a?(Array) && list.size <= MAX_BATCH

      { "results" => list.map { |entry| peer_record(entry) } }
    end

    def peer_record(entry)
      record = Chain::Record.parse(entry.is_a?(Hash) ? entry["payload"] : nil, entry.is_a?(Hash) ? entry["signature"] : nil)
      result = book.add(record)
      { "hash" => record.record_hash, "stored" => result == :ok, "duplicate" => result == :duplicate }
    rescue Chain::Invalid => e
      { "hash" => record&.record_hash, "stored" => false, "error" => e.message,
        "unknown" => e.is_a?(Chain::Ledger::Unknown) }
    end

    def parse_record(r, params)
      payload = params["payload"]
      signature = params["signature"]
      bad_request(r, "payload is the record's canonical JSON, as a string") unless payload.is_a?(String)
      bad_request(r, "signature is required") unless signature.is_a?(String)

      Chain::Record.parse(payload, signature)
    rescue Chain::Invalid => e
      bad_request(r, e.message)
    end

    def judge(r, record)
      book.add(record)
    rescue Chain::Ledger::Unknown => e
      r.halt(409, { "error" => e.message })
    rescue Chain::Invalid => e
      bad_request(r, e.message)
    end

    def fetch_record(hash)
      return { "record" => nil } unless Params.record_hash(hash)

      { "record" => present_record(ledger[hash]) }
    end

    def latest(kind, account)
      return nil unless Params.record_hash(account)

      ledger.public_send(kind, account)
    end

    def batch(r, kind, name)
      accounts = Params.array_of(r.params["accounts"], max: MAX_BATCH) { |v| Params.record_hash(v) }
      bad_request(r, "bad accounts") unless accounts

      { name => accounts.filter_map { |account| present_record(ledger.public_send(kind, account)) } }
    end

    # Newest first, every kind: a client shows the kinds it knows.
    def fetch_notices(account)
      return { "notices" => [] } unless Params.record_hash(account)

      notices = ledger.records_of(account).select { |rec| rec.kind == "notice" }.last(100).reverse
      { "notices" => notices.map { |rec| present_record(rec) } }
    end

    # The latest records of one type made for the chat, oldest first.
    def chat(kind, limit)
      found = []
      ledger.records.reverse_each do |rec|
        next unless rec.kind == kind.to_s && rec.app?(Cryptography::Payload::CHAT)

        found << rec
        break if found.size >= limit
      end
      found.reverse
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

    # Signed blobs go out exactly as they came in, with the record hash the
    # server derived from them. A reader re-derives it from the same two
    # strings, so a server that invented one would be caught. `state` is the
    # server's reading of section 1 -- valid, tentative, disputed, confirmed or
    # void -- as seen by everything it holds, and is not part of the record.
    def present_record(rec)
      return nil unless rec

      { "hash" => rec.record_hash, "account" => rec.account, "payload" => rec.payload,
        "signature" => rec.signature, "state" => ledger.state(rec.record_hash) }
    end

    # What a client needs to count a reaction, without parsing every payload.
    def present_reaction(rec)
      { "hash" => rec.record_hash, "account" => rec.account, "target" => rec.targets,
        "body" => rec["body"], "state" => ledger.state(rec.record_hash) }
    end

    # Content-addressed, so the bytes can never change under a given name.
    def serve_image(name)
      bytes = images.read(name) or response.status = 404
      return "" unless bytes

      response["Content-Type"] = images.content_type(name)
      response["Cache-Control"] = "public, max-age=31536000, immutable"
      bytes
    end

    def serve_wordlist
      response["Content-Type"] = "text/plain; charset=utf-8"
      response["Cache-Control"] = "public, max-age=31536000, immutable"
      File.read(File.join(opts[:root], "config", "bip39-english.txt"))
    end

    def serve_index
      response["Content-Type"] = "text/html; charset=utf-8"
      File.read(File.join(opts[:root], "public", "index.html"))
    end
  end
end
