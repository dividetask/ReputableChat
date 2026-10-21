# frozen_string_literal: true

require_relative "spec_helper"
require "rack/test"
require "servers"

# The API other servers and apps use. It speaks records, and nothing about
# what any app does with them.
class ApiSpec < Minitest::Test
  include Rack::Test::Methods
  include Servers

  def setup
    @server = boot("alpha")
    @app = @server.app
  end

  def app = @app

  def json = JSON.parse(last_response.body)

  def post_json(path, body)
    json = body.is_a?(String) ? body : JSON.generate(body)
    post(path, json, upload_env(@server.host, path, json))
  end

  def signed_note(body, ack: [@server.host.id])
    @server.host.sign("message", { "ack" => ack, "body" => body, "ts" => Time.now.to_i })
  end

  def test_the_overview_names_the_rules_genesis_and_host_account
    get "/api"
    assert_equal Agnostic::Rules::VERSION, json["rules"]
    assert_equal @server.genesis.digest, json["genesis"]
    assert_equal @server.host.id, json["host"]
  end

  def test_the_genesis_and_the_host_account_are_served
    get "/api/genesis"
    assert_equal @server.genesis.payload, json["payload"]
    get "/api/host"
    assert_equal @server.host.pubkey, json["pubkey"]
  end

  def test_a_posted_record_is_checked_stored_and_served_back_byte_identical
    record = signed_note("Hello, chain.")
    post_json "/api/records", { "records" => [record.to_wire] }
    assert_equal [{ "status" => "accepted", "hash" => record.digest }], json["results"]

    get "/api/records/#{record.digest}"
    assert_equal record.payload, json["payload"]
    assert_equal record.signature, json["signature"]
  end

  def test_one_record_may_be_posted_on_its_own
    record = signed_note("Alone.")
    post_json "/api/records", record.to_wire
    assert_equal "accepted", json["results"].first["status"]
  end

  def test_an_invalid_record_is_refused_with_the_rules_it_breaks
    forged = Agnostic::Record.new(payload: signed_note("x").payload, signature: signed_note("y").signature)
    post_json "/api/records", { "records" => [forged.to_wire] }
    result = json["results"].first
    assert_equal "refused", result["status"]
    assert_match(/verifies against no key/, result["problems"].first)
    get "/api/records/#{forged.digest}"
    assert_equal 404, last_response.status
  end

  def test_a_record_ahead_of_its_parents_is_held_and_says_what_it_waits_for
    parent = signed_note("parent")
    child = signed_note("child", ack: [parent.digest])
    post_json "/api/records", { "records" => [child.to_wire] }
    assert_equal 202, last_response.status
    assert_equal [parent.digest], json["results"].first["missing"]

    post_json "/api/records", { "records" => [parent.to_wire] }
    get "/api/records/#{child.digest}"
    assert_equal 200, last_response.status
  end

  def test_records_page_from_a_cursor_in_the_order_they_were_accepted
    get "/api/records?since=0&limit=1"
    assert_equal [@server.genesis.digest], json["records"].map { |r| r["hash"] }
    get "/api/records?since=#{json['next']}"
    assert_equal [@server.host.id], json["records"].map { |r| r["hash"] }
  end

  def test_records_filter_by_type_prefix_account_and_target
    record = signed_note("filtered")
    post_json "/api/records", record.to_wire
    get "/api/records?type=reputablechat:message:"
    assert_equal [record.digest], json["records"].map { |r| r["hash"] }
    get "/api/records?account=#{@server.host.id}"
    assert_includes json["records"].map { |r| r["hash"] }, record.digest
    get "/api/records?target=#{record.digest}"
    assert_empty json["records"]
  end

  def test_the_frontier_is_what_nothing_acknowledges
    get "/api/frontier"
    assert_equal [@server.host.id], json["records"]
  end

  def test_a_body_that_is_not_json_is_refused
    post_json "/api/records", "{nope"
    assert_equal 400, last_response.status
  end

  # --- what an app reads to decide what to show ------------------------------------

  def test_a_record_is_served_with_its_state
    record = signed_note("Stated.")
    post_json "/api/records", record.to_wire

    get "/api/records/#{record.digest}"
    assert_equal "valid", json["state"]

    post_json "/api/states", { "hashes" => [record.digest, "f" * 64] }
    assert_equal({ record.digest => "valid", "f" * 64 => nil }, json["states"])
  end

  def test_a_working_key_names_the_account_it_signs_for
    get "/api/keys/#{@server.host.pubkey}"
    assert_equal @server.host.id, json["account"]

    get "/api/keys/#{'A' * 43}"
    assert_nil json["account"]
  end

  def test_an_account_is_summarised_by_its_newest_records
    note = signed_note("Latest.")
    post_json "/api/records", note.to_wire

    get "/api/accounts/#{@server.host.id}"
    assert_equal @server.host.id, JSON.parse(json["declaration"]["payload"]).then { |p| p["id"] || json["declaration"]["hash"] }
    assert_nil json["attestation"]
    assert_equal note.digest, json["latest"]

    post_json "/api/accounts", { "accounts" => [@server.host.id, "f" * 64] }
    assert_equal [@server.host.id], json["accounts"].map { |a| a["account"] }
  end
end
