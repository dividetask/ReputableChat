# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/params"

class ParamsSpec < Minitest::Test
  P = ReputableChat::Params

  KEY = "a" * 43

  def test_accepts_well_formed_keys_and_rejects_everything_else
    assert_equal KEY, P.pubkey(KEY)
    assert_nil P.pubkey("has spaces!")
    assert_nil P.pubkey("short")
    assert_nil P.pubkey(nil)
    assert_nil P.pubkey(["a" * 43])
  end

  def test_strips_and_bounds_strings
    assert_equal "hello", P.string("  hello  ", max: 10)
    assert_nil P.string("", max: 10)
    assert_nil P.string("x" * 11, max: 10)
    assert_nil P.string(42, max: 10)
  end

  def test_rejects_control_characters
    assert_nil P.string("hi#{0.chr}there", max: 50)
    assert_nil P.string("bell#{7.chr}", max: 50)
  end

  def test_rejects_invalid_utf8
    assert_nil P.string(255.chr.dup.force_encoding("UTF-8"), max: 50)
  end

  def test_integers_are_range_checked
    assert_equal 42, P.integer("42", max: 100)
    assert_nil P.integer("4200", max: 100)
    assert_nil P.integer("not a number")
    assert_nil P.integer(-1)
  end

  # RULE: a signature is not a record hash. They were the same length and the
  # same shape of text before the chain existed, so anything sending the old
  # one has to be refused rather than quietly stored as something nothing can
  # be matched against. Every `ack` in the system rests on this.
  def test_a_signature_is_not_accepted_as_a_record_hash
    assert_equal "a" * 64, P.record_hash("a" * 64)

    assert_nil P.record_hash("a" * 86), "an Ed25519 signature is not a record hash"
    assert_nil P.record_hash("z" * 64), "a record hash is hex"
    assert_nil P.record_hash("a" * 63)
    assert_nil P.record_hash(nil)
  end

  def test_arrays_are_bounded
    assert_equal [KEY], P.array_of([KEY], max: 5) { |v| P.pubkey(v) }
    assert_nil P.array_of([KEY] * 6, max: 5) { |v| P.pubkey(v) }
    assert_nil P.array_of([KEY, "bad"], max: 5) { |v| P.pubkey(v) }
    assert_nil P.array_of([], max: 5) { |v| P.pubkey(v) }
  end
end
