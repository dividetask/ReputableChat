# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "tmpdir"

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

  private

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
