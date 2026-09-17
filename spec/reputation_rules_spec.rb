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

    assert_equal dec("0.91"),       l.weight(0)
    assert_equal dec("0.00066339"), l.weight(3)
    assert_in_delta 0.09, l.stranger_ceiling.to_f, 1e-6
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
    assert_equal :hidden, engine(graph).visibility(viewer: VIEWER, target: TARGET),
                 "one like must lose to a depth-3 report"

    graph.like(VIEWER, TARGET, 2)
    assert_equal :grey, engine(graph).visibility(viewer: VIEWER, target: TARGET),
                 "two likes must outweigh a depth-3 report"
  end

  # RULE: nobody is visible by default. Being unrated is indistinguishable from
  # scoring zero, and both are hidden.
  def test_unrated_users_are_hidden
    graph = store.chain(VIEWER, "a")

    assert_equal dec("0"), engine(graph).effective(viewer: VIEWER, target: "stranger")
    assert_equal :hidden, engine(graph).visibility(viewer: VIEWER, target: "stranger")
  end

  # RULE: this is the bug that drove the "hidden unless above zero" decision --
  # reporting someone must never move them from hidden to visible.
  def test_a_report_never_increases_visibility
    graph = store.chain(VIEWER, "a", "b", "c")
    before = engine(graph).visibility(viewer: VIEWER, target: TARGET)

    graph.report("c", TARGET)
    after = engine(graph).visibility(viewer: VIEWER, target: TARGET)

    assert_equal :hidden, before
    assert_equal :hidden, after, "a report must not make an unrated user visible"
  end

  # RULE: grey is low-positive only; anything at or below zero is hidden.
  def test_grey_band_is_low_positive_only
    e = engine(store)

    assert_equal :hidden, e.classify(dec("-0.0001"))
    assert_equal :hidden, e.classify(dec("0"))
    assert_equal :grey,   e.classify(dec("0.0001"))
    assert_equal :grey,   e.classify(dec("0.049"))
    assert_equal :normal, e.classify(dec("0.05"))
  end

  # RULE: a report is absolute within one rater -- it overrides however many of
  # the target's comments that same rater liked.
  def test_report_overrides_the_same_raters_likes
    graph = store.rate(VIEWER, TARGET, net_votes: 500, reported: true)

    assert_equal dec("-0.91"), engine(graph).effective(viewer: VIEWER, target: TARGET)
  end

  # RULE: across raters a report is only -1 in the mean, so it is outvoteable.
  # Two friendships tie it, three win. This is why reports are not a flag: one
  # malicious contact must not be able to hide anyone from you permanently.
  def test_report_is_outvoteable_across_raters_at_the_same_depth
    graph = store.chain(VIEWER, "a").friend(VIEWER, "b").friend(VIEWER, "c").friend(VIEWER, "d")
    graph.report("a", TARGET)
    graph.friend("b", TARGET)

    assert_equal :hidden, engine(graph).visibility(viewer: VIEWER, target: TARGET),
                 "one friendship must not outvote a report"

    graph.friend("c", TARGET)
    assert_equal :hidden, engine(graph).visibility(viewer: VIEWER, target: TARGET),
                 "two friendships tie a report, and a tie is hidden"

    graph.friend("d", TARGET)
    assert_equal :grey, engine(graph).visibility(viewer: VIEWER, target: TARGET),
                 "three friendships must outvote a report"
  end

  # RULE: a non-positive link ends the branch. Everything beyond someone you do
  # not rate positively goes unread, however well-regarded they are further out.
  def test_gate_blocks_branches_behind_a_non_positive_link
    graph = store.rate(VIEWER, "a", net_votes: -5)
    graph.friend("a", TARGET)

    assert_equal :hidden, engine(graph).visibility(viewer: VIEWER, target: TARGET)
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

  # RULE: the traversal stops at max_depth.
  def test_traversal_respects_max_depth
    people = ["viewer"] + (1..12).map { |i| "p#{i}" }
    graph = store.chain(*people)

    depths = engine(graph).reachable_depths(VIEWER)
    assert_equal 7, depths.values.max
  end

  # RULE: a user's own pinned config wins; a blank one tracks the default.
  def test_user_config_overrides_are_layered
    graph = store.chain(VIEWER, "a", "b", "c").report("c", TARGET).like(VIEWER, TARGET, 2)

    assert_equal :grey, engine(graph).visibility(viewer: VIEWER, target: TARGET)

    # Pinning a shallower curve changes only this user's view. 0.0001 is below
    # the legal window's floor of A > k**3 / 4, so for this user two likes no
    # longer clear a depth-3 report -- which is the window doing its job.
    pinned = engine(graph, "vote_curve" => { "a" => "0.0001" })
    assert_equal :hidden, pinned.visibility(viewer: VIEWER, target: TARGET),
                 "a user who pins a curve below the legal window loses to the report"

    blank = engine(graph, "vote_curve" => { "a" => nil })
    assert_equal :grey, blank.visibility(viewer: VIEWER, target: TARGET),
                 "a blank value must track the default"
  end
end
