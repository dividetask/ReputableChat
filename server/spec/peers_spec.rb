# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# Servers sync after each heartbeat: push what they accepted, offer the
# heartbeat, answer what the peer is missing, and pull what the peer holds.
class PeersSpec < Minitest::Test
  include Servers

  def setup
    @now = Time.now.to_i
    @alpha = boot("alpha", peers: ["beta"], clock: -> { @now })
    @beta = boot("beta", peers: ["alpha"], clock: -> { @now })
  end

  def hashes(server) = server.store.since(0, limit: 1_000).map(&:digest)

  # The server that shares a heartbeat is asked for its history; it asks the
  # other for nothing, which shares its own records with its own heartbeat.
  def test_sharing_a_heartbeat_gives_the_peer_its_whole_history_and_takes_nothing
    @alpha.beat_and_sync
    assert_empty hashes(@alpha) - hashes(@beta), "beta lacks what alpha holds"
    refute @alpha.store.known?(@beta.host.id), "alpha pulled from beta"

    @beta.beat_and_sync
    assert_empty hashes(@beta) - hashes(@alpha)
  end

  def test_the_peer_asks_for_every_record_of_the_history_it_lacks
    @alpha.heartbeat.beat
    @now += 600
    3.times { |i| @alpha.ingest.submit(@alpha.host.sign("message", { "ack" => [@alpha.store.frontier.last.digest], "body" => "#{i}", "ts" => @now })) }
    @alpha.heartbeat.beat

    @alpha.peers.sync(@alpha.heartbeat.previous)
    assert @beta.store.known?(@alpha.heartbeat.previous.digest)
    assert_empty hashes(@alpha) - hashes(@beta)
  end

  def test_records_accepted_between_heartbeats_are_pushed_with_the_next_one
    @alpha.beat_and_sync
    note = @alpha.host.sign("message", { "ack" => [@alpha.heartbeat.previous.digest], "body" => "Hello.", "ts" => @now })
    assert_equal :accepted, @alpha.ingest.submit(note).status
    refute @beta.store.known?(note.digest)

    @now += 600
    @alpha.beat_and_sync
    assert @beta.store.known?(note.digest)
  end

  def test_the_peer_is_sent_what_it_says_it_is_missing
    @alpha.heartbeat.beat
    beat = @alpha.heartbeat.previous

    @alpha.peers.sync(beat)
    assert @beta.store.known?(beat.digest)
  end

  def test_both_servers_heartbeats_join_each_others_history
    @alpha.beat_and_sync
    @beta.beat_and_sync

    assert @beta.store.closure([@beta.heartbeat.previous.digest]).include?(@alpha.heartbeat.previous.digest)
  end

  def test_a_pull_resumes_from_where_the_last_one_stopped
    @beta.peers.pull_all
    before = @beta.store.peer_cursor("http://alpha")
    @alpha.heartbeat.beat
    @beta.peers.pull_all

    assert_operator @beta.store.peer_cursor("http://alpha"), :>, before
  end

  def test_missing_ancestors_are_fetched_from_the_peer_by_hash
    @alpha.heartbeat.beat
    beat = @alpha.heartbeat.previous
    result = @beta.ingest.submit(beat, source: "http://alpha")
    assert_equal :pending, result.status

    @beta.peers.fetch_missing("http://alpha", result.missing, 10)
    assert @beta.store.known?(beat.digest)
  end

  # --- clocks -------------------------------------------------------------------

  def offer(from, to, beat)
    Rack::MockRequest.new(to.app).post("/api/sync", input: JSON.generate("heartbeat" => beat.to_wire),
                                                    "CONTENT_TYPE" => "application/json")
  end

  def skewed_beat(server, seconds)
    server.host.sign("heartbeat", { "ack" => [server.host.id], "body" => "", "ts" => @now + seconds })
  end

  def test_a_heartbeat_within_ten_minutes_of_the_clock_is_taken
    @beta.peers.pull_all
    response = offer(@alpha, @beta, skewed_beat(@alpha, -600))
    assert_equal 200, response.status, response.body
    refute @beta.store.ignored?(@alpha.host.id, at: @now)
  end

  def test_a_server_whose_heartbeat_is_more_than_ten_minutes_off_is_ignored
    @beta.peers.pull_all
    [-601, 601].each do |skew|
      @beta.store.forgive(@alpha.host.id)
      response = offer(@alpha, @beta, skewed_beat(@alpha, skew))
      assert_equal 403, response.status
      assert @beta.store.ignored?(@alpha.host.id, at: @now), "a heartbeat #{skew}s off did not get its server ignored"
    end
  end

  def test_an_ignored_server_is_refused_and_not_synced_with
    @beta.peers.pull_all
    offer(@alpha, @beta, skewed_beat(@alpha, -3_600))

    assert_equal 403, offer(@alpha, @beta, skewed_beat(@alpha, 0)).status
    @beta.peers.pull_all
    @alpha.heartbeat.beat
    @beta.beat_and_sync
    refute @beta.store.known?(@alpha.heartbeat.previous.digest), "beta still pulled from a server it ignores"
  end

  def test_a_server_is_ignored_for_a_week
    @beta.peers.pull_all
    offer(@alpha, @beta, skewed_beat(@alpha, -3_600))

    @now += 604_799
    assert_equal 403, offer(@alpha, @beta, skewed_beat(@alpha, 0)).status
    @now += 1
    assert_equal 200, offer(@alpha, @beta, skewed_beat(@alpha, 0)).status
  end

  # Otherwise anyone could get an honest server ignored with a forged one.
  def test_a_forged_heartbeat_does_not_get_the_server_it_names_ignored
    @beta.peers.pull_all
    forged = Agnostic::HostAccount.sign(Ed25519::SigningKey.generate, {
      "ack" => [@alpha.host.id], "body" => "", "id" => @alpha.host.id,
      "pubkey" => Agnostic::Keys.encode(Ed25519::SigningKey.generate.verify_key.to_bytes),
      "ts" => @now - 3_600, "type" => "reputablechat:heartbeat:#{Agnostic::Rules::VERSION}"
    })
    response = offer(@alpha, @beta, forged)

    assert_equal 422, response.status
    refute @beta.store.ignored?(@alpha.host.id, at: @now)
  end
end
