# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# A new server catches up by sweeping the chain before going live. Generations
# are counted by one heartbeat account and come out the same on every server
# holding its heartbeats, so a sweep can take them from several at once.
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

  def sweep_of(server, generation, part, account: @alpha.host.id)
    response = Rack::MockRequest.new(server.app).get("/api/sweep?account=#{account}&generation=#{generation}&part=#{part}")
    [response.status, JSON.parse(response.body), response.headers]
  end

  def whole_sweep(server)
    position = { "generation" => 1, "part" => 0 }
    parts = []
    while position
      _, body = sweep_of(server, position["generation"], position["part"])
      parts << body["records"].map { |r| r["hash"] }
      position = body["next"]
    end
    parts
  end

  def generation(server, record, account: @alpha.host.id)
    server.store.db[:generations].where(account: account, record: record.digest).get(:generation)
  end

  def hashes(server) = server.store.since(0, limit: 10_000).map(&:digest)

  def cap(server, size) = server.settings.instance_variable_get(:@values)["limits"]["sweep_records"] = size

  def test_each_heartbeat_starts_a_generation_of_what_it_brought_into_the_history
    beat
    first = @alpha.heartbeat.previous
    later = note("after the first heartbeat")
    beat

    assert_equal 1, generation(@alpha, @alpha.genesis)
    assert_equal 1, generation(@alpha, first)
    assert_equal 2, generation(@alpha, later)
    assert_equal 2, generation(@alpha, @alpha.heartbeat.previous)
  end

  def test_a_generation_comes_in_capped_parts_parents_first
    beat
    4.times { |i| note("note #{i}") }
    beat
    cap(@alpha, 2)

    parts = whole_sweep(@alpha)
    assert(parts.all? { |p| p.size <= 2 })
    swept = parts.flatten
    assert_equal hashes(@alpha).sort, swept.sort
    seqs = swept.map { |h| @alpha.store.fetch(h).seq }
    assert_equal seqs.sort, seqs, "a record came before something it acknowledges"
  end

  # The same generation, in the same order, from any server holding the
  # heartbeats -- part for part where the two servers' part sizes agree.
  def test_another_server_holding_the_heartbeats_serves_the_same_parts
    beat
    3.times { |i| note("note #{i}") }
    beat
    beta = boot("beta", clock: -> { @now })
    @alpha.store.since(0, limit: 1_000).each { |r| beta.ingest.submit(Agnostic::Record.new(payload: r.payload, signature: r.signature)) }
    cap(@alpha, 2)
    cap(beta, 2)

    assert_equal whole_sweep(@alpha), whole_sweep(beta)
  end

  def test_records_no_heartbeat_holds_yet_wait_for_the_next_one
    beat
    pending = note("not yet in a heartbeat")
    _, body = sweep_of(@alpha, 1, 0)
    refute_includes body["records"].map { |r| r["hash"] }, pending.digest
    assert_nil body["next"]
  end

  def test_a_new_server_catches_up_from_several_servers_at_once
    beat
    6.times { |i| note("note #{i}"); beat }
    beta = boot("beta", clock: -> { @now })
    @alpha.store.since(0, limit: 1_000).each { |r| beta.ingest.submit(Agnostic::Record.new(payload: r.payload, signature: r.signature)) }

    asked = Hash.new(0)
    real = network.method(:call)
    network.define_singleton_method(:call) do |method, address, body|
      asked[URI(address).host] += 1 if address.include?("/api/sweep")
      real.call(method, address, body)
    end
    fresh = boot("fresh", peers: %w[alpha beta], clock: -> { @now })
    fresh.send(:catch_up)

    assert_empty hashes(@alpha) - hashes(fresh)
    assert_operator asked["alpha"], :>, 1
    assert_operator asked["beta"], :>, 1, "only one server was swept"
  end

  def test_an_interrupted_sweep_resumes_where_it_stopped
    beat
    4.times { |i| note("note #{i}"); beat }
    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now })

    calls = 0
    real = network.method(:call)
    network.define_singleton_method(:call) do |method, address, body|
      raise "connection dropped" if address.include?("/api/sweep") && (calls += 1) == 4

      real.call(method, address, body)
    end
    fresh.peers.catch_up(["http://alpha"])
    stopped = fresh.store.meta("sweep:#{@alpha.host.id}").to_i
    assert_operator stopped, :>, 1
    refute_empty hashes(@alpha) - hashes(fresh)

    network.define_singleton_method(:call) { |method, address, body| real.call(method, address, body) }
    fresh.store.update_peer("http://alpha", next_attempt_at: 0, failures: 0)
    fresh.send(:catch_up)
    assert_empty hashes(@alpha) - hashes(fresh)
  end

  def test_a_caller_asking_too_often_is_told_how_long_to_wait
    @alpha.settings.instance_variable_get(:@values)["limits"]["sweep_requests_per_minute"] = 2
    app = @alpha.app
    statuses = 3.times.map { Rack::MockRequest.new(app).get("/api/sweep", "REMOTE_ADDR" => "203.0.113.9") }
    assert_equal [200, 200, 429], statuses.map(&:status)
    assert_equal "60", statuses.last.headers["retry-after"]
    assert_equal 200, Rack::MockRequest.new(app).get("/api/sweep", "REMOTE_ADDR" => "203.0.113.10").status
    @now += 60
    assert_equal 200, Rack::MockRequest.new(app).get("/api/sweep", "REMOTE_ADDR" => "203.0.113.9").status
  end

  def test_a_server_told_to_wait_waits_and_asks_again
    beat
    @alpha.settings.instance_variable_get(:@values)["limits"]["sweep_requests_per_minute"] = 1
    network.apps["http://alpha"] = @alpha.app
    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now })
    waited = []
    fresh.peers.instance_variable_set(:@sleeper, ->(s) { waited << s; @now += s })
    fresh.send(:catch_up)

    refute_empty waited
    assert_empty hashes(@alpha) - hashes(fresh)
  end
