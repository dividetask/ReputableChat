# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "ed25519"
require "reputable_chat/app"
require "reputable_chat/cryptography/signature"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/record"
require "tmpdir"
require "digest"

class AppSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical

  ORIGIN = "http://example.test"

  def setup
    ReputableChat::App.store  = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origin = ORIGIN
    ReputableChat::App.genesis = GenesisFixture.build
    @signing = Ed25519::SigningKey.generate
    @pubkey  = Sig.encode(@signing.verify_key.to_bytes)
  end

  def app = ReputableChat::App.app

  def sign(payload) = Sig.encode(@signing.sign(Canon.bytes(payload)))

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def json = JSON.parse(last_response.body)

  # What a client with nothing else in view acknowledges.
  def ack = ReputableChat::App.genesis.hash

  # A record hash that is well formed but names nothing stored, which is all
  # the server can tell about one anyway.
  def a_record_hash(seed = "a message") = Digest::SHA256.hexdigest(seed)

  def challenge
    post_json "/api/challenge", {}
    json["nonce"]
  end

  def log_in
    nonce = challenge
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    post_json "/api/session",
              { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }
  end

  # --- login ------------------------------------------------------------

  def test_login_round_trip
    log_in

    assert_equal 200, last_response.status
    assert_equal @pubkey, json["pubkey"]
    refute json["registered"], "a fresh key should not be registered yet"
  end

  def test_rejects_a_bad_signature
    nonce = challenge
    ts = Time.now.to_i
    other = Ed25519::SigningKey.generate
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    forged = Sig.encode(other.sign(Canon.bytes(payload)))

    post_json "/api/session", { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => forged }

    assert_equal 401, last_response.status
  end

  # A signature made for another origin must not authenticate here. This is
  # what stops one server replaying a harvested login against another.
  def test_rejects_a_signature_bound_to_another_origin
    nonce = challenge
    ts = Time.now.to_i
    elsewhere = Payload.login(pubkey: @pubkey, nonce: nonce, origin: "http://evil.test", issued_at: ts)

    post_json "/api/session",
              { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(elsewhere) }

    assert_equal 401, last_response.status
  end

  def test_a_challenge_cannot_be_replayed
    nonce = challenge
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    body = { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }

    post_json "/api/session", body
    assert_equal 200, last_response.status

    post_json "/api/session", body
    assert_equal 401, last_response.status, "a spent challenge must not work twice"
  end

  def test_rejects_a_stale_timestamp
    nonce = challenge
    ts = Time.now.to_i - 3_600
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)

    post_json "/api/session", { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  def test_writes_require_a_session
    post_json "/api/register", {}

    assert_equal 401, last_response.status
  end

  # --- images ------------------------------------------------------------

  PNG = "\x89PNG\r\n\x1A\n".b + ("x" * 64).b

  def test_image_upload_is_content_addressed
    log_in
    post "/api/image", PNG, "CONTENT_TYPE" => "application/octet-stream"
    assert_equal 200, last_response.status

    icon = JSON.parse(last_response.body)["icon"]
    assert_equal "#{Digest::SHA256.hexdigest(PNG)}.png", icon,
                 "the filename must be the hash of the bytes"

    get "/images/#{icon}"
    assert_equal 200, last_response.status
    assert_equal "image/png", last_response.headers["Content-Type"]
    assert_equal PNG, last_response.body.b
  end

  # SVG is a script-bearing document. It must never be storable as an icon.
  def test_rejects_svg_and_other_unsniffable_uploads
    log_in

    post "/api/image", "<svg onload=alert(1)></svg>", "CONTENT_TYPE" => "image/svg+xml"
    assert_equal 400, last_response.status

    post "/api/image", "not an image at all", "CONTENT_TYPE" => "image/png"
    assert_equal 400, last_response.status, "a claimed content type must not be trusted"
  end

  def test_rejects_oversized_images
    log_in
    huge = "\x89PNG\r\n\x1A\n".b + ("x" * 300_000).b

    post "/api/image", huge, "CONTENT_TYPE" => "application/octet-stream"

    assert_equal 413, last_response.status
  end

  def test_image_names_cannot_traverse_paths
    log_in

    get "/images/..%2F..%2Fconfig%2Freputation.yml"
    refute_equal 200, last_response.status

    get "/images/#{'a' * 64}.svg"
    assert_equal 404, last_response.status
  end

  # --- batch fetching -----------------------------------------------------

  # RULE: a batch is bounded. The traversal fetches a whole hop per request, so
  # the request size is chosen by the client -- an unbounded one would let
  # anybody ask for the entire table in a single call.
  def test_batch_fetch_is_bounded
    log_in
    too_many = Array.new(300) { Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes) }

    post_json "/api/attestation/batch", { "pubkeys" => too_many }

    assert_equal 400, last_response.status
  end

  # --- messages ---------------------------------------------------------

  def test_stores_a_reply_and_serves_the_target_back
    log_in
    ts = Time.now.to_i
    target = a_record_hash("target")
    payload = Payload.message(pubkey: @pubkey, body: "agreed", ack: ack, issued_at: ts, reply_to: target)

    post_json "/api/message",
              { "ack" => ack, "body" => "agreed", "ts" => ts,
                "reply_to" => target, "signature" => sign(payload) }
    assert_equal 200, last_response.status

    get "/api/messages"
    assert_equal target, json["messages"].first["reply_to"]
  end

  # RULE: the reply target is signed, so it cannot be swapped in transit.
  def test_rejects_a_reply_whose_target_was_altered
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "agreed", ack: ack, issued_at: ts, reply_to: a_record_hash("target"))

    post_json "/api/message",
              { "ack" => ack, "body" => "agreed", "ts" => ts,
                "reply_to" => a_record_hash("other"), "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  def test_rejects_a_malformed_reply_target
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hi", ack: ack, issued_at: ts, reply_to: "nope")

    post_json "/api/message",
              { "ack" => ack, "body" => "hi", "ts" => ts,
                "reply_to" => "nope", "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  def test_stores_a_signed_message
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: ack, issued_at: ts)

    post_json "/api/message",
              { "ack" => ack, "body" => "hello", "ts" => ts, "signature" => sign(payload) }
    assert_equal 200, last_response.status

    get "/api/messages"
    assert_equal 1, json["messages"].size
    assert_equal @pubkey, json["messages"].first["pubkey"]
  end

  # RULE: a message must name what its author had seen. A record with no ack is
  # one nothing else can anchor to, so it is refused rather than stored loose.
  def test_rejects_a_message_with_no_ack
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: ack, issued_at: ts)

    post_json "/api/message",
              { "body" => "hello", "ts" => ts,
                "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  def test_rejects_a_malformed_ack
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: "nope", issued_at: ts)

    post_json "/api/message",
              { "ack" => "nope", "body" => "hello",
                "ts" => ts, "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  # RULE: the ack is inside the signature, so a server cannot re-anchor a
  # message to somewhere else in the history after the fact.
  def test_rejects_a_message_whose_ack_was_altered
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: ack, issued_at: ts)

    post_json "/api/message",
              { "ack" => a_record_hash("elsewhere"),
                "body" => "hello", "ts" => ts, "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  # RULE: the hash the server serves is the hash of what it serves. A reader
  # re-derives it from the blob, so a server that made one up would be caught.
  def test_the_served_hash_is_the_hash_of_the_served_record
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: ack, issued_at: ts)

    post_json "/api/message",
              { "ack" => ack, "body" => "hello",
                "ts" => ts, "signature" => sign(payload) }
    assert_equal 200, last_response.status

    get "/api/messages"
    stored = json["messages"].first

    assert_equal ack, stored["ack"]
    assert_equal ReputableChat::Cryptography::Record.digest(
      payload: stored["payload"], signature: stored["signature"]
    ), stored["hash"]
  end

  # RULE: the genesis is served so a client can check the hash it was built
  # with against the one this server runs, rather than meeting the mismatch as
  # signatures that will not verify.
  def test_serves_the_genesis_record
    get "/api/genesis"

    assert_equal 200, last_response.status
    assert_equal ReputableChat::App.genesis.hash, json["hash"]
    assert_nil JSON.parse(json["payload"])["ack"]
  end

  # RULE: the identical record cannot be stored twice. There is no sequence
  # number any more, so the record hash being unique is what catches a repeat --
  # the same payload and the same signature, sent again.
  def test_the_same_record_cannot_be_stored_twice
    log_in
    ts = Time.now.to_i
    payload = Payload.message(pubkey: @pubkey, body: "hello", ack: ack, issued_at: ts)
    body = { "ack" => ack, "body" => "hello", "ts" => ts, "signature" => sign(payload) }

    post_json "/api/message", body
    assert_equal 200, last_response.status

    post_json "/api/message", body
    assert_equal 409, last_response.status
  end

  # --- emotes ------------------------------------------------------------

  # Taken from the app rather than hand-escaped, so these stay real emotes if
  # config/emotes.yml changes.
  FIRST_EMOTE  = ReputableChat::App::ALLOWED_EMOTES.first
  SECOND_EMOTE = ReputableChat::App::ALLOWED_EMOTES[1]

  def emote_body(message:, emote: FIRST_EMOTE, key: nil)
    ts = Time.now.to_i
    payload = Payload.emote(pubkey: @pubkey, message: message,
                            emote: emote, ack: ack, issued_at: ts)
    signature = key ? Sig.encode(key.sign(Canon.bytes(payload))) : sign(payload)
    { "message" => message, "emote" => emote, "ack" => ack, "ts" => ts, "signature" => signature }
  end

  def a_message_signature = a_record_hash

  def test_stores_an_emote_and_serves_it_back
    log_in
    post_json "/api/emote", emote_body(message: a_message_signature)
    assert_equal 200, last_response.status

    get "/api/emotes"
    stored = json["emotes"]

    assert_equal 1, stored.size
    assert_equal a_message_signature, stored.first["message"]
    assert_equal FIRST_EMOTE, stored.first["emote"]
    assert_equal @pubkey, stored.first["pubkey"], "the author is needed to show whether you reacted"
  end

  # One emote per person per message, enforced server-side rather than
  # trusted from the client.
  def test_one_emote_per_person_per_message
    log_in
    body = emote_body(message: a_message_signature)

    post_json "/api/emote", body
    assert_equal 200, last_response.status

    post_json "/api/emote", emote_body(message: a_message_signature, emote: SECOND_EMOTE)
    assert_equal 409, last_response.status, "a different emote is still a second one"
  end

  # An arbitrary string must never be storable, or it renders back to everyone.
  def test_rejects_an_emote_outside_the_published_set
    log_in

    post_json "/api/emote", emote_body(message: a_message_signature, emote: "<img onerror=x>")

    assert_equal 400, last_response.status
  end

  def test_rejects_an_emote_signed_by_someone_else
    log_in

    post_json "/api/emote",
              emote_body(message: a_message_signature, key: Ed25519::SigningKey.generate)

    assert_equal 400, last_response.status
  end

  def test_emoting_requires_a_session
    post_json "/api/emote", emote_body(message: a_message_signature)

    assert_equal 401, last_response.status
  end

  def test_sets_a_strict_content_security_policy
    get "/api/identity/#{@pubkey}"
    csp = last_response.headers["Content-Security-Policy"]

    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "frame-ancestors 'none'"
  end
