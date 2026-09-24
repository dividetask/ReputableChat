# frozen_string_literal: true

require "roda"
require "json"
require "yaml"
require "securerandom"
require_relative "params"
require_relative "server_config"
require_relative "cryptography/signature"
require_relative "cryptography/canonical"
require_relative "cryptography/payload"
require_relative "cryptography/record"
require_relative "genesis"
require_relative "host"
require_relative "store/database"
require_relative "store/images"

module ReputableChat
  # The server does as little as it can: it verifies signatures, rejects
  # revision rollbacks, and stores signed blobs. It never sees a seed, holds a private
  # key, or computes a reputation -- reputation is subjective per viewer, so it
  # belongs on the client.
  class App < Roda
    MAX_BODY  = 4_000
    MAX_BATCH = 256

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
    ALLOWED_EMOTES = EMOTES.values_at("positive", "negative", "neutral").compact.flatten.freeze

    class << self
      # `host` is nil when this server runs without a host account.
      attr_accessor :store, :images, :origin, :genesis, :host
      attr_writer :limits

      # Defaulted rather than required, so a test or a script can build the app
      # without assembling a config first.
      def limits = @limits || ServerConfig::LIMITS
    end

    def store = self.class.store
    def images = self.class.images
    def origin = self.class.origin
    def genesis = self.class.genesis
    def host = self.class.host
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
        r.post("register")  { register(r) }
        r.post("image")     { upload_image(r) }

        # Takes no pubkey on either verb: it uses the session's, so asking for
        # somebody else's vault is not expressible through the API.
        r.on "vault" do
          r.get { own_vault(r) }
          r.put { put_vault(r) }
        end

        # The chain records.
        r.on "identity" do
          r.post("batch") { batch(r, :identities) }
          r.put { put_identity(r) }
          r.get(String) { |pubkey| fetch(:identity, pubkey) }
        end

        r.on "attestation" do
          r.post("batch") { batch(r, :attestations) }
          r.put { put_attestation(r) }
          r.get(String) { |pubkey| fetch(:attestation, pubkey) }
        end

        r.on "notice" do
          r.post { post_notice(r) }
          r.get(String) { |pubkey| fetch_notices(r, pubkey) }
        end

        r.on "adjustment" do
          r.post { post_adjustment(r) }
          r.get(String) { |pubkey| fetch_adjustments(r, pubkey) }
        end

        # No room segment: there are no rooms. When they arrive they will be
        # their own records, named by hash rather than by a name anybody can
        # claim, so a path built out of a name would have to go anyway.
        r.get("messages") { { "messages" => store.messages.map { |m| present_message(m) } } }
        r.get("emotes")   { { "emotes" => store.emotes } }
        r.post("message") { post_message(r) }
        r.post("emote")   { post_emote(r) }
      end
    end

    private

    # --- handlers ---------------------------------------------------------

    # Challenge-response. The signed payload covers the nonce, the pubkey, the
    # origin and a timestamp: without origin and purpose in there, a signature
    # harvested by one server could be replayed against another.
    def open_session(r)
      pubkey    = Params.pubkey(r.params["pubkey"])      or bad_request(r, "bad pubkey")
      signature = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      nonce     = Params.string(r.params["nonce"], max: 128) or bad_request(r, "bad nonce")
      issued_at = Params.integer(r.params["ts"])          or bad_request(r, "bad timestamp")

      fresh = (Time.now.to_i - issued_at).abs <= Store::Database::CLOCK_SKEW
      bad_request(r, "stale timestamp") unless fresh

      payload = Cryptography::Payload.login(pubkey: pubkey, nonce: nonce, origin: origin, issued_at: issued_at)

      unless Cryptography::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)
        r.halt(401, { "error" => "signature did not verify" })
      end

      # Claimed last, so a failed signature does not burn the challenge.
      r.halt(401, { "error" => "challenge expired or already used" }) unless store.claim_nonce(nonce)

      session["pubkey"] = pubkey
      user = store.user(pubkey)

      { "pubkey" => pubkey, "registered" => !user.nil? }
    end

    # A valid but unregistered seed reaches here. The client warns before
    # calling it -- a mistyped seed that happens to pass the checksum would
    # otherwise silently create a new empty account. The handle is not set
    # here; the client publishes it in its first identity declaration.
    def register(r)
      pubkey = current_pubkey(r)
      r.halt(409, { "error" => "already registered" }) if store.registered?(pubkey)

      store.register(pubkey)
      { "pubkey" => pubkey, "registered" => true }
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

    # `ack` is the record this message's signer had last seen. The server does
    # not check that it was well chosen -- it cannot, since it never computes a
    # reputation and the rule is the author's own. It checks only that it is
    # the right shape, and stores what it is given.
    # --- chain records -----------------------------------------------------

    # An identity declaration. `master_pubkey` and `previous_pubkey` are placeholders
    # for key rotation and must still be null: accepting a value for a field
    # nothing implements would let a client publish a claim the network would
    # later have to honour or explain away.
    def put_identity(r)
      pubkey  = current_pubkey(r)
      revision = Params.integer(r.params["revision"], min: 1) or bad_request(r, "bad revision")
      handle  = Params.handle(r.params["handle"])           or bad_request(r, "bad handle")
      bio     = Params.bio(r.params["bio"])                 or bad_request(r, "bad bio")
      ack     = Params.record_hash(r.params["ack"])         or bad_request(r, "bad ack")
      sig     = Params.signature(r.params["signature"])     or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"])              or bad_request(r, "bad timestamp")
      icon    = r.params["icon"].nil? ? nil : (Params.icon(r.params["icon"]) or bad_request(r, "bad icon"))

      bad_request(r, "key rotation is not implemented") if r.params["master_pubkey"] || r.params["previous_pubkey"]

      payload = Cryptography::Payload.identity(
        pubkey: pubkey, revision: revision, handle: handle, bio: bio, icon: icon,
        ack: ack, issued_at: ts, note: optional_note(r)
      )
      store_record(r, :store_identity, pubkey, revision, payload, sig)
    end

    # What somebody thinks of everyone else. The server checks the shape and
    # nothing else -- it has no opinion about whether a score is deserved, and
    # could not form one without computing a reputation.
    def put_attestation(r)
      pubkey  = current_pubkey(r)
      revision = Params.integer(r.params["revision"], min: 1) or bad_request(r, "bad revision")
      scores  = Params.scores(r.params["scores"])           or bad_request(r, "bad scores")
      derived = Params.derived(r.params["derived"])         or bad_request(r, "bad derived scores")
      ack     = Params.record_hash(r.params["ack"])         or bad_request(r, "bad ack")
      sig     = Params.signature(r.params["signature"])     or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"])              or bad_request(r, "bad timestamp")

      payload = Cryptography::Payload.attestation(
        pubkey: pubkey, revision: revision, scores: scores, derived: derived,
        ack: ack, issued_at: ts, note: optional_note(r)
      )

      # Bounded here rather than by an entry count. This is the one record whose
      # size its author chooses, and the canonical bytes are what has to be
      # stored and served back, so they are the thing to measure.
      canonical = Cryptography::Canonical.dump(payload)
      if canonical.bytesize > limit(:attestation_bytes)
        bad_request(r, "attestation is larger than #{limit(:attestation_bytes)} bytes")
      end

      store_record(r, :store_attestation, pubkey, revision, payload, sig)
    end

    def store_record(r, method, pubkey, revision, payload, signature)
      verify!(r, pubkey, signature, payload)

      canonical = Cryptography::Canonical.dump(payload)
      hash = Cryptography::Record.digest(payload: canonical, signature: signature)
      result = store.public_send(method, pubkey: pubkey, revision: revision, hash: hash,
                                         payload: canonical, signature: signature)

      r.halt(409, { "error" => "revision is not newer than the stored one" }) if result == :stale

      { "stored" => true, "revision" => revision, "hash" => hash }
    end

    # An official statement. The server checks the shape, the signature and the
    # revision, and has no opinion about the contents -- it does not know what a
    # policy is, only that this account has not used this number before.
    def post_notice(r)
      pubkey     = current_pubkey(r)
      revision   = Params.integer(r.params["revision"], min: 1) or bad_request(r, "bad revision")
      kind       = Params.notice_kind(r.params["kind"], allowed: NOTICE_KINDS) or bad_request(r, "unknown kind")
      title      = Params.title(r.params["title"])       or bad_request(r, "bad title")
      body       = Params.notice_body(r.params["body"], max: limit(:notice_bytes)) or bad_request(r, "bad body")
      ack        = Params.record_hash(r.params["ack"])   or bad_request(r, "bad ack")
      sig        = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts         = Params.integer(r.params["ts"])        or bad_request(r, "bad timestamp")
      supersedes = optional_hash(r, "supersedes")

      # The founding notice is the one that replaces nothing. Anything else
      # claiming to be one would give a chain two bottoms.
      bad_request(r, "a founding notice supersedes nothing") if kind == "founding" && supersedes

      payload = Cryptography::Payload.notice(
        pubkey: pubkey, revision: revision, kind: kind, title: title, body: body,
        ack: ack, issued_at: ts, supersedes: supersedes, note: optional_note(r)
      )
      verify!(r, pubkey, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      hash = Cryptography::Record.digest(payload: canonical, signature: sig)
      result = store.store_notice(
        hash: hash, pubkey: pubkey, revision: revision, kind: kind, title: title,
        supersedes: supersedes, ack: ack, payload: canonical, signature: sig
      )
      r.halt(409, { "error" => "that revision is already used" }) if result == :duplicate

      { "stored" => true, "revision" => revision, "hash" => hash }
    end

    def fetch_notices(r, pubkey_param)
      pubkey = Params.pubkey(pubkey_param) or bad_request(r, "bad pubkey")

      { "notices" => store.notices(pubkey).map { |row| present_notice(row) } }
    end

    # One change to an attestation between republishes. `base_revision` names
    # the snapshot it amends and `seq` its place in that run, both inside the
    # signature, so the server can neither reorder a run nor replay one against
    # a later snapshot.
    def post_adjustment(r)
      pubkey  = current_pubkey(r)
      base    = Params.integer(r.params["base_revision"], min: 1) or bad_request(r, "bad base revision")
      seq     = Params.integer(r.params["seq"], min: 1)          or bad_request(r, "bad seq")
      target  = Params.pubkey(r.params["target"])                or bad_request(r, "bad target")
      score   = Params.decimal(r.params["reputation"])           or bad_request(r, "bad reputation")
      trust   = Params.decimal(r.params["trust"])                or bad_request(r, "bad trust")
      ack     = Params.record_hash(r.params["ack"])              or bad_request(r, "bad ack")
      sig     = Params.signature(r.params["signature"])          or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"])                   or bad_request(r, "bad timestamp")

      bad_request(r, "an adjustment cannot be about its own author") if target == pubkey

      payload = Cryptography::Payload.adjustment(
        pubkey: pubkey, base_revision: base, seq: seq, target: target,
        reputation: score, trust: trust, ack: ack, issued_at: ts, note: optional_note(r)
      )
      verify!(r, pubkey, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      hash = Cryptography::Record.digest(payload: canonical, signature: sig)
      result = store.store_adjustment(
        hash: hash, pubkey: pubkey, base_revision: base, seq: seq, target: target,
        ack: ack, payload: canonical, signature: sig
      )
      r.halt(409, { "error" => "that adjustment already exists" }) if result == :duplicate

      { "stored" => true, "seq" => seq, "hash" => hash }
    end

    # Only the run amending the snapshot the caller holds. An adjustment
    # against an older revision was superseded by the republish that followed.
    def fetch_adjustments(r, pubkey_param)
      pubkey = Params.pubkey(pubkey_param) or bad_request(r, "bad pubkey")
      base = Params.integer(r.params["base_revision"], min: 1) or bad_request(r, "bad base revision")

      { "adjustments" => store.adjustments_for(pubkey, base_revision: base).map { |row| present_adjustment(row) } }
    end

    def fetch(kind, pubkey_param)
      pubkey = Params.pubkey(pubkey_param)
      return { kind.to_s => nil } unless pubkey

      { kind.to_s => present_record(store.public_send(kind, pubkey)) }
    end

    def batch(r, kind)
      pubkeys = Params.array_of(r.params["pubkeys"], max: MAX_BATCH) { |v| Params.pubkey(v) }
      bad_request(r, "bad pubkeys") unless pubkeys

      { kind.to_s => store.public_send(kind, pubkeys).map { |row| present_record(row) } }
    end

    def post_message(r)
      pubkey = current_pubkey(r)
      body   = Params.string(r.params["body"], max: limit(:message_bytes)) or bad_request(r, "bad body")
      sig    = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts     = Params.integer(r.params["ts"]) or bad_request(r, "bad timestamp")
      ack    = Params.record_hash(r.params["ack"]) or bad_request(r, "bad ack")
      reply  = optional_hash(r, "reply_to")

      payload = Cryptography::Payload.message(
        pubkey: pubkey, body: body,
        ack: ack, issued_at: ts, reply_to: reply, note: optional_note(r)
      )
      verify!(r, pubkey, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      hash = Cryptography::Record.digest(payload: canonical, signature: sig)
      result = store.store_message(
        hash: hash, pubkey: pubkey, ack: ack,
        reply_to: reply, payload: canonical, signature: sig
      )
      # The record hash is what catches a repeat now that there is no sequence
      # number: the identical record, signature and all, has been sent twice.
      r.halt(409, { "error" => "that record has already been stored" }) if result == :duplicate

      { "stored" => true, "hash" => hash }
    end

    def post_emote(r)
      pubkey  = current_pubkey(r)
      message = Params.record_hash(r.params["message"]) or bad_request(r, "bad message")
      choice  = Params.emote(r.params["emote"], allowed: ALLOWED_EMOTES) or bad_request(r, "unknown emote")
      sig     = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"]) or bad_request(r, "bad timestamp")
      ack     = Params.record_hash(r.params["ack"]) or bad_request(r, "bad ack")

      payload = Cryptography::Payload.emote(
        pubkey: pubkey, message: message, emote: choice,
        ack: ack, issued_at: ts, note: optional_note(r)
      )
      verify!(r, pubkey, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      result = store.store_emote(
        hash: Cryptography::Record.digest(payload: canonical, signature: sig),
        pubkey: pubkey, message: message, emote: choice,
        ack: ack, payload: canonical, signature: sig
      )
      r.halt(409, { "error" => "you have already reacted to that message" }) if result == :duplicate

      { "stored" => true }
    end

    # --- helpers ----------------------------------------------------------

    def verify!(r, pubkey, signature, payload)
      return if Cryptography::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)

      r.halt(400, { "error" => "signature did not verify" })
    end

    def current_pubkey(r)
      pubkey = Params.pubkey(session["pubkey"])
      r.halt(401, { "error" => "not signed in" }) unless pubkey

      pubkey
    end

    def bad_request(r, message)
      r.halt(400, { "error" => message })
    end

    # Absent is fine, present but malformed is not -- silently dropping a bad
    # reference would store a record whose signature covers something the
    # server never saw.
    def optional_hash(r, field)
      return nil if r.params[field].nil?

      Params.record_hash(r.params[field]) or bad_request(r, "bad #{field}")
    end

    # Same reasoning: a note too long or full of control characters is a
    # rejection, not something to quietly drop out of a signed payload.
    def optional_note(r)
      return nil if r.params["note"].nil? || r.params["note"].to_s.strip.empty?

      Params.note(r.params["note"], max: limit(:note_bytes)) or bad_request(r, "bad note")
    end

    # Signed blobs go out exactly as they came in, with the record hash the
    # server derived from them. A reader re-derives it from the same two
    # strings, so a server that invented one would be caught.
    def present_record(row)
      return nil unless row

      { "pubkey" => row[:pubkey], "revision" => row[:revision], "hash" => row[:hash],
        "payload" => row[:payload], "signature" => row[:signature] }.compact
    end

    def present_notice(row)
      { "pubkey" => row[:pubkey], "revision" => row[:revision], "kind" => row[:kind],
        "title" => row[:title], "supersedes" => row[:supersedes], "hash" => row[:hash],
        "payload" => row[:payload], "signature" => row[:signature] }
    end

    # An adjustment has no revision of its own -- it has the snapshot it amends
    # and its place in that run, which is what a reader replays it by.
    def present_adjustment(row)
      { "pubkey" => row[:pubkey], "base_revision" => row[:base_revision], "seq" => row[:seq],
        "target" => row[:target], "hash" => row[:hash], "payload" => row[:payload],
        "signature" => row[:signature] }
    end

    def present_message(row)
      { "hash" => row[:hash], "pubkey" => row[:pubkey],
        "reply_to" => row[:reply_to], "ack" => row[:ack],
        "payload" => row[:payload], "signature" => row[:signature],
        "received_at" => row[:received_at] }
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
