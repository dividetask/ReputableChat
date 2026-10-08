# frozen_string_literal: true

require_relative "spec_helper"
require "agnostic/heartbeat"

# This server's own heartbeats.
class HeartbeatSpec < Minitest::Test
  include ChainHelpers

  def setup
    setup_chain
    declaration = declare("server")
    @host = Agnostic::HostAccount.new(signing_key: key("server"), declaration: declaration)
    @heartbeat = Agnostic::Heartbeat.new(store: @store, ingest: @ingest, host: @host, settings: @settings,
                                         clock: -> { @now })
    @bob = declare("bob").digest
  end

  def own_beats = @store.by_account(@host.id, kind: "heartbeat")

  def test_the_first_heartbeat_acknowledges_everything_nothing_else_does
    a = accept(post("bob", @bob, ack: [@bob], body: "a"))
    b = accept(post("bob", @bob, ack: [@bob], body: "b"))
    assert_equal :accepted, @heartbeat.beat.status

    assert_equal [a.digest, b.digest, @host.id].sort, own_beats.last.ack
    assert_equal [own_beats.last.digest], @store.frontier.map(&:digest)
  end

  def test_a_heartbeat_waits_for_its_interval_then_acks_the_last_one
    @heartbeat.beat
    @now += 599
    assert_nil @heartbeat.beat
    @now += 1
    accept(post("bob", @bob, ack: [own_beats.last.digest]))
    @heartbeat.beat

    assert_equal 2, own_beats.size
    assert_includes own_beats.last.ack, own_beats.first.digest
  end

  def test_the_interval_never_drops_below_the_rules_floor
    settings = Agnostic::Settings.new({ "heartbeat" => { "interval_seconds" => "60" } }, env: {})
    assert_equal 480, settings.integer("heartbeat", "interval_seconds")
  end

  def test_a_heartbeat_does_not_name_a_release
    load_examples
    @heartbeat.beat
    assert(own_beats.last.ack.none? { |h| @store.fetch(h).release? })
  end

  # Another server's heartbeats went 256 past a record nobody joined in time.
  def relay_leaves_behind(joined)
    other = Agnostic::HostAccount.new(signing_key: key("relay"), declaration: declare("relay", ack: [@bob]))
    beats = [accept(other.sign("heartbeat", { "ack" => [other.id, *joined].sort, "body" => "", "ts" => @now }))]
    stale = accept(post("bob", @bob, ack: [beats.first.digest], body: "left behind"))
    257.times { beats << accept(other.sign("heartbeat", { "ack" => [beats.last.digest], "body" => "", "ts" => @now += 480 })) }
    [stale, beats.last]
  end

  def test_a_heartbeat_leaves_out_a_record_another_servers_heartbeats_orphaned
    stale, newest = relay_leaves_behind([@host.id])
    result = @heartbeat.beat

    assert_equal :accepted, result.status, result.problems.inspect
    refute_includes own_beats.last.ack, stale.digest
    assert_includes own_beats.last.ack, newest.digest
  end

  # When the record left behind is this server's own, it is on that side of
  # the split, and it is the other server's heartbeats it cannot hold.
  def test_a_heartbeat_stays_on_the_side_of_the_split_its_own_account_is_on
    _, newest = relay_leaves_behind([])
    result = @heartbeat.beat

    assert_equal :accepted, result.status, result.problems.inspect
    assert_includes own_beats.last.ack, @host.id
    refute_includes own_beats.last.ack, newest.digest
  end
end
