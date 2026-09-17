# frozen_string_literal: true

require_relative "spec_helper"
require "rack/test"
require "ed25519"
require "reputable_chat/app"
require "reputable_chat/crypto/signature"
require "reputable_chat/crypto/payload"

class AppSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Crypto::Signature
  Payload = ReputableChat::Crypto::Payload
  Canon   = ReputableChat::Crypto::Canonical

  ORIGIN = "http://example.test"

  def setup
    ReputableChat::App.store  = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.origin = ORIGIN
    @signing = Ed25519::SigningKey.generate
    @pubkey  = Sig.encode(@signing.verify_key.to_bytes)
  end

  def app = ReputableChat::App.app

  def sign(payload) = Sig.encode(@signing.sign(Canon.bytes(payload)))

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def json = JSON.parse(last_response.body)

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
    post_json "/api/register", { "username" => "nobody" }

    assert_equal 401, last_response.status
  end

  # --- config storage ---------------------------------------------------

  def config_body(version:, ratings:, key: nil)
    ts = Time.now.to_i
    payload = Payload.config(pubkey: @pubkey, version: version, ratings: ratings, issued_at: ts)
    signature = key ? Sig.encode(key.sign(Canon.bytes(payload))) : sign(payload)
    { "version" => version, "ratings" => ratings, "ts" => ts, "signature" => signature }
  end

  def ratings_for(target, friend: true, reported: false, net_votes: 0)
    { target => { "friend" => friend, "reported" => reported, "net_votes" => net_votes } }
  end

  def test_stores_and_serves_a_signed_config
    log_in
    target = Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes)

    put "/api/config", JSON.generate(config_body(version: 1, ratings: ratings_for(target))),
        "CONTENT_TYPE" => "application/json"
    assert_equal 200, last_response.status

    get "/api/config/#{@pubkey}"
    stored = json["config"]

    assert_equal 1, stored["version"]
    assert Sig.verify(pubkey_b64: @pubkey, signature_b64: stored["signature"],
                      payload: JSON.parse(stored["payload"])),
           "the served blob must still verify against the author's key"
  end

  def test_refuses_an_unsigned_config
    log_in
    target = Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes)
    body = config_body(version: 1, ratings: ratings_for(target), key: Ed25519::SigningKey.generate)

    put "/api/config", JSON.generate(body), "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
  end

  # Without the version check the server could serve an old config to hide a
  # report, and its signature would still verify perfectly.
  def test_refuses_a_rollback
    log_in
    target = Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes)

    put "/api/config", JSON.generate(config_body(version: 5, ratings: ratings_for(target))),
        "CONTENT_TYPE" => "application/json"
    assert_equal 200, last_response.status

    put "/api/config", JSON.generate(config_body(version: 4, ratings: ratings_for(target))),
        "CONTENT_TYPE" => "application/json"
    assert_equal 409, last_response.status
  end

  def test_rejects_malformed_ratings
    log_in

    put "/api/config", JSON.generate(config_body(version: 1, ratings: { "not-a-key" => {} })),
        "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
  end

  def test_batch_fetch_is_bounded
    log_in
    too_many = Array.new(300) { Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes) }

    post_json "/api/config/batch", { "pubkeys" => too_many }

    assert_equal 400, last_response.status
  end

  # --- messages ---------------------------------------------------------

  def test_stores_a_signed_message
    log_in
    ts = Time.now.to_i
    payload = Payload.message(author: @pubkey, room: "general", seq: 1, prev: nil,
                              body: "hello", issued_at: ts)

    post_json "/api/room/general/message",
              { "seq" => 1, "prev" => nil, "body" => "hello", "ts" => ts, "signature" => sign(payload) }
    assert_equal 200, last_response.status

    get "/api/room/general/messages"
    assert_equal 1, json["messages"].size
    assert_equal @pubkey, json["messages"].first["author"]
  end

  # A message signed for one room must not be replantable in another.
  def test_a_message_cannot_be_moved_between_rooms
    log_in
    ts = Time.now.to_i
    elsewhere = Payload.message(author: @pubkey, room: "other", seq: 1, prev: nil,
                                body: "hello", issued_at: ts)

    post_json "/api/room/general/message",
              { "seq" => 1, "prev" => nil, "body" => "hello", "ts" => ts, "signature" => sign(elsewhere) }

    assert_equal 400, last_response.status
  end

  def test_sequence_numbers_cannot_be_reused
    log_in
    ts = Time.now.to_i
    payload = Payload.message(author: @pubkey, room: "general", seq: 1, prev: nil,
                              body: "hello", issued_at: ts)
    body = { "seq" => 1, "prev" => nil, "body" => "hello", "ts" => ts, "signature" => sign(payload) }

    post_json "/api/room/general/message", body
    assert_equal 200, last_response.status

    post_json "/api/room/general/message", body
    assert_equal 409, last_response.status
  end

  def test_rejects_a_bad_room_name
    log_in

    get "/api/room/..%2Fetc/messages"

    refute_equal 200, last_response.status
  end

  def test_sets_a_strict_content_security_policy
    get "/api/config/#{@pubkey}"
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
    self.origin = "http://example.test"
  end.freeze

  def app = FROZEN.app

  def test_serves_reputation_defaults_to_the_client
    get "/api/defaults"

    assert_equal 200, last_response.status
    config = JSON.parse(last_response.body)

    assert_equal "0.09", config.dig("constants", "k")
    assert_equal "0.0004", config.dig("vote_curve", "a")
    assert_equal 8, config.dig("seed", "min_words")
    assert_equal "argon2id", config.dig("seed", "kdf", "algorithm")
  end

  def test_serves_emote_polarity
    get "/api/emotes"

    assert_equal 200, last_response.status
    emotes = JSON.parse(last_response.body)

    assert_operator emotes["positive"].size, :>, emotes["negative"].size,
                    "positive emotes should outnumber negative ones by design"
  end

  def test_serves_the_wordlist
    get "/wordlist.txt"

    assert_equal 200, last_response.status
    assert_equal 2048, last_response.body.split("\n").size
  end

  def test_security_headers_are_present_on_api_responses
    get "/api/defaults"

    assert_includes last_response.headers["Content-Security-Policy"], "default-src 'self'"
    assert_equal "DENY", last_response.headers["X-Frame-Options"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
  end
end