end

# config.ru freezes the app class. Anything that lazily memoizes on first
# request raises FrozenError in production while passing every unfrozen test,
# so the frozen path gets its own coverage.
class FrozenAppSpec < Minitest::Test
  include Rack::Test::Methods

  # A subclass, so freezing does not leak into the rest of the suite. Note the
  # ordering this depends on, which config.ru also relies on: store and origin
  # must be assigned BEFORE the class is frozen, since they are class-level
  # accessors.
  FROZEN = Class.new(ReputableChat::App) do
    self.store  = ReputableChat::Store::Database.new("sqlite:/")
    self.images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    self.origin = "http://example.test"
  end.freeze

  def app = FROZEN.app

  def test_serves_reputation_defaults_to_the_client
    get "/api/defaults"

    assert_equal 200, last_response.status
    config = JSON.parse(last_response.body)

    assert_equal "0.1", config.dig("constants", "k")
    assert_equal "0.0004", config.dig("vote_curve", "a")
    assert_equal 8, config.dig("seed", "min_words")
    assert_equal "argon2id", config.dig("seed", "kdf", "algorithm")
  end

  def test_serves_emote_polarity
    get "/api/emote-kinds"

    assert_equal 200, last_response.status
    emotes = JSON.parse(last_response.body)

    assert_operator emotes["positive"].size, :>, emotes["negative"].size,
                    "positive emotes should outnumber negative ones by design"
  end

  # RULE: /new-account is a real URL, so a refresh or a bookmark works.
  def test_new_account_is_its_own_url
    get "/new-account"

    assert_equal 200, last_response.status
    assert_includes last_response.headers["Content-Type"], "text/html"
    assert_includes last_response.body, "login-form"
  end

  def test_serves_the_wordlist
    get "/wordlist.txt"

    assert_equal 200, last_response.status
    assert_equal 2048, last_response.body.split("\n").size
  end

  # RULE: browsers must revalidate the app's own modules. Without an explicit
  # policy they cache each file independently on a heuristic, which after a
  # deploy leaves someone running a new app.js against a stale session.js --
  # and for signed payloads that is a silent failure, not a loud one.
  def test_modules_must_be_revalidated
    %w[/js/app.js /js/session.js /js/identity.js /css/app.css].each do |path|
      get path

      assert_equal 200, last_response.status, path
      assert_equal "no-cache", last_response.headers["Cache-Control"], path
    end
  end

  # RULE: things whose name is their content never need revalidating.
  def test_content_addressed_assets_stay_immutable
    get "/wordlist.txt"

    assert_includes last_response.headers["Cache-Control"], "immutable"
  end

  def test_security_headers_are_present_on_api_responses
    get "/api/defaults"

    assert_includes last_response.headers["Content-Security-Policy"], "default-src 'self'"
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
  end
end
