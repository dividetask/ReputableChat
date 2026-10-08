# frozen_string_literal: true

require_relative "spec_helper"
require "agnostic/accounts"

# docs/project/rules/v0.001-examples.md is the rules in bytes. Every record in
# it is valid under the rules it is an example of, so this server must accept
# each one -- except the release that builds on another release, whose rules
# (v0.002) this server does not implement and so cannot check.
class ExamplesSpec < Minitest::Test
  include ChainHelpers

  def setup = setup_chain

  def test_the_server_accepts_every_example_whose_rules_it_implements
    results = Examples.records.drop(1).map { |r| [r, @ingest.submit(r)] }
    refused = results.reject { |_, result| result.status == :accepted }

    assert_equal 1, refused.size, refused.map { |r, x| "#{r.digest[0, 8]}: #{x.problems.inspect}" }.join("\n")
    record, result = refused.first
    assert_equal "reputablechat:release:v0.003", record["type"]
    assert_match(/does not implement/, result.problems.first)
  end

  def test_the_example_chain_is_read_in_full
    assert_operator Examples.records.size, :>, 40
  end

  # Exactly one example signs with a key a change superseded: the thief still
  # signing after Dana moved her working key.
  def test_one_example_contests_a_key_change_and_only_one
    load_examples
    contests = @store.db[:records].where(Sequel.like(:facts, '%"contests":[%')).select_map(:signer)
    assert_equal [pub("dana-thief")], contests
  end

  # A checker that has quietly stopped looking accepts everything, so records
  # written to break one rule each must be refused, and for that rule.
  def test_each_broken_example_is_refused_for_the_rule_it_breaks
    load_examples
    expected = { "early" => /480 seconds/, "unsorted" => /sorted/, "unbalanced" => /spends 99 and makes 98/ }

    assert_equal expected.keys.sort, Examples.broken.keys.sort
    Examples.broken.each { |name, record| refuse(record, expected.fetch(name)) }
  end

  # The states the examples describe in prose. Dana's change is confirmed, and
  # with it the thief's change it superseded, which was never disputed; the
  # thief's message, which was, is void. Of Alice's double spend the payment
  # stands and the lunch is void. Alice's own earlier key change is in the
  # history of the one her quorum named, so it is confirmed too, and the
  # release she signed with its key is untouched.
  def test_the_states_the_examples_describe
    load_examples
    accounts = Agnostic::Accounts.new(store: @store, genesis: @genesis)
    state = ->(prefix) { accounts.state(Examples.records.find { |r| r.digest.start_with?(prefix) }.digest) }

    assert_equal "confirmed", state.call("2e59fd55"), "the thief's key change, superseded by Dana's"
    assert_equal "void", state.call("a14714e2"), "the thief's message"
    assert_equal "confirmed", state.call("e39a3e42"), "Dana's key change"
    assert_equal "confirmed", state.call("9cb36d78"), "Alice's payment"
    assert_equal "void", state.call("9cfb8f27"), "Alice's lunch"
    assert_equal "void", state.call("35eb6dbc"), "the change made with Alice's stolen master key"
    assert_equal "confirmed", state.call("f2409cdf"), "Alice's earlier change, in the named one's history"
    assert_equal "valid", state.call("1045791a"), "the release Alice signed with that change's key"
  end
end
