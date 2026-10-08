# frozen_string_literal: true

require_relative "spec_helper"
require "servers"
require "agnostic/manual_ratings"

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

  # --- ratings by hand ------------------------------------------------------------

  def by_hand = Agnostic::ManualRatings.new(@alpha.store, clock: -> { @now })

  def published(account = beta) = @alpha.store.published_rating(account)&.values_at(:reputation, :trust)

  # The operator decides, trust included, and the server publishes it as it
  # would its own rating.
  def test_a_rating_by_hand_stands_in_for_reachability_trust_included
    contact(attempts: 100, successes: 95, first_success_at: @now - (400 * DAY))
    by_hand.set(beta, "-0.5", "1")

    assert_equal({ "reputation" => "-0.5", "trust" => "1", "source" => "operator" }, @alpha.ratings.current[beta])
    @alpha.ratings.publish
    assert_equal %w[-0.5 1], published
  end

  def test_removing_a_rating_by_hand_hands_it_back_to_reachability
    contact(attempts: 100, successes: 95, first_success_at: @now - (400 * DAY))
    by_hand.set(beta, "-0.5", "1")
    @alpha.ratings.publish
    by_hand.clear(beta)

    assert_equal "reachability", @alpha.ratings.current[beta]["source"]
    @alpha.ratings.publish
    assert_equal %w[0.02 0], published
  end

  # An attestation amends an entry but cannot delete one, so an account
  # nobody has an opinion of any more is published as 0 with trust 0.
  def test_removing_the_only_opinion_publishes_zero
    stranger = "c" * 64
    by_hand.set(stranger, "0.3", "0.5")
    @alpha.ratings.publish
    by_hand.clear(stranger)
    @alpha.ratings.publish

    assert_equal %w[0 0], published(stranger)
  end

  def test_a_rating_by_hand_is_a_decimal_from_minus_one_to_one_for_an_account
    assert_raises(ArgumentError) { by_hand.set("not an account", "0.5", "1") }
    %w[.5 1.5 0.50].each { |bad| assert_raises(ArgumentError) { by_hand.set(beta, bad, "1") } }
    assert_raises(ArgumentError) { by_hand.set(beta, "0.5", "2") }
  end

  # The apps beside the server read its ratings to choose their own peers.
  def test_the_ratings_are_served_to_the_apps_beside_the_server
    by_hand.set(beta, "0.4", "0")
    response = Rack::MockRequest.new(@alpha.app).get("/api/ratings")

    assert_equal "0.4", JSON.parse(response.body).dig("ratings", beta, "reputation")
  end

  # --- what the apps beside the server report -----------------------------------

  def report(reached:, key: nil, account: beta, ts: @now)
    payload = JSON.generate("purpose" => "reputablechat:contact:v1", "account" => account, "reached" => reached, "ts" => ts)
    signature = Agnostic::Keys.sign(key || @alpha.host.signing_key, payload)
    Rack::MockRequest.new(@alpha.app).post("/api/contacts", input: JSON.generate("payload" => payload, "signature" => signature),
                                                           "CONTENT_TYPE" => "application/json")
  end

  # RULE (yours): what the chat finds fetching files counts toward the
  # account's rating, as the server's own contacts do.
  def test_an_apps_report_counts_with_the_servers_own_contacts
    before = @alpha.store.contact(beta)&.fetch(:attempts) || 0
    assert_equal 200, report(reached: true).status
    assert_equal 200, report(reached: false).status

    contact = @alpha.store.contact(beta)
    assert_equal before + 2, contact[:attempts]
  end

  # Only the apps on this machine hold the host account's key, so nobody else
  # can move a rating by reporting.
  def test_a_report_not_signed_by_the_host_account_is_refused
    assert_equal 403, report(reached: false, key: Ed25519::SigningKey.generate).status
    assert_equal 400, report(reached: false, ts: @now - 3_600).status
  end
end
