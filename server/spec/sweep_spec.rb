# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# A new server catches up by sweeping the chain from the servers it was given
# at setup: generation by generation, part by part, each part capped by the
# server sharing it.
class SweepSpec < Minitest::Test
  include Servers

  def setup
    @now = Time.now.to_i
    @alpha = boot("alpha", clock: -> { @now }, host: { "url" => "http://alpha" })
  end

  def note(body)
    record = @alpha.host.sign("message", { "ack" => [@alpha.store.frontier.last.digest], "body" => body, "ts" => @now })
    assert_equal :accepted, @alpha.ingest.submit(record).status
    record
  end

  def beat
    @alpha.beat_and_sync
    @now += 600
  end

  def sweep(generation, part)
    response = Rack::MockRequest.new(@alpha.app).get("/api/sweep?generation=#{generation}&part=#{part}")
    JSON.parse(response.body)
  end

  def generation(record) = @alpha.store.db[:records].where(hash: record.digest).get(:generation)

  def test_each_heartbeat_starts_a_generation_of_what_it_brought_into_the_history
    beat
    first = @alpha.heartbeat.previous
    later = note("after the first heartbeat")
    beat

    assert_equal 1, generation(@alpha.genesis)
    assert_equal 1, generation(first)
    assert_equal 2, generation(later)
    assert_equal 2, generation(@alpha.heartbeat.previous)
  end

  def test_a_sweep_serves_a_generation_in_capped_parts_parents_first
    beat
    4.times { |i| note("note #{i}") }
    beat
    @alpha.settings.instance_variable_get(:@values)["limits"]["sweep_records"] = 2

    parts = []
    position = { "generation" => 1, "part" => 0 }
    while position
      body = sweep(position["generation"], position["part"])
      assert_operator body["records"].size, :<=, 2
      parts << body["records"].map { |r| r["hash"] }
      position = body["next"]
    end

    swept = parts.flatten
    assert_equal @alpha.store.count, swept.size
    seqs = swept.map { |h| @alpha.store.fetch(h).seq }
    assert_equal seqs.sort, seqs, "a record came before something it acknowledges"
  end

  def test_records_no_heartbeat_holds_yet_wait_for_the_next_one
    beat
    pending = note("not yet in a heartbeat")
    body = sweep(1, 0)
    refute_includes body["records"].map { |r| r["hash"] }, pending.digest
    assert_nil body["next"]
  end

  def test_a_new_server_catches_up_from_the_servers_it_was_given_before_going_live
    beat
    3.times { |i| note("note #{i}") }
    beat

    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now })
    fresh.send(:catch_up)
    assert_empty @alpha.store.since(0, limit: 1_000).map(&:digest) - fresh.store.since(0, limit: 1_000).map(&:digest)
    assert fresh.store.peer("http://alpha")[:swept]
  end

  def test_an_interrupted_sweep_resumes_where_it_stopped
    beat
    5.times { |i| note("note #{i}") }
    beat
    @alpha.settings.instance_variable_get(:@values)["limits"]["sweep_records"] = 2
    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now })

    calls = 0
    real = network.method(:call)
    network.define_singleton_method(:call) do |method, address, body|
      raise "connection dropped" if address.include?("/api/sweep") && (calls += 1) == 3

      real.call(method, address, body)
    end
    fresh.send(:catch_up)
    stopped = fresh.store.peer("http://alpha")
    refute stopped[:swept]
    assert_operator stopped[:sweep_part] + stopped[:sweep_generation], :>, 1

    network.define_singleton_method(:call) { |method, address, body| real.call(method, address, body) }
    fresh.store.update_peer("http://alpha", next_attempt_at: 0, failures: 0)
    fresh.send(:catch_up)
    assert fresh.store.peer("http://alpha")[:swept]
    assert_empty @alpha.store.since(0, limit: 1_000).map(&:digest) - fresh.store.since(0, limit: 1_000).map(&:digest)
  end
end