end

# Behind a reverse proxy every request arrives from the proxy, so the limit
# would be shared by everyone unless the proxy is named and believed.
class TrustedProxySpec < Minitest::Test
  include Servers

  def app_with(proxies)
    server = boot("alpha", host: { "url" => "http://alpha" })
    server.settings.instance_variable_get(:@values)["limits"].merge!("sweep_requests_per_minute" => 1,
                                                                      "trusted_proxies" => proxies)
    server.app
  end

  def ask(app, forwarded)
    Rack::MockRequest.new(app).get("/api/sweep", "REMOTE_ADDR" => "10.0.0.2", "HTTP_X_FORWARDED_FOR" => forwarded).status
  end

  def test_callers_behind_a_named_proxy_are_limited_one_by_one
    app = app_with(["10.0.0.2"])
    assert_equal [200, 200, 429], [ask(app, "203.0.113.1"), ask(app, "203.0.113.2"), ask(app, "203.0.113.1")]
  end

  def test_a_forwarded_address_from_a_proxy_not_named_is_not_believed
    app = app_with([])
    assert_equal [200, 429], [ask(app, "203.0.113.1"), ask(app, "203.0.113.2")]
  end
end

# Once caught up, a server looks at each of its servers' latest records for a
# chain split. Until then -- and after a split, until an administrator has
# picked a side -- it is not live: it has declared nothing and answers no one.
class SplitCheckSpec < Minitest::Test
  include Servers

  def setup
    @now = Time.now.to_i
  end

  def status(server) = Rack::MockRequest.new(server.app).get("/api").status

  def test_until_caught_up_a_server_has_no_declaration_and_answers_no_one
    alpha = boot("alpha", clock: -> { @now }, host: { "url" => "http://alpha" })
    alpha.beat_and_sync
    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now }, live: false)

    refute fresh.host.declared?
    assert_equal 503, status(fresh)
    assert_nil fresh.beat_and_sync

    fresh.catch_up
    assert fresh.live?
    assert_equal 200, status(fresh)
    assert_equal :accepted, fresh.beat_and_sync.status
  end

  # A declaration acknowledging only the genesis would be left behind by any
  # server with more than 256 heartbeats, so it acknowledges where the chain is.
  def test_the_declaration_acknowledges_the_latest_heartbeats_it_caught_up_to
    alpha = boot("alpha", clock: -> { @now }, host: { "url" => "http://alpha" })
    alpha.beat_and_sync
    fresh = boot("fresh", peers: ["alpha"], clock: -> { @now }, live: false)
    fresh.catch_up

    assert_includes fresh.host.declaration.ack, alpha.heartbeat.previous.digest
  end

  # Relay's heartbeats went 256 past a record alpha's latest records still
  # hold: the two servers are on different sides of a split.
  def split_network
    alpha = boot("alpha", clock: -> { @now }, host: { "url" => "http://alpha" })
    alpha.beat_and_sync
    relay = boot("relay", clock: -> { @now }, host: { "url" => "http://relay" })
    first = relay.host.sign("heartbeat", { "ack" => [relay.host.id], "body" => "", "ts" => @now })
    relay.ingest.submit(first)
    alpha.ingest.submit(first)
    stale = alpha.host.sign("message", { "ack" => [alpha.heartbeat.previous.digest, first.digest].sort,
                                         "body" => "left behind", "ts" => @now })
    alpha.ingest.submit(stale)
    beats = [first]
    257.times do
      @now += 480
      beats << relay.host.sign("heartbeat", { "ack" => [beats.last.digest], "body" => "", "ts" => @now })
      relay.ingest.submit(beats.last)
    end
    [alpha, relay, beats.last]
  end

  def test_a_split_stops_the_server_until_the_administrator_picks_a_side
    _, relay, newest = split_network
    fresh = boot("fresh", peers: %w[alpha relay], clock: -> { @now }, live: false)
    fresh.catch_up

    assert_equal :halted, fresh.state
    assert(fresh.halted["problems"].any? { |p| p.include?("orphaned") })
    refute fresh.host.declared?
    assert_equal 503, status(fresh)
    assert_equal({ "http://alpha" => [:left_behind], "http://relay" => [:went_on] }, fresh.sides)

    fresh.choose("http://relay")
    fresh.wait_for_choice
    assert fresh.live?
    assert fresh.store.peer("http://alpha")[:forgotten], "the server on the other side is still synced with"
    refute fresh.store.peer("http://relay")[:forgotten]
    assert_includes fresh.host.declaration.ack, newest.digest
    assert_equal :accepted, fresh.beat_and_sync.status
    assert relay.store.known?(fresh.heartbeat.previous.digest)
  end

  # The same check runs on every start, so a server offline through a split
  # wakes up stopped rather than picking a side by itself.
  def test_a_stop_survives_a_restart
    split_network
    fresh = boot("fresh", peers: %w[alpha relay], clock: -> { @now }, live: false)
    fresh.catch_up
    again = Agnostic::Server.new(settings: fresh.settings, clock: -> { @now }, http: network)
    again.catch_up

    assert_equal :halted, again.state
  end
end
