# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "ed25519"
require "base64"
require "tmpdir"
require "reputable_chat/app"

# The vault is the one document the server holds and cannot read. What it can
# still do -- and what it must not be able to do -- is the whole point.
class VaultSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical

  ORIGIN = "http://example.test"

  def setup
    ReputableChat::App.store   = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images  = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origin  = ORIGIN
    ReputableChat::App.genesis = GenesisFixture.build
    @signing, @pubkey = new_user
    log_in_as(@signing, @pubkey)
  end

  def app = ReputableChat::App.app
  def json = JSON.parse(last_response.body)

  def new_user
    key = Ed25519::SigningKey.generate
    [key, Sig.encode(key.verify_key.to_bytes)]
  end

  def sign(key, payload) = Sig.encode(key.sign(Canon.bytes(payload)))

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def log_in_as(key, pubkey)
    post_json "/api/challenge", {}
    nonce = JSON.parse(last_response.body)["nonce"]
    ts = Time.now.to_i
    payload = Payload.login(pubkey: pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    post_json "/api/session",
              { "pubkey" => pubkey, "nonce" => nonce, "ts" => ts,
                "signature" => sign(key, payload) }
    post_json "/api/register", {}
  end

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def vault_body(key: @signing, pubkey: @pubkey, revision: 1,
                 ciphertext: nil, iv: nil)
    ciphertext ||= b64("pretend this is AES-GCM output")
    iv ||= b64("0" * 12)
    ts = Time.now.to_i
    payload = Payload.vault(pubkey: pubkey, revision: revision,
                            ciphertext: ciphertext, iv: iv, issued_at: ts)
    { "revision" => revision, "ciphertext" => ciphertext, "iv" => iv,
      "ts" => ts, "signature" => sign(key, payload) }
  end

  def put_vault(**kwargs)
    put "/api/vault", JSON.generate(vault_body(**kwargs)), "CONTENT_TYPE" => "application/json"
  end

  def test_stores_a_vault_and_serves_it_back
    sealed = b64("ciphertext bytes")
    put_vault(ciphertext: sealed)
    assert_equal 200, last_response.status

    get "/api/vault"
    payload = JSON.parse(json["vault"]["payload"])

    assert_equal sealed, payload["ciphertext"]
    assert_equal ReputableChat::Cryptography::Payload::VAULT, payload["purpose"]
  end

  # RULE: the server holds the vault but cannot read it. Nothing in what it
  # stores names a setting, a friend or a report -- only an opaque blob, its
  # nonce, and the one number it needs to reject a rollback.
  def test_the_server_stores_nothing_it_can_interpret
    put_vault
    columns = ReputableChat::App.store.db[:vaults].columns

    assert_equal %i[pubkey revision payload signature updated_at].sort, columns.sort
    payload = JSON.parse(ReputableChat::App.store.vault(@pubkey)[:payload])
    assert_equal %w[ciphertext iv pubkey purpose revision ts], payload.keys.sort
  end

  # RULE: the revision sits outside the ciphertext so a rollback can be
  # rejected. That is the one thing the server reads, and the reason it can.
  def test_refuses_a_rolled_back_vault
    put_vault(revision: 4)
    assert_equal 200, last_response.status

    put_vault(revision: 3)
    assert_equal 409, last_response.status
  end

  def test_refuses_the_same_revision_twice
    put_vault(revision: 2)
    put_vault(revision: 2)

    assert_equal 409, last_response.status
  end

  # RULE: the ciphertext is signed, so the server cannot swap one vault's
  # contents for another's, or replay an older blob under a newer revision.
  def test_refuses_a_vault_whose_ciphertext_was_altered
    body = vault_body
    body["ciphertext"] = b64("a different blob entirely")

    put "/api/vault", JSON.generate(body), "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
  end

  def test_refuses_a_vault_whose_nonce_was_altered
    body = vault_body
    body["iv"] = b64("1" * 12)

    put "/api/vault", JSON.generate(body), "CONTENT_TYPE" => "application/json"

    assert_equal 400, last_response.status
  end

  # RULE: a byte bound is the only limit the server has, because it cannot see
  # the shape of what is inside. In practice it bounds the voted list, which is
  # the part of a vault that grows without limit.
  def test_refuses_an_oversized_ciphertext
    put_vault(ciphertext: "A" * (ReputableChat::Params::MAX_VAULT + 1))

    assert_equal 400, last_response.status
  end

  def test_refuses_a_nonce_of_the_wrong_length
    put_vault(iv: b64("too short"))

    assert_equal 400, last_response.status
  end

  # RULE: the read path takes no pubkey -- it uses the session's -- so serving
  # somebody else's vault is not expressible through the API rather than being
  # a check that has to stay correct.
  def test_a_vault_is_served_only_to_its_owner
    put_vault(ciphertext: b64("alice's secrets"))

    other_key, other_pubkey = new_user
    log_in_as(other_key, other_pubkey)

    get "/api/vault"

    assert_equal 200, last_response.status
    assert_nil json["vault"], "a second account must not see the first one's vault"
  end

  def test_a_vault_requires_a_session
    clear_cookies
    get "/api/vault"

    assert_equal 401, last_response.status
  end

  # RULE: the vault carries no ack and no note. Nobody else ever sees it, so
  # there is nothing to anchor it to and nobody to address.
  def test_the_vault_is_not_a_chain_record
    payload = Payload.vault(pubkey: "k", revision: 1, ciphertext: "c", iv: "i", issued_at: 1)

    refute payload.key?("ack")
    refute payload.key?("note")
  end
end
