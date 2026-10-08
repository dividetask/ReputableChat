# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# Uploading records -- POST /api/records and /api/sync -- needs a request signed
# by an account on this server's chain, with its current working or master
# key. Reading needs nothing.
class UploadAuthSpec < Minitest::Test
  include Servers

  def setup
    @alpha = boot("alpha", host: { "url" => "http://alpha" })
    @beta = boot("beta", host: { "url" => "http://beta" })
    @alpha.ingest.submit(@beta.host.declaration) # beta is on alpha's chain
  end

  def note(body) = @beta.host.sign("message", { "ack" => [@beta.host.id], "body" => body, "ts" => Time.now.to_i })

  def upload(body, signer: @beta.host, ts: Time.now.to_i, path: "/api/records")
    signed_post(@alpha, path, body, signer: signer, ts: ts)
  end

  def unsigned(path, body)
    Rack::MockRequest.new(@alpha.app).post(path, input: JSON.generate(body), "CONTENT_TYPE" => "application/json")
  end

  def test_a_signed_upload_from_an_account_on_the_chain_is_taken
    response = upload({ "records" => [note("hello").to_wire] })
    assert_equal 200, response.status, response.body
    assert_equal "accepted", JSON.parse(response.body)["results"].first["status"]
  end

  def test_an_unsigned_upload_is_refused
    assert_equal 401, unsigned("/api/records", { "records" => [note("hello").to_wire] }).status
    assert_equal 401, unsigned("/api/sync", { "heartbeat" => {} }).status
  end

  def test_reading_needs_no_signature
    %w[/api /api/frontier /api/records?since=0 /api/sweep].each do |path|
      assert_equal 200, Rack::MockRequest.new(@alpha.app).get(path).status, path
    end
    assert_equal 200, unsigned("/api/states", { "hashes" => [] }).status
  end

  def test_an_account_not_on_the_chain_is_told_to_introduce_itself
    gamma = boot("gamma")
    response = upload({ "records" => [] }, signer: gamma.host)
    assert_equal 401, response.status
    assert JSON.parse(response.body)["unknown_account"]

    introduced = Rack::MockRequest.new(@alpha.app).post(
      "/api/introduce", input: JSON.generate("declaration" => gamma.host.declaration.to_wire), "CONTENT_TYPE" => "application/json"
    )
    assert_equal 200, introduced.status
    assert_equal 200, upload({ "records" => [] }, signer: gamma.host).status
  end

  def test_an_introduction_is_a_first_declaration_and_nothing_else
    response = Rack::MockRequest.new(@alpha.app).post(
      "/api/introduce", input: JSON.generate("declaration" => note("not a declaration").to_wire), "CONTENT_TYPE" => "application/json"
    )
    assert_equal 400, response.status
  end

  # The key must be the account's own: a stranger naming beta's account with
  # a key of its own is refused.
  def test_a_key_the_account_does_not_hold_is_refused
    stranger = Ed25519::SigningKey.generate
    ts = Time.now.to_i.to_s
    h = Agnostic::UploadAuth::HEADERS
    env = {
      h[:account] => @beta.host.id, h[:key] => Agnostic::Keys.public_key(stranger), h[:ts] => ts,
      h[:signature] => Agnostic::Keys.sign(stranger, Agnostic::UploadAuth.message(:post, "/api/records", ts, "{}"))
    }.to_h { |k, v| ["HTTP_#{k.upcase.tr('-', '_')}", v] }
    response = Rack::MockRequest.new(@alpha.app).post("/api/records", env.merge("CONTENT_TYPE" => "application/json", input: "{}"))
    assert_equal 401, response.status
    assert_match(/not a current key/, response.body)
  end

  def test_a_signature_does_not_carry_over_to_another_body
    env = upload_env(@beta.host, "/api/records", JSON.generate({ "records" => [] }))
    response = Rack::MockRequest.new(@alpha.app).post("/api/records", env.merge(input: JSON.generate({ "records" => [note("swapped").to_wire] })))
    assert_equal 401, response.status
    assert_match(/does not verify/, response.body)
  end

  def test_a_stale_signature_is_refused
    assert_equal 401, upload({ "records" => [] }, ts: Time.now.to_i - 601).status
  end

  def test_a_server_shares_only_its_own_heartbeat
    beat = @beta.host.sign("heartbeat", { "ack" => [@beta.host.id], "body" => "", "ts" => Time.now.to_i })
    @alpha.ingest.submit(@alpha.host.declaration)
    response = signed_post(@alpha, "/api/sync", { "heartbeat" => beat.to_wire }, signer: @alpha.host)
    assert_equal 403, response.status
    assert_equal 200, upload({ "heartbeat" => beat.to_wire }, path: "/api/sync").status
  end

  # A server new to a peer introduces itself unprompted the first time it is
  # refused for being unknown, then shares.
  def test_a_server_unknown_to_its_peer_introduces_itself_when_it_syncs
    gamma = boot("gamma", peers: ["alpha"])
    refute @alpha.store.known?(gamma.host.id)
    gamma.beat_and_sync
    assert @alpha.store.known?(gamma.heartbeat.previous.digest)
  end
end
