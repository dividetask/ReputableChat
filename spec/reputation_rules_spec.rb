# frozen_string_literal: true

require_relative "spec_helper"

# These tests encode design decisions, not implementation details. If one of
# them fails after a config change, the config change is the thing to
# reconsider -- each test names the rule it is protecting.
class ReputationRulesSpec < Minitest::Test
  include SpecHelper

  VIEWER = "viewer"
  TARGET = "target"

  # RULE: the first few emotes are nearly weightless; 20 does not reach the cap.
  def test_vote_curve_shape
    c = engine(store).curve

    assert_equal dec("0.0004"), c.value(1)
    assert_equal dec("0.0016"), c.value(2)
    assert_equal dec("0.0036"), c.value(3)
    assert_equal dec("0.16"),   c.value(20)
    assert_operator c.value(20), :<, c.cap, "20 emotes must not reach the cap"
    assert_equal 36, c.saturation_point
  end

  # RULE: dislikes mirror likes. A*x^2 is positive for negative x, so the sign
  # has to be applied to the magnitude rather than fed through the polynomial.
  def test_curve_is_odd_symmetric
    c = engine(store).curve

    [1, 2, 7, 25, 100].each do |n|
      assert_equal(-c.value(n), c.value(-n), "curve(#{-n}) must mirror curve(#{n})")
    end
  end

  # RULE: weights sum to 1, so effective reputation needs no clamping, and the
  # ceiling for anyone you have not personally rated is exactly k.
  def test_ladder_weights
    l = engine(store).ladder

    assert_equal dec("0.9"),        l.weight(0)
    assert_equal dec("0.0009"),     l.weight(3)
    assert_in_delta 0.1, l.stranger_ceiling.to_f, 1e-6
  end

  # RULE (the coupling): the report-visibility rule below only holds while
  # k**3 sits strictly inside (curve(1), curve(2)) == (A, 4A). This is the
  # invariant that makes k and the curve un-retunable independently.
  def test_k_cubed_stays_inside_the_curve_window
    e = engine(store)
    k_cubed = e.ladder.k**3

    assert_operator e.curve.value(1), :<, k_cubed, "curve(1) must sit below k**3"
    assert_operator e.curve.value(2), :>, k_cubed, "curve(2) must sit above k**3"
  end

  # RULE: a report from three steps out hides someone you have liked once,
  # but two likes of your own outweigh it.
  def test_distant_report_versus_your_own_likes
    graph = store.chain(VIEWER, "a", "b", "c")
    graph.report("c", TARGET)

    graph.like(VIEWER, TARGET, 1)
    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: TARGET),
                 "one like must lose to a depth-3 report"

    graph.like(VIEWER, TARGET, 2)
    assert_equal :tolerated, engine(graph).bucket(viewer: VIEWER, target: TARGET),
                 "two likes must outweigh a depth-3 report"
  end

  # RULE: nobody is visible by default. Being unrated is indistinguishable from
  # scoring zero, and both are hidden.
  def test_unrated_users_are_hidden
    graph = store.chain(VIEWER, "a")

    assert_equal dec("0"), engine(graph).effective(viewer: VIEWER, target: "stranger")
    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: "stranger")
  end

  # RULE: this is the bug that drove the "hidden unless above zero" decision --
  # reporting someone must never move them from hidden to visible.
  def test_a_report_never_increases_visibility
    graph = store.chain(VIEWER, "a", "b", "c")
    before = engine(graph).bucket(viewer: VIEWER, target: TARGET)

    graph.report("c", TARGET)
    after = engine(graph).bucket(viewer: VIEWER, target: TARGET)

    assert_equal :blocked, before
    assert_equal :blocked, after, "a report must not make an unrated user visible"
  end

  # RULE: Tolerated is low-positive only; anything at or below zero is Blocked.
  def test_tolerated_band_is_low_positive_only
    e = engine(store)

    assert_equal :blocked, e.classify(dec("-0.0001"))
    assert_equal :blocked, e.classify(dec("0"))
    assert_equal :tolerated,   e.classify(dec("0.0001"))
    assert_equal :tolerated, e.classify(dec("0.009"))
    assert_equal :trusted,   e.classify(dec("0.01"))
  end

  # RULE: a report is absolute within one rater -- it overrides however many of
  # the target's comments that same rater liked.
  def test_report_overrides_the_same_raters_likes
    graph = store.rate(VIEWER, TARGET, net_votes: 500, reported: true)

    assert_equal dec("-0.9"), engine(graph).effective(viewer: VIEWER, target: TARGET)
  end

  # RULE: across raters a report is only -1 in the mean, so it is outvoteable.
  # Two friendships tie it, three win. This is why reports are not a flag: one
  # malicious contact must not be able to hide anyone from you permanently.
  def test_report_is_outvoteable_across_raters_at_the_same_depth
    graph = store.chain(VIEWER, "a").friend(VIEWER, "b").friend(VIEWER, "c").friend(VIEWER, "d")
    graph.report("a", TARGET)
    graph.friend("b", TARGET)

    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: TARGET),
                 "one friendship must not outvote a report"

    graph.friend("c", TARGET)
    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: TARGET),
                 "two friendships tie a report, and a tie is hidden"

    graph.friend("d", TARGET)
    assert_equal :trusted, engine(graph).bucket(viewer: VIEWER, target: TARGET),
                 "three friendships must outvote a report"
  end

  # RULE: a non-positive link ends the branch. Everything beyond someone you do
  # not rate positively goes unread, however well-regarded they are further out.
  def test_gate_blocks_branches_behind_a_non_positive_link
    graph = store.rate(VIEWER, "a", net_votes: -5)
    graph.friend("a", TARGET)

    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: TARGET)
    refute engine(graph).reachable_depths(VIEWER).key?(TARGET)
  end

  # RULE: each person votes once, at their shortest distance. Someone reachable
  # by two paths does not get counted twice.
  def test_each_rater_counts_once_at_shortest_depth
    graph = store.chain(VIEWER, "a", "shared")
    graph.friend(VIEWER, "b").friend("b", "shared")
    graph.friend("shared", TARGET)

    depths = engine(graph).reachable_depths(VIEWER)
    assert_equal 2, depths["shared"], "shared should sit at its shortest distance"

    # A friend at depth 2 contributes weight(2) * 0.5 exactly once.
    expected = engine(graph).ladder.weight(2) * dec("0.5")
    assert_equal expected, engine(graph).effective(viewer: VIEWER, target: TARGET)
  end

  # RULE: the traversal stops at max_hops.
  def test_traversal_respects_max_hops
    people = ["viewer"] + (1..12).map { |i| "p#{i}" }
    graph = store.chain(*people)

    depths = engine(graph).reachable_depths(VIEWER)
    assert_equal 7, depths.values.max
  end

  # RULE: the traversal also stops at max_configs, whichever limit comes first.
  # A positive-only graph still branches, so seven hops is unbounded without it.
  def test_traversal_respects_max_configs
    graph = store
    # Fan out widely: 20 contacts, each friending 20 more.
    (1..20).each do |i|
      graph.friend(VIEWER, "a#{i}")
      (1..20).each { |j| graph.friend("a#{i}", "b#{i}-#{j}") }
    end

    unbounded = engine(graph).reachable_depths(VIEWER)
    assert_operator unbounded.size, :>, 50, "this graph should exceed the cap"

    capped = engine(graph, "ladder" => { "max_configs" => 50 })
    assert_operator capped.reachable_depths(VIEWER).size, :<=, 50
  end

  # RULE: the unrated are Blocked by default -- that is how new accounts and
  # spam accounts both start, and it is the whole sybil defense.
  def test_unrated_are_blocked_unless_the_user_opts_in
    graph = store.chain(VIEWER, "a")

    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: "newcomer")

    opted_in = engine(graph, "display" => { "show_unrated" => true })
    assert_equal :tolerated, opted_in.bucket(viewer: VIEWER, target: "newcomer"),
                 "show_unrated should surface the unrated"
  end

  # RULE: opting into the unrated must not also surface the net-negative.
  def test_show_unrated_does_not_reveal_reported_users
    graph = store.chain(VIEWER, "a").report("a", TARGET)
    opted_in = engine(graph, "display" => { "show_unrated" => true })

    assert_equal :blocked, opted_in.bucket(viewer: VIEWER, target: TARGET)
  end

  # RULE: a user's own pinned config wins; a blank one tracks the default.
  def test_user_config_overrides_are_layered
    graph = store.chain(VIEWER, "a", "b", "c").report("c", TARGET).like(VIEWER, TARGET, 2)

    assert_equal :tolerated, engine(graph).bucket(viewer: VIEWER, target: TARGET)

    # Pinning a shallower curve changes only this user's view. 0.0001 is below
    # the legal window's floor of A > k**3 / 4, so for this user two likes no
    # longer clear a depth-3 report -- which is the window doing its job.
    pinned = engine(graph, "vote_curve" => { "a" => "0.0001" })
    assert_equal :blocked, pinned.bucket(viewer: VIEWER, target: TARGET),
                 "a user who pins a curve below the legal window loses to the report"

    blank = engine(graph, "vote_curve" => { "a" => nil })
    assert_equal :tolerated, blank.bucket(viewer: VIEWER, target: TARGET),
                 "a blank value must track the default"
  end
