# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/operator"
require_relative "../script/tim"
require "tmpdir"

# The genesis account signs from a terminal, which means its seed sits in a
# file. That file is the weakest point in the system, so the rules around it
# are worth asserting rather than assuming.
class OperatorSpec < Minitest::Test
  include SpecHelper

  Operator = ReputableChat::Operator

  def a_phrase = ReputableChat::Cryptography::Seed.encode("0" * 121, 12)

  # RULE: the seed file is never group- or world-readable. Written 0600 from
  # the moment it is created, not chmodded afterwards, so it is not briefly
  # readable by everyone on the machine.
  def test_the_seed_file_is_written_private
    Dir.mktmpdir do |dir|
      path = Operator.write_seed(a_phrase, path: File.join(dir, "seed"))

      assert_equal 0o600, File.stat(path).mode & 0o777
      refute Operator.seed_readable_by_others?(path: path)
    end
  end

  def test_a_loose_seed_file_is_noticed
    Dir.mktmpdir do |dir|
      path = Operator.write_seed(a_phrase, path: File.join(dir, "seed"))
      File.chmod(0o644, path)

      assert Operator.seed_readable_by_others?(path: path)
    end
  end

  # RULE: the file holds the seed phrase, not the derived private key. It is
  # then the same secret a person would type into the UI, so there is one thing
  # to look after rather than two that must not disagree.
  def test_the_seed_file_round_trips_the_phrase
    Dir.mktmpdir do |dir|
      phrase = a_phrase
      path = Operator.write_seed(phrase, path: File.join(dir, "seed"))

      assert_equal phrase, Operator.seed_phrase(path: path)
      assert_equal 12, File.read(path).split.size
    end
  end

  # RULE: a seed file that has picked up a stray edit is refused. Deriving a
  # different key in silence would sign as an account nobody has heard of.
  def test_a_corrupted_seed_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "seed")
      File.write(path, "#{a_phrase} banana")

      assert_raises(ReputableChat::Cryptography::Seed::InvalidSeed) { Operator.seed_phrase(path: path) }
    end
  end

  def test_a_missing_seed_says_where_one_comes_from
    Dir.mktmpdir do |dir|
      error = assert_raises(Operator::MissingSeed) { Operator.seed_phrase(path: File.join(dir, "nope")) }

      assert_match(/rake genesis/, error.message)
    end
  end

  # --- what the CLI grants ------------------------------------------------

  # RULE: `visible` grants the least rating that clears the visibility line,
  # read off the curve rather than hardcoded. An unrated account sits at
  # exactly zero and is invisible to everyone, which is the sybil defense and
  # also the reason nobody can get started without a nudge.
  def test_visible_grants_the_least_rating_that_clears_the_line
    votes = Tim.minimum_visible_votes
    engine = engine(store)
    line = config.fetch("display.visible_above")

    assert_operator engine.ladder.weight(0) * engine.curve.value(votes), :>, dec(line)
    assert_operator engine.ladder.weight(0) * engine.curve.value(votes - 1), :<=, dec(line) if votes > 1
  end

  def test_visible_lifts_an_unrated_account_over_the_line
    rating = Tim.made_visible(nil)
    graph = store.rate("tim", "newcomer", **symbolize(rating))

    assert_operator engine(graph).effective(viewer: "tim", target: "newcomer"), :>,
                    dec(config.fetch("display.visible_above"))
  end

  # RULE: vouching weakly for somebody never demotes them. `visible` says "this
  # is a real person", and saying it about a friend must not undo the friending
  # or claw back votes already given.
  def test_visible_never_lowers_somebody_already_above_the_line
    generous = { "friend" => true, "reported" => false, "net_votes" => 40, "cleared" => false }
    result = Tim.made_visible(generous)

    assert_equal 40, result["net_votes"]
    assert result["friend"]
  end

  # RULE: friending somebody withdraws a report. A report is absolute within
  # one rater, so leaving it set would silently pin a new friend to -1.
  def test_friending_withdraws_a_report
    reported = { "friend" => false, "reported" => true, "net_votes" => 0, "cleared" => false }
    result = Tim.friended(reported)

    assert result["friend"]
    refute result["reported"]
  end

  def symbolize(rating)
    { friend: rating["friend"], reported: rating["reported"],
      net_votes: rating["net_votes"], cleared: rating["cleared"] }
  end
end
