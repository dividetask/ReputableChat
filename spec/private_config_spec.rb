# frozen_string_literal: true

require_relative "spec_helper"
require "digest"
require "rack/test"
require "ed25519"
require "tmpdir"
require "reputable_chat/app"
require "reputable_chat/cryptography/signature"
require "reputable_chat/cryptography/payload"

# The private config is held by the server so it cannot be lost, signed so
# tampering is detectable, and served to nobody but its owner.
class PrivateConfigSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical

  ORIGIN   = "http://example.test"
  SETTINGS = { "display" => { "show_unrated" => true } }.freeze

  def setup
    ReputableChat::App.store  = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origin = ORIGIN
  end

  def app = ReputableChat::App.app
  def json = JSON.parse(last_response.body)

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def new_user
    key = Ed25519::SigningKey.generate
    [key, Sig.encode(key.verify_key.to_bytes)]
  end

  # Signs in as this key, replacing whoever was signed in before.
  def log_in_as(key, pubkey)
    clear_cookies
    post_json "/api/challenge", {}
    nonce = json["nonce"]
    ts = Time.now.to_i
    payload = Payload.login(pubkey: pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    signature = Sig.encode(key.sign(Canon.bytes(payload)))

    post_json "/api/session", { "pubkey" => pubkey, "nonce" => nonce, "ts" => ts, "signature" => signature }
  end

  def put_private(key, pubkey, version:, settings: SETTINGS, voted: [], signer: nil)
    ts = Time.now.to_i
    payload = Payload.private_config(pubkey: pubkey, version: version, settings: settings,
                                     voted: voted, issued_at: ts)
    signature = Sig.encode((signer || key).sign(Canon.bytes(payload)))

    put "/api/private-config",
        JSON.generate({ "version" => version, "settings" => settings, "voted" => voted,
                        "ts" => ts, "signature" => signature }),
        "CONTENT_TYPE" => "application/json"
  end

  def test_round_trips_through_the_server
    key, pubkey = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 1)
    assert_equal 200, last_response.status

    get "/api/private-config"
    stored = json["config"]
    payload = JSON.parse(stored["payload"])

    assert_equal true, payload.dig("settings", "display", "show_unrated")
    assert Sig.verify(pubkey_b64: pubkey, signature_b64: stored["signature"], payload: payload),
           "the served blob must still verify against the owner's key"
  end

  # The whole point: one user must never receive another's private config.
  def test_is_never_served_to_another_user
    alice_key, alice = new_user
    bob_key, bob = new_user

    log_in_as(alice_key, alice)
    put_private(alice_key, alice, version: 1, settings: { "secret" => "alice only" })

    log_in_as(bob_key, bob)
    get "/api/private-config"

    assert_equal 200, last_response.status
    assert_nil json["config"], "Bob must not receive Alice's private config"
  end

  # There is no pubkey parameter on the read route, so a supplied one is simply
  # not part of the request. This pins that.
  def test_a_supplied_pubkey_cannot_redirect_the_read
    alice_key, alice = new_user
    bob_key, bob = new_user

    log_in_as(alice_key, alice)
    put_private(alice_key, alice, version: 1, settings: { "secret" => "alice only" })

    log_in_as(bob_key, bob)
    get "/api/private-config", { "pubkey" => alice }

    assert_nil json["config"]
  end

  def test_requires_a_session
    key, pubkey = new_user
    clear_cookies

    get "/api/private-config"
    assert_equal 401, last_response.status

    put_private(key, pubkey, version: 1)
    assert_equal 401, last_response.status
  end

  def test_refuses_a_config_signed_by_someone_else
    key, pubkey = new_user
    other_key, = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 1, signer: other_key)

    assert_equal 400, last_response.status
  end

  # Without a version check the server could serve back an older copy and the
  # signature on it would still verify perfectly.
  def test_refuses_a_rollback
    key, pubkey = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 5)
    assert_equal 200, last_response.status

    put_private(key, pubkey, version: 4)
    assert_equal 409, last_response.status
  end

  def test_rejects_malformed_settings
    key, pubkey = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 1, settings: { "a" => [1, 2] })
    assert_equal 400, last_response.status, "arrays are not a settings leaf"

    put_private(key, pubkey, version: 1, settings: "not a hash")
    assert_equal 400, last_response.status
  end

  def test_rejects_a_malformed_voted_list
    key, pubkey = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 1, voted: ["not a signature"])

    assert_equal 400, last_response.status
  end

  # The voted list is what makes one-vote-per-comment survive a second device.
  # It names record hashes, the same way everything else on the chain names a
  # message.
  def test_carries_the_voted_list
    key, pubkey = new_user
    log_in_as(key, pubkey)
    voted = Digest::SHA256.hexdigest("a message")

    put_private(key, pubkey, version: 1, voted: [voted])
    assert_equal 200, last_response.status

    get "/api/private-config"
    assert_equal [voted], JSON.parse(json["config"]["payload"])["voted"]
  end

  # RULE: a signature is not a record hash. They were the same thing before the
  # chain existed, so an old client sending the old shape has to be refused
  # rather than quietly storing something nothing can be matched against.
  def test_rejects_a_voted_entry_that_is_a_signature
    key, pubkey = new_user
    log_in_as(key, pubkey)

    put_private(key, pubkey, version: 1, voted: ["a" * 86])

    assert_equal 400, last_response.status
  end
end