end

# `cleared` is the profile's "remove" button: it pins someone to zero whatever
# they have been emoted or replied to, before or since.
class ClearedRatingSpec < Minitest::Test
  include SpecHelper

  VIEWER = "viewer"
  TARGET = "target"

  # RULE: clearing wipes accumulated votes, in either direction.
  def test_clearing_pins_a_rating_to_zero
    graph = store.rate(VIEWER, TARGET, net_votes: 30, cleared: true)
    assert_equal dec("0"), engine(graph).effective(viewer: VIEWER, target: TARGET)

    graph.rate(VIEWER, TARGET, net_votes: -30, cleared: true)
    assert_equal dec("0"), engine(graph).effective(viewer: VIEWER, target: TARGET)
  end

  # RULE: a cleared user is blocked, not merely quiet -- zero is not above zero.
  def test_a_cleared_user_is_blocked
    graph = store.rate(VIEWER, TARGET, net_votes: 30, cleared: true)

    assert_equal :blocked, engine(graph).bucket(viewer: VIEWER, target: TARGET)
  end

  # RULE: friending outranks clearing, which is why the UI will not offer to
  # clear a friend.
  def test_friending_outranks_clearing
    graph = store.rate(VIEWER, TARGET, friend: true, net_votes: 2, cleared: true)

    assert_equal :trusted, engine(graph).bucket(viewer: VIEWER, target: TARGET)
  end

  # RULE: reporting outranks everything.
  def test_reporting_outranks_clearing
    graph = store.rate(VIEWER, TARGET, reported: true, net_votes: 30, cleared: true)

    assert_equal dec("-0.9"), engine(graph).effective(viewer: VIEWER, target: TARGET)
  end

  # RULE: a cleared link is not positive, so the walk stops there.
  def test_a_cleared_user_does_not_carry_the_walk
    graph = store.rate(VIEWER, "a", net_votes: 30, cleared: true)
    graph.friend("a", TARGET)

    refute engine(graph).reachable_depths(VIEWER).key?(TARGET)
  end

  # RULE: a config written before `cleared` existed still loads.
  def test_ratings_without_cleared_still_parse
    rating = ReputableChat::Reputation::Rating.from_h(
      { "friend" => false, "reported" => false, "net_votes" => 3 }
    )

    refute rating.cleared
  end
end
