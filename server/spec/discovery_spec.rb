# frozen_string_literal: true

require_relative "spec_helper"
require "servers"
require "stringio"
require "agnostic/setup"

# A fresh server is told of a few servers, or none, and learns of the rest
# from the records passed along. Servers it cannot reach are tried less and
# less often, then forgotten.
class DiscoverySpec < Minitest::Test
  include Servers

  def setup
    @now = Time.now.to_i
  end

  def at(name, peers: [])
    boot(name, peers: peers.map { |p| p.sub("http://", "") }, clock: -> { @now }, host: { "url" => "http://#{name}" })
  end

  def known(server) = server.store.peers.map { |p| p[:url] }

  # --- setup ----------------------------------------------------------------------

  def answer(*lines, settings:)
    out = StringIO.new
    path = Agnostic::Setup.new(settings: settings, input: StringIO.new(lines.join("\n") + "\n"), output: out).run
    [YAML.safe_load_file(path), out.string]
  end

  def test_setup_asks_for_the_handle_address_and_other_servers
    Dir.mktmpdir do |dir|
      settings = Agnostic::Settings.new({ "data_dir" => dir }, env: {})
      written, = answer("Relay", "https://relay.example/", "https://a.example", "not a url", "http://b.example:9292", "",
                        settings: settings)

      assert_equal({ "handle" => "Relay", "url" => "https://relay.example" }, written["host"])
      assert_equal ["https://a.example", "http://b.example:9292"], written.dig("peers", "urls")

      loaded = Agnostic::Settings.load(path: "/nonexistent", env: { "DATA_DIR" => dir })
      assert_equal "https://relay.example", loaded.url
      assert_equal ["https://a.example", "http://b.example:9292"], loaded.peers
    end
  end

  def test_with_no_other_servers_it_runs_alone
    Dir.mktmpdir do |dir|
      written, said = answer("", "", "", settings: Agnostic::Settings.new({ "data_dir" => dir }, env: {}))
      assert_empty written.dig("peers", "urls")
      assert_match(/run alone/, said)
    end
  end

  def test_an_address_that_is_not_http_is_asked_again
    Dir.mktmpdir do |dir|
      written, said = answer("", "chain.example", "https://chain.example", "",
                             settings: Agnostic::Settings.new({ "data_dir" => dir }, env: {}))
      assert_equal "https://chain.example", written.dig("host", "url")
      assert_match(/not an http or https address/, said)
    end
  end

  # --- learning -------------------------------------------------------------------

  def test_a_server_learns_of_the_servers_whose_records_reach_it
    alpha = at("alpha")
    beta = at("beta", peers: ["http://alpha"])
    gamma = at("gamma", peers: ["http://alpha"])

    beta.beat_and_sync
    assert_includes known(alpha), "http://beta", "alpha did not learn of beta from beta's records"

    gamma.beat_and_sync
    alpha.beat_and_sync
    assert_includes known(beta), "http://gamma", "beta did not learn of gamma through alpha"
    assert beta.store.known?(gamma.heartbeat.previous.digest)
  end

  def test_an_account_that_never_heartbeats_is_not_taken_for_a_server
    alpha = at("alpha")
    note = alpha.host.sign("identity", { "ack" => [alpha.host.id], "title" => "x", "body" => "", "ts" => @now })
    person = Agnostic::HostAccount.sign(Ed25519::SigningKey.generate, {
      "ack" => [alpha.genesis.digest], "body" => "", "title" => "Dana", "url" => "https://dana.example",
      "pubkey" => Agnostic::Keys.encode(Ed25519::SigningKey.generate.verify_key.to_bytes),
      "ts" => @now, "type" => "reputablechat:identity:#{Agnostic::Rules::VERSION}"
    })
    alpha.ingest.submit(note)
    alpha.ingest.submit(person)
    refute_includes known(alpha), "https://dana.example"
  end

  def test_a_learned_address_that_answers_as_another_account_is_not_synced_with
    alpha = at("alpha")
    beta = at("beta", peers: ["http://alpha"])
    beta.beat_and_sync
    network.apps["http://beta"] = at("impostor").app

    alpha.beat_and_sync
    assert_equal 1, alpha.store.peer("http://beta")[:failures]
  end

  def test_learned_servers_are_capped
    settings = Agnostic::Settings.new({ "peers" => { "max_learned" => "1" } }, env: {})
    alpha = at("alpha")
    alpha.peers.instance_variable_set(:@settings, settings)
    at("beta", peers: ["http://alpha"]).beat_and_sync
    at("gamma", peers: ["http://alpha"]).beat_and_sync

    assert_includes known(alpha), "http://beta"
    refute_includes known(alpha), "http://gamma"
  end

  # --- reachability ---------------------------------------------------------------

  def test_an_unreachable_server_is_tried_less_and_less_often
    alpha = at("alpha", peers: ["http://nowhere"])
    delays = 4.times.map do
      @now = [alpha.store.peer("http://nowhere")[:next_attempt_at], @now].max
      alpha.peers.pull_all
      alpha.store.peer("http://nowhere")[:next_attempt_at] - @now
    end
    assert_equal [600, 1_200, 2_400, 4_800], delays
  end

  def test_the_retry_schedule_is_configurable
    settings = Agnostic::Settings.new({ "peers" => { "retry" => { "first_seconds" => "60", "multiplier" => "1.5",
                                                                  "max_seconds" => "100" } } }, env: {})
    peers = Agnostic::Peers.new(store: Agnostic::Store.new("sqlite:/"), ingest: Struct.new(:x) { def on_accept; end }.new,
                                settings: settings)
    assert_equal [60, 90, 100], [1, 2, 3].map { |n| peers.retry_delay(n) }
  end

  # Forgotten at the first failed try once a week has gone by unreached.
  def test_a_server_unreached_for_a_week_is_forgotten
    alpha = at("alpha", peers: ["http://nowhere"])
    alpha.peers.pull_all
    @now += 604_799
    alpha.peers.pull_all
    refute alpha.store.peer("http://nowhere")[:forgotten]

    @now = alpha.store.peer("http://nowhere")[:next_attempt_at]
    alpha.peers.pull_all
    assert alpha.store.peer("http://nowhere")[:forgotten]
    refute_includes alpha.peers.urls, "http://nowhere"
  end

  def test_a_forgotten_server_that_declares_itself_again_is_tried_again
    alpha = at("alpha")
    beta = at("beta", peers: ["http://alpha"])
    beta.beat_and_sync
    alpha.store.update_peer("http://beta", forgotten: true)

    redeclared = beta.host.sign("identity", { "ack" => [beta.heartbeat.previous.digest], "title" => "beta",
                                              "body" => "", "url" => "http://beta", "ts" => @now })
    alpha.ingest.submit(redeclared)
    refute alpha.store.peer("http://beta")[:forgotten]
  end

  def test_a_server_that_reaches_this_one_is_not_offline
    alpha = at("alpha")
    beta = at("beta", peers: ["http://alpha"])
    beta.beat_and_sync
    alpha.store.update_peer("http://beta", failures: 3, next_attempt_at: @now + 9_999)

    @now += 600
    beta.beat_and_sync
    assert_equal 0, alpha.store.peer("http://beta")[:failures]
    assert_includes alpha.peers.urls, "http://beta"
  end
end
