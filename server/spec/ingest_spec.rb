# frozen_string_literal: true

require_relative "spec_helper"

# How records arrive: accepted, held for their ancestors, or refused.
class IngestSpec < Minitest::Test
  include ChainHelpers

  def setup
    setup_chain(settings: Agnostic::Settings.new({ "pending" => { "max_records" => "2" } }, env: {}))
    @bob = declare("bob").digest
  end

  def test_a_record_already_held_is_known_rather_than_accepted_twice
    record = accept(post("bob", @bob, ack: [@bob]))
    assert_equal :known, @ingest.submit(record).status
  end

  # Guideline, section 10.
  def test_a_record_far_ahead_of_the_servers_clock_is_refused
    refuse(post("bob", @bob, ack: [@bob], ts: @now + 601), /ahead of this server's clock/)
    accept(post("bob", @bob, ack: [@bob], ts: @now + 600))
  end

  def test_a_record_signed_long_ago_is_accepted_when_it_arrives_late
    accept(post("bob", @bob, ack: [@bob], ts: 1))
  end

  def test_held_records_are_bounded
    missing = Array.new(3) { |i| Digest::SHA256.hexdigest("missing #{i}") }
    2.times { |i| assert_equal :pending, @ingest.submit(post("bob", @bob, ack: [missing[i]])).status }
    refuse(post("bob", @bob, ack: [missing[2]]), /holding as many records/)
  end

  def test_held_records_expire
    assert_equal :pending, @ingest.submit(post("bob", @bob, ack: [Digest::SHA256.hexdigest("x")])).status
    @now += 3_601
    @ingest.expire
    assert_equal 0, @store.pending_count
  end

  def test_a_held_record_that_turns_out_invalid_is_dropped
    parent = post("bob", @bob, ack: [@bob], body: "parent")
    child = post("mallory", @bob, ack: [parent.digest])
    assert_equal :pending, @ingest.submit(child).status
    accept(parent)
    assert_equal 0, @store.pending_count
    refute @store.known?(child.digest)
  end

  def test_records_are_served_byte_identical
    record = accept(post("bob", @bob, ack: [@bob], body: "café \u{1F600}"))
    stored = @store.fetch(record.digest)
    assert_equal record.payload.b, stored.payload.b
    assert_equal record.signature, stored.signature
  end
end
