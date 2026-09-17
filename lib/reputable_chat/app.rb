# frozen_string_literal: true

require "roda"
require "json"
require "yaml"
require "securerandom"
require_relative "params"
require_relative "crypto/signature"
require_relative "crypto/canonical"
require_relative "crypto/payload"
require_relative "store/database"

module ReputableChat
  # The server does as little as it can.
  #
  # It never sees a seed, never holds a private key, and never computes a
  # reputation -- reputation is subjective per viewer, so it belongs on the
  # client, which fetches signed configs and does the maths itself. What the
  # server does do is verify every signature before storing anything, reject
  # rollbacks, and hand out single-use login challenges.
  class App < Roda
    MAX_USERNAME = 64
    MAX_BODY     = 4_000
    MAX_BATCH    = 256

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
    plugin :public, root: "public"
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

    class << self
      attr_accessor :store, :origin
    end

    def store = self.class.store
    def origin = self.class.origin

    route do |r|
      r.public

      r.root { serve_index }

      # Served from config/ rather than copied into public/ so the wordlist has
      # exactly one source of truth shared with the Ruby reference.
      r.get("wordlist.txt") { serve_wordlist }

      r.on "api" do
        r.post("challenge") { { "nonce" => store.issue_nonce } }

        # The client does the reputation maths, so it needs the parameters.
        # Serving them (rather than baking them into the JS) is what lets a
        # default change reach every user who never pinned that setting.
        r.get("defaults") { DEFAULTS }
        r.get("emotes")   { EMOTES }
        r.post("session")   { open_session(r) }
        r.post("register")  { register(r) }

        r.on "config" do
          r.post("batch") { config_batch(r) }
          r.put { store_config(r) }
          r.get(String) { |pubkey| fetch_config(pubkey) }
        end

        r.on "room", String do |room_name|
          room = Params.room(room_name) or bad_request(r, "bad room")

          r.get("messages") { { "messages" => store.room_messages(room).map { |m| present_message(m) } } }
          r.post("message") { post_message(r, room) }
        end
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

      payload = Crypto::Payload.login(pubkey: pubkey, nonce: nonce, origin: origin, issued_at: issued_at)

      unless Crypto::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)
        r.halt(401, { "error" => "signature did not verify" })
      end

      # Claimed last, so a failed signature does not burn the challenge.
      r.halt(401, { "error" => "challenge expired or already used" }) unless store.claim_nonce(nonce)

      session["pubkey"] = pubkey
      user = store.user(pubkey)

      { "pubkey" => pubkey, "registered" => !user.nil?, "username" => user && user[:username] }
    end

    # A valid but unregistered seed reaches here. The client warns before
    # calling it -- a mistyped seed that happens to pass the checksum would
    # otherwise silently create a new empty account.
    def register(r)
      pubkey   = current_pubkey(r)
      username = Params.string(r.params["username"], max: MAX_USERNAME) or bad_request(r, "bad username")

      r.halt(409, { "error" => "already registered" }) if store.registered?(pubkey)

      store.register(pubkey, username)
      { "pubkey" => pubkey, "username" => username, "registered" => true }
    end

    def fetch_config(pubkey_param)
      pubkey = Params.pubkey(pubkey_param)
      return { "config" => nil } unless pubkey

      { "config" => present_config(store.config_blob(pubkey)) }
    end

    # One round trip for a whole traversal level. A seven-deep walk done one
    # fetch at a time would be hundreds of sequential requests.
    def config_batch(r)
      pubkeys = Params.array_of(r.params["pubkeys"], max: MAX_BATCH) { |v| Params.pubkey(v) }
      bad_request(r, "bad pubkeys") unless pubkeys

      { "configs" => store.config_blobs(pubkeys).map { |row| present_config(row) } }
    end

    def store_config(r)
      pubkey  = current_pubkey(r)
      version = Params.integer(r.params["version"], min: 1) or bad_request(r, "bad version")
      ratings = Params.ratings(r.params["ratings"])         or bad_request(r, "bad ratings")
      sig     = Params.signature(r.params["signature"])     or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"])              or bad_request(r, "bad timestamp")

      payload = Crypto::Payload.config(pubkey: pubkey, version: version, ratings: ratings, issued_at: ts)
      verify!(r, pubkey, sig, payload)

      result = store.store_config(
        pubkey: pubkey, version: version,
        payload: Crypto::Canonical.dump(payload), signature: sig
      )
      r.halt(409, { "error" => "version is not newer than the stored one" }) if result == :stale

      { "stored" => true, "version" => version }
    end

    def post_message(r, room)
      author = current_pubkey(r)
      seq    = Params.integer(r.params["seq"], min: 1) or bad_request(r, "bad seq")
      body   = Params.string(r.params["body"], max: MAX_BODY) or bad_request(r, "bad body")
      sig    = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts     = Params.integer(r.params["ts"]) or bad_request(r, "bad timestamp")
      prev   = r.params["prev"].nil? ? nil : Params.signature(r.params["prev"])

      payload = Crypto::Payload.message(
        author: author, room: room, seq: seq, prev: prev, body: body, issued_at: ts
      )
      verify!(r, author, sig, payload)

      result = store.store_message(
        author: author, room: room, seq: seq, prev: prev,
        payload: Crypto::Canonical.dump(payload), signature: sig
      )
      r.halt(409, { "error" => "that sequence number is already used" }) if result == :duplicate

      { "stored" => true, "seq" => seq }
    end

    # --- helpers ----------------------------------------------------------

    def verify!(r, pubkey, signature, payload)
      return if Crypto::Signature.verify(pubkey_b64: pubkey, signature_b64: signature, payload: payload)

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

    # Signed blobs go out exactly as they came in. The client verifies them
    # against the author's key, so the server re-serializing them would only
    # create a way to break signatures.
    def present_config(row)
      return nil unless row

      { "pubkey" => row[:pubkey], "version" => row[:version],
        "payload" => row[:payload], "signature" => row[:signature] }
    end

    def present_message(row)
      { "author" => row[:author], "seq" => row[:seq], "prev" => row[:prev],
        "payload" => row[:payload], "signature" => row[:signature],
        "received_at" => row[:received_at] }
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
