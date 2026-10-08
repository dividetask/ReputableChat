# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# Servers share records both ways: each pulls what the others accepted, and
# pushes what it accepts.
class PeersSpec < Minitest::Test
  include Servers

  def setup
    @alpha = boot("alpha", peers: ["beta"])
    @beta = boot("beta", peers: ["alpha"])
  end

  def hashes(server) = server.store.since(0, limit: 1_000).map(&:digest)

  def test_a_server_pulls_what_a_peer_holds
    @alpha.heartbeat.beat
    @beta.peers.pull_all

    assert_empty hashes(@alpha) - hashes(@beta)
  end

  def test_a_server_pushes_what_it_accepts
    @alpha.heartbeat.beat
    @alpha.peers.push_pending

    assert_empty hashes(@alpha) - hashes(@beta)
  end

  def test_a_pull_resumes_from_where_the_last_one_stopped
    @beta.peers.pull_all
    before = @beta.store.peer_cursor("http://alpha")
    @alpha.heartbeat.beat
    @beta.peers.pull_all

    assert_operator @beta.store.peer_cursor("http://alpha"), :>, before
    assert @beta.store.known?(@alpha.heartbeat.previous.digest)
  end

  def test_missing_ancestors_are_fetched_from_the_peer_by_hash
    @alpha.heartbeat.beat
    beat = @alpha.heartbeat.previous
    result = @beta.ingest.submit(beat, source: "http://alpha")
    assert_equal :pending, result.status

    @beta.peers.fetch_missing("http://alpha", result.missing, 10)
    assert @beta.store.known?(beat.digest)
  end

  def test_a_record_is_not_pushed_back_to_the_peer_it_came_from
    @alpha.heartbeat.beat
    @beta.peers.pull_all
    pushed = []
    @network.define_singleton_method(:call) { |method, address, body| pushed << address if method == :post; super(method, address, body) }
    @beta.peers.push_pending

    assert_empty pushed
  end

  def test_both_servers_heartbeats_join_each_others_history
    @alpha.heartbeat.beat
    @alpha.peers.push_pending
    @beta.heartbeat.beat

    assert @beta.store.closure([@beta.heartbeat.previous.digest]).include?(@alpha.heartbeat.previous.digest)
  end
end
