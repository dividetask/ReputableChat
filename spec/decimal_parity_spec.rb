# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/reputation/decimals"
require "open3"
require "json"

# A score is published as a decimal string inside a signed record. Ruby writes
# them from the genesis CLI and the browser writes them from a vault, and the
# two must spell the same number the same way -- not merely parse each other's.
#
# They already differed once: Ruby's BigDecimal#to_s("F") writes "1.0" where the
# browser writes "1". Nothing broke, because both parsers read both. That is
# exactly what makes it worth a test: the first thing to compare two published
# scores as text, or to key anything by one, would find the two producers
# disagreeing and no test complaining.
class DecimalParitySpec < Minitest::Test
  Decimals = ReputableChat::Reputation
  SCRIPT   = File.expand_path("decimal_parity.mjs", __dir__)
  SCALE    = 18

  # Whole numbers, the trailing-zero cases, both signs, and the smallest value
  # the scale can hold.
  VALUES = %w[
    0 1 -1 2 0.5 -0.5 1.0 0.50 0.45 -0.045 0.0004 0.000000000000000001 123.456 -123.4560
  ].freeze

  def test_ruby_and_javascript_spell_a_published_score_identically
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    stdout, stderr, status = Open3.capture3("node", SCRIPT, stdin_data: JSON.generate(VALUES))
    flunk "node failed: #{stderr}" unless status.success?

    ruby = VALUES.map { |text| Decimals.decimal(BigDecimal(text), SCALE) }

    JSON.parse(stdout).zip(ruby, VALUES).each do |js, rb, source|
      assert_equal js, rb, "#{source} is published as #{rb.inspect} by Ruby and #{js.inspect} by the browser"
    end
  end

  # RULE: never exponent notation. Canonical serialization refuses a float
  # because it has no single textual form across languages, and a published
  # score written as "5e-2" is that problem reintroduced as a string.
  def test_small_numbers_do_not_become_exponent_notation
    assert_equal "0.000000000000000001", Decimals.decimal(BigDecimal("1e-18"), SCALE)
    assert_equal "100000000", Decimals.decimal(BigDecimal("1e8"), SCALE)
  end

  # RULE: rounding happens at the configured scale, so a score cannot carry more
  # precision than the arithmetic that produced it.
  def test_values_are_rounded_to_the_scale
    assert_equal "0", Decimals.decimal(BigDecimal("1e-19"), SCALE)
  end
end
