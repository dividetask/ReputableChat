# frozen_string_literal: true

require "roda"
require "json"
require "yaml"
require "securerandom"
require_relative "params"
require_relative "cryptography/signature"
require_relative "cryptography/canonical"
require_relative "cryptography/payload"
require_relative "cryptography/record"
require_relative "genesis"
require_relative "store/database"
require_relative "store/images"

module ReputableChat
  # The server does as little as it can: it verifies signatures, rejects config
  # rollbacks, and stores signed blobs. It never sees a seed, holds a private
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
    ALLOWED_EMOTES = EMOTES.values_at("positive", "negative", "neutral").compact.flatten.freeze

    class << self
      attr_accessor :store, :images, :origin, :genesis
    end

    def store = self.class.store
    def images = self.class.images
    def origin = self.class.origin
    def genesis = self.class.genesis

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
        r.get("emotes")   { EMOTES }
        # The bottom of the chain. Served so a client can check the hash it
        # was built with against the one this server is running, rather than
        # discovering a mismatch as signatures that will not verify.
        r.get("genesis")  { genesis.to_h }
        r.post("session")   { open_session(r) }
        r.post("register")  { register(r) }
        r.post("image")     { upload_image(r) }

        r.on "private-config" do
          r.get { own_private_config(r) }
          r.put { store_private_config(r) }
        end

        r.on "config" do
          r.post("batch") { config_batch(r) }
          r.put { store_config(r) }
          r.get(String) { |pubkey| fetch_config(pubkey) }
        end

        r.on "room", String do |room_name|
          room = Params.room(room_name) or bad_request(r, "bad room")

          r.get("messages") { { "messages" => store.room_messages(room).map { |m| present_message(m) } } }
          r.get("emotes")   { { "emotes" => store.room_emotes(room) } }
          r.post("message") { post_message(r, room) }
          r.post("emote")   { post_emote(r, room) }
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
    # otherwise silently create a new empty account. The display name is not
    # set here; the client publishes it in its first signed config.
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
      r.halt(413, { "error" => "image too large" }) if declared > Store::Images::MAX_BYTES

      case (result = images.store(r.body.read))
      when :too_large   then r.halt(413, { "error" => "image too large" })
      when :unsupported then bad_request(r, "unsupported image type")
      else { "icon" => result }
      end
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

    # Takes no pubkey -- it uses the session's. Asking for somebody else's
    # private config is not expressible through this route, rather than being
    # a check that has to stay correct.
    def own_private_config(r)
      { "config" => present_config(store.private_config(current_pubkey(r))) }
    end

    def store_private_config(r)
      pubkey   = current_pubkey(r)
      version  = Params.integer(r.params["version"], min: 1) or bad_request(r, "bad version")
      settings = Params.settings(r.params["settings"])       or bad_request(r, "bad settings")
      voted    = Params.voted(r.params["voted"] || [])       or bad_request(r, "bad voted list")
      sig      = Params.signature(r.params["signature"])     or bad_request(r, "bad signature")
      ts       = Params.integer(r.params["ts"])              or bad_request(r, "bad timestamp")

      payload = Cryptography::Payload.private_config(
        pubkey: pubkey, version: version, settings: settings, voted: voted, issued_at: ts
      )
      verify!(r, pubkey, sig, payload)

      result = store.store_private_config(
        pubkey: pubkey, version: version,
        payload: Cryptography::Canonical.dump(payload), signature: sig
      )
      r.halt(409, { "error" => "version is not newer than the stored one" }) if result == :stale

      { "stored" => true, "version" => version }
    end

    def store_config(r)
      pubkey  = current_pubkey(r)
      version = Params.integer(r.params["version"], min: 1) or bad_request(r, "bad version")
      profile = Params.profile(r.params["profile"])         or bad_request(r, "bad profile")
      ratings = Params.ratings(r.params["ratings"])         or bad_request(r, "bad ratings")
      sig     = Params.signature(r.params["signature"])     or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"])              or bad_request(r, "bad timestamp")

      payload = Cryptography::Payload.config(
        pubkey: pubkey, version: version, profile: profile, ratings: ratings, issued_at: ts
      )
      verify!(r, pubkey, sig, payload)

      result = store.store_config(
        pubkey: pubkey, version: version,
        payload: Cryptography::Canonical.dump(payload), signature: sig
      )
      r.halt(409, { "error" => "version is not newer than the stored one" }) if result == :stale

      { "stored" => true, "version" => version }
    end

    # `ack` is the record this message's author had last seen. The server does
    # not check that it was well chosen -- it cannot, since it never computes a
    # reputation and the rule is the author's own. It checks only that it is
    # the right shape, and stores what it is given.
    def post_message(r, room)
      author = current_pubkey(r)
      seq    = Params.integer(r.params["seq"], min: 1) or bad_request(r, "bad seq")
      body   = Params.string(r.params["body"], max: MAX_BODY) or bad_request(r, "bad body")
      sig    = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts     = Params.integer(r.params["ts"]) or bad_request(r, "bad timestamp")
      ack    = Params.record_hash(r.params["ack"]) or bad_request(r, "bad ack")
      prev   = optional_hash(r, "prev")
      reply  = optional_hash(r, "reply_to")

      payload = Cryptography::Payload.message(
        author: author, room: room, seq: seq, prev: prev, body: body,
        ack: ack, issued_at: ts, reply_to: reply
      )
      verify!(r, author, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      result = store.store_message(
        hash: Cryptography::Record.digest(payload: canonical, signature: sig),
        author: author, room: room, seq: seq, prev: prev, ack: ack,
        reply_to: reply, payload: canonical, signature: sig
      )
      r.halt(409, { "error" => "that sequence number is already used" }) if result == :duplicate

      { "stored" => true, "seq" => seq }
    end

    def post_emote(r, room)
      author  = current_pubkey(r)
      message = Params.record_hash(r.params["message"]) or bad_request(r, "bad message")
      choice  = Params.emote(r.params["emote"], allowed: ALLOWED_EMOTES) or bad_request(r, "unknown emote")
      sig     = Params.signature(r.params["signature"]) or bad_request(r, "bad signature")
      ts      = Params.integer(r.params["ts"]) or bad_request(r, "bad timestamp")
      ack     = Params.record_hash(r.params["ack"]) or bad_request(r, "bad ack")

      payload = Cryptography::Payload.emote(
        author: author, room: room, message: message, emote: choice,
        ack: ack, issued_at: ts
      )
      verify!(r, author, sig, payload)

      canonical = Cryptography::Canonical.dump(payload)
      result = store.store_emote(
        hash: Cryptography::Record.digest(payload: canonical, signature: sig),
        author: author, room: room, message: message, emote: choice,
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

    # Signed blobs go out exactly as they came in. The client verifies them
    # against the author's key, so the server re-serializing them would only
    # create a way to break signatures.
    def present_config(row)
      return nil unless row

      { "pubkey" => row[:pubkey], "version" => row[:version],
        "payload" => row[:payload], "signature" => row[:signature] }
    end

    def present_message(row)
      { "hash" => row[:hash], "author" => row[:author], "seq" => row[:seq],
        "prev" => row[:prev], "reply_to" => row[:reply_to], "ack" => row[:ack],
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
