# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "tmpdir"
require "reputable_chat/chain/ledger"

# The example chain is the only place the rules are written down in bytes rather
# than in prose, so it is the only place a machine can tell when the two have
# drifted apart. Three rules changed under it during one afternoon's editing and
# nothing failed; the records were checked by a script that lived outside the
# repository and went stale with them.
#
# spec/examples.mjs does the checking and prints a line per problem. This spec
# asserts there are none, asserts the chain still contains what the file claims
# it does, and -- because a checker that silently stops looking passes
# everything -- asserts that it rejects records written to break a rule.
class ExamplesSpec < Minitest::Test
  SCRIPT   = File.expand_path("examples.mjs", __dir__)
  EXAMPLES = File.expand_path("../docs/project/rules/v0.001-examples.md", __dir__)
  BROKEN   = File.expand_path("fixtures/examples_broken.md", __dir__)

  def test_the_example_chain_breaks_no_rule_it_is_an_example_of
    skip "node is not installed" unless node?

    assert_empty problems, "the example records no longer satisfy the rules"
  end

  # Guards the failure that would make every other assertion here worthless: a
  # checker whose parsing has broken sees no records and reports no problems.
  def test_the_checker_reads_every_record_in_the_file
    skip "node is not installed" unless node?

    counted = read(EXAMPLES).scan(/\n```\npayload:   /).size
    assert_operator counted, :>, 40, "the file should hold the whole example chain"
    assert_equal counted, report("RECORDS").first.to_i, "the checker did not read every record"
  end

  def test_the_file_holds_at_least_three_examples_of_each_record_type
    skip "node is not installed" unless node?

    kinds = report("KIND").map { |line| line.split("\t") }
    assert_equal %w[attestation heartbeat identity message notice reaction release],
                 kinds.map(&:first).sort
    kinds.each { |kind, n| assert_operator n.to_i, :>=, 3, "only #{n} #{kind} examples" }
  end

  # The sequence the working key's rules turn on: a key still signing after a
  # change replaced it, which disputes the account. Exactly one example does it,
  # and if the count moves, either the examples or that rule has changed.
  def test_one_example_contests_a_key_change_and_only_one
    skip "node is not installed" unless node?

    contests = report("CONTEST")
    assert_equal 1, contests.size, "contests: #{contests.inspect}"
    assert_includes contests.first, "dana-thief"
  end

  def test_a_record_that_breaks_a_rule_is_rejected
    skip "node is not installed" unless node?

    Dir.mktmpdir do |dir|
      path = File.join(dir, "examples.md")
      File.write(path, read(EXAMPLES) + read(BROKEN))
      found = run_checker(path).grep(/^PROBLEM/)

      broken = read(BROKEN).scan(/^hash:      (\h{64})$/).flatten
      assert_equal 3, broken.size, "the fixture should hold three broken records"
      broken.each do |hash|
        assert found.any? { |line| line.include?(hash[0, 8]) },
               "the checker accepted #{hash[0, 8]}, which breaks a rule"
      end
    end
  end

  # --- the server's own validator -------------------------------------------
  #
  # The checker above is a second implementation, written to read the file. The
  # one that decides what a server accepts is Chain::Ledger, so the examples go
  # through that too: every record valid, and each broken one refused for the
  # rule it breaks.

  # The examples carry releases of 0.002 and 0.003, whose own rules are not
  # implemented here; a release is still judged by the version it follows.
  VERSIONS = %w[v0.001 v0.002 v0.003].freeze

  def test_the_server_accepts_every_example
    records = records_in(read(EXAMPLES))
    ledger = ReputableChat::Chain::Ledger.new(genesis: records.first, versions: VERSIONS)

    records.drop(1).each do |record|
      ledger.add(record)
    rescue ReputableChat::Chain::Invalid => e
      flunk "the server refuses example #{record.record_hash[0, 8]}: #{e.message}"
    end
    assert_equal records.size, ledger.size
  end

  def test_the_server_refuses_each_broken_example
    records = records_in(read(EXAMPLES))
    ledger = ReputableChat::Chain::Ledger.new(genesis: records.first, versions: VERSIONS)
    records.drop(1).each { |record| ledger.add(record) }

    reasons = read(BROKEN).scan(/```\npayload:   (.+?)\nsignature: (\S+)\nhash:      (\S+)\n```/m).map do |payload, signature, _|
      ledger.add(ReputableChat::Chain::Record.parse(payload, signature))
      flunk "the server accepted a broken example"
    rescue ReputableChat::Chain::Invalid => e
      e.message
    end

    assert_match(/at least 480 seconds/, reasons[0])
    assert_match(/ack is not sorted/, reasons[1])
    assert_match(/spends 99 and makes 98/, reasons[2])
  end

  # The states the examples describe in prose: the thief's key change and the
  # message signed with its key are void, Dana's change is confirmed, and of
  # Alice's double spend the payment stands and the lunch is void.
  def test_the_server_reads_the_states_the_examples_describe
    records = records_in(read(EXAMPLES))
    ledger = ReputableChat::Chain::Ledger.new(genesis: records.first, versions: VERSIONS)
    records.drop(1).each { |record| ledger.add(record) }
    state = ->(prefix) { ledger.state(records.find { |r| r.record_hash.start_with?(prefix) }.record_hash) }

    assert_equal "void", state.call("19ba432b"), "the thief's key change"
    assert_equal "void", state.call("d99dd7ca"), "the thief's message"
    assert_equal "confirmed", state.call("86f0baf3"), "Dana's key change"
    assert_equal "confirmed", state.call("9cb36d78"), "Alice's payment"
    assert_equal "void", state.call("9cfb8f27"), "Alice's lunch"
    assert_equal "void", state.call("35eb6dbc"), "the change made with Alice's stolen master key"
  end

  private

  def records_in(text)
    text.scan(/```\npayload:   (.+?)\nsignature: (\S+)\nhash:      (\S+)\n```/m).map do |payload, signature, _|
      ReputableChat::Chain::Record.parse(payload, signature)
    end
  end

  # The default external encoding is not UTF-8 everywhere, and these files are.
  def read(path) = File.read(path, encoding: "UTF-8")

  def output = @output ||= run_checker(EXAMPLES)

  def run_checker(path)
    stdout, stderr, status = Open3.capture3("node", SCRIPT, path)
    flunk "the checker itself failed: #{stderr}" unless status.success?
    stdout.split("\n")
  end

  def problems = output.grep(/^PROBLEM/).map { |line| line.sub("PROBLEM\t", "") }
  def report(tag) = output.grep(/^#{tag}\t/).map { |line| line.sub("#{tag}\t", "") }
  def node? = system("node", "--version", out: File::NULL, err: File::NULL)
end
