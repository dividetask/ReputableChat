# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# What a server says of other servers, from whether it could reach them at the
# addresses their accounts declared.
class ServerRatingsSpec < Minitest::Test
  include Servers

  DAY = 86_400

  def setup
    @now = Time.now.to_i
    @alpha = boot("alpha", clock: -> { @now }, host: { "url" => "http://alpha" })
    @beta = boot("beta", peers: ["alpha"], clock: -> { @now }, host: { "url" => "http://beta" })
    @beta.beat_and_sync # alpha learns of beta from its records
  end

  def beta = @beta.host.id

  def rating(account = beta) = @alpha.ratings.due.dig(account, "reputation")

  def contact(**values)
    @alpha.store.record_contact(beta, success: false, at: @now)
    @alpha.store.db[:contacts].where(account: beta).update(values)
  end

  def test_an_address_that_never_worked_is_rated_minus_one_once_forgotten
    network.apps.delete("http://beta")
    @alpha.peers.pull_all
    assert_nil rating, "rated before it was forgotten"

    @now += 8 * DAY
    @alpha.peers.pull_all
    assert_equal "-1", rating
  end

  def test_an_address_that_worked_then_went_offline_is_rated_a_little_below_zero
    @alpha.peers.pull_all
    network.apps.delete("http://beta")
    @now += 8 * DAY
    @alpha.peers.pull_all
    assert_equal "-0.01", rating
  end

  def test_a_reliable_server_is_rated_a_little_after_four_months_and_a_little_more_after_a_year
    contact(attempts: 100, successes: 95, first_success_at: @now)
    @now += 119 * DAY
    assert_nil rating
    @now += DAY
    assert_equal "0.01", rating
    @now += 245 * DAY
    assert_equal "0.02", rating
  end

  def test_an_unreliable_server_is_not_rated
    contact(attempts: 100, successes: 80, first_success_at: @now - (400 * DAY))
    assert_nil rating
  end

  def test_ratings_are_published_as_an_attestation_only_when_they_change
    contact(attempts: 10, successes: 10, first_success_at: @now - (400 * DAY))
    result = @alpha.ratings.publish
    assert_equal :accepted, result.status

    attestation = @alpha.store.fetch(result.hash)
    assert_equal({ beta => { "reputation" => "0.02", "trust" => "0" } }, attestation["scores"])
    assert_nil @alpha.ratings.publish, "an unchanged rating was published again"
  end

  def test_the_ratings_are_configurable
    settings = Agnostic::Settings.new({ "ratings" => { "trust" => "1", "never_reached" => "-0.5" } }, env: {})
    ratings = Agnostic::ServerRatings.new(store: @alpha.store, ingest: @alpha.ingest, host: @alpha.host, settings: settings,
                                          clock: -> { @now })
    contact(offline: true)
    assert_equal({ "reputation" => "-0.5", "trust" => "0" }, ratings.due[beta], "trust is never anything but 0")
  end

  # --- withdrawing an address -----------------------------------------------------

  def redeclare(**fields)
    latest = @beta.store.by_account(beta).max_by(&:seq)
    record = @beta.host.sign("identity", { "ack" => [latest.digest], "title" => "beta", "body" => "", "ts" => @now }
                                           .merge(fields.transform_keys(&:to_s)))
    assert_equal :accepted, @beta.ingest.submit(record).status
    assert_equal :accepted, @alpha.ingest.submit(record).status
  end

  def test_a_declaration_without_a_url_removes_the_server
    assert_includes @alpha.peers.urls, "http://beta"
    redeclare
    refute_includes @alpha.peers.urls, "http://beta"
  end

  def test_a_declaration_with_a_new_url_replaces_the_old_one
    redeclare(url: "http://beta-two")
    refute_includes @alpha.peers.urls, "http://beta"
    assert_includes @alpha.peers.urls, "http://beta-two"
  end

  # --- timing ---------------------------------------------------------------------

  def test_the_server_waits_until_its_next_heartbeat_is_due
    assert_equal 600, @beta.heartbeat.seconds_until_due
    @now += 599
    assert_nil @beta.beat_and_sync
    @now += 1
    assert_equal :accepted, @beta.beat_and_sync.status
  end
end
