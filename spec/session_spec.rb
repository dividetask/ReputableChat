# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/reputation/session"

# These protect the session model: bucket once at login, then only reports move
# anyone until the next login.
class SessionSpec < Minitest::Test
  include SpecHelper

  VIEWER = "viewer"
  TARGET = "target"

  def session(graph, overrides = {})
    ReputableChat::Reputation::Session.new(engine: engine(graph, overrides), viewer: VIEWER)
  end

  # RULE: everyone is sorted into exactly one of three lists.
  def test_sorts_users_into_three_buckets
    graph = store.chain(VIEWER, "close")            # friended -> trusted
    graph.rate(VIEWER, "faint", net_votes: 3)       # a few likes -> tolerated
    graph.report(VIEWER, "bad")                     # reported -> blocked

    s = session(graph).build(%w[close faint bad stranger])

    assert_equal :trusted,   s.bucket_of("close")
    assert_equal :tolerated, s.bucket_of("faint")
    assert_equal :blocked,   s.bucket_of("bad")
    assert_equal :blocked,   s.bucket_of("stranger"), "the unrated are blocked"

    assert_includes s.trusted, "close"
    assert_includes s.tolerated, "faint"
    assert_includes s.blocked, "bad"
  end

  # RULE: likes and dislikes do not move anyone mid-session, however many.
  def test_emotes_do_not_move_anyone_during_a_session
    graph = store.rate(VIEWER, TARGET, net_votes: 3)
    s = session(graph).build([TARGET])
    assert_equal :tolerated, s.bucket_of(TARGET)

    graph.rate(VIEWER, TARGET, net_votes: 500)   # would be trusted at next login
    assert_equal :tolerated, s.bucket_of(TARGET), "likes must not promote mid-session"

    graph.rate(VIEWER, TARGET, net_votes: -500)  # would be blocked at next login
    assert_equal :tolerated, s.bucket_of(TARGET), "dislikes must not demote mid-session"
  end

  # RULE: your own report blocks immediately.
  def test_your_own_report_blocks_at_once
    graph = store.chain(VIEWER, TARGET)
    s = session(graph).build([TARGET])
    assert_equal :trusted, s.bucket_of(TARGET)

    assert_equal :blocked, s.report(subject: TARGET, reporter: VIEWER)
    assert_equal :blocked, s.bucket_of(TARGET)
  end

  # RULE: one report from one hop away is enough.
  def test_one_report_from_one_hop_away_blocks
    graph = store.chain(VIEWER, "a").friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])

    assert_equal 1, s.hops_to("a")
    assert_equal :blocked, s.report(subject: TARGET, reporter: "a")
  end

  # RULE: two hops away it takes two reporters.
  def test_two_hops_away_needs_two_reporters
    graph = store.chain(VIEWER, "a")
    graph.friend("a", "b1").friend("a", "b2").friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])

    assert_equal 2, s.hops_to("b1")

    assert_equal :trusted, s.report(subject: TARGET, reporter: "b1"),
                 "one reporter two hops out is not enough"
    assert_equal :blocked, s.report(subject: TARGET, reporter: "b2"),
                 "two reporters two hops out block"
  end

  # RULE: the same person reporting twice is still one reporter.
  def test_a_repeated_report_from_one_person_counts_once
    graph = store.chain(VIEWER, "a")
    graph.friend("a", "b1").friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])

    s.report(subject: TARGET, reporter: "b1")
    assert_equal :trusted, s.report(subject: TARGET, reporter: "b1"),
                 "one person cannot block alone from two hops out"
  end

  # RULE: three hops out has no immediate effect -- it waits for next login.
  def test_reports_from_three_hops_away_do_not_block_mid_session
    graph = store.chain(VIEWER, "a", "b", "c").friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])

    assert_equal 3, s.hops_to("c")
    assert_equal :trusted, s.report(subject: TARGET, reporter: "c")
  end

  # RULE: someone outside your network cannot block anyone for you.
  def test_reports_from_outside_the_network_are_ignored
    graph = store.friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])

    assert_nil s.hops_to("outsider")
    assert_equal :trusted, s.report(subject: TARGET, reporter: "outsider")
  end

  # RULE: other people's config changes are invisible until the next login.
  # The session reads a snapshot, so this holds even for a rating published by
  # someone already inside the walk.
  def test_other_peoples_config_changes_are_invisible_until_next_login
    graph = store.chain(VIEWER, "a")
    s = session(graph).build([])

    graph.friend("a", "latecomer")
    assert_equal :blocked, s.bucket_of("latecomer"),
                 "a rating published after login must not be seen"

    assert_equal :trusted, session(graph).bucket_of("latecomer"),
                 "but a fresh login should see it"
  end

  # RULE: someone already visible at login is sorted on first sight, even if
  # they were not in the list handed to build.
  def test_users_met_mid_session_are_bucketed_on_first_sight
    graph = store.chain(VIEWER, "a")
    graph.friend("a", "quiet")
    s = session(graph).build([])

    assert_equal :trusted, s.bucket_of("quiet")
  end

  # RULE: the breakdown must add up to the score it explains.
  def test_explain_itemises_the_score_it_acts_on
    graph = store.chain(VIEWER, "a")
    graph.friend("a", TARGET)
    s = session(graph).build([TARGET])

    result = s.explain(TARGET)
    summed = result[:levels].sum(dec("0")) { |level| level[:contribution] }

    assert_equal result[:effective], summed.round(18)
    assert_equal :trusted, result[:bucket]

    level = result[:levels].first
    assert_equal 1, level[:hops]
    assert_equal ["a"], level[:raters].map { |r| r[:pubkey] },
                 "the breakdown must name who was responsible"
  end

  def test_explain_reports_who_reported
    graph = store.chain(VIEWER, "a").friend(VIEWER, TARGET)
    s = session(graph).build([TARGET])
    s.report(subject: TARGET, reporter: "a")

    assert_equal({ "a" => 1 }, s.explain(TARGET)[:reporters])
  end

  # RULE: the thresholds come from config, not from code.
  def test_report_thresholds_are_configurable
    graph = store.chain(VIEWER, "a").friend(VIEWER, TARGET)
    strict = session(graph, "session" => { "report_blocks" => { "1" => 2 } }).build([TARGET])

    assert_equal :trusted, strict.report(subject: TARGET, reporter: "a"),
                 "raising the threshold should require a second reporter"
  end
end
