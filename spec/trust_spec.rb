# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/reputation/score"

# The trust multiplier: what somebody's recommendations are worth, as distinct
# from what they are worth.
#
# It exists for the friend who is worth reading and has terrible taste in who
# else to vouch for. Setting them to nought leaves their posts visible and
# stops their vouching carrying anyone in.
class TrustSpec < Minitest::Test
  include SpecHelper

  Score = ReputableChat::Reputation::Score

  def chain(trust)
    graph = store
    graph.publish("me", "middle", reputation: "0.5", trust: trust)
    graph.publish("middle", "far", reputation: "0.5")
    engine(graph)
  end

  def effective(graph, target: "far") = graph.effective(viewer: "me", target: target)

  # RULE: full trust is the default and changes nothing.
  def test_a_fully_trusted_contact_carries_their_recommendations_intact
    assert_operator effective(chain("1")), :>, dec("0")
  end

  # RULE: nought prunes. Everything past that person counts for nothing, while
  # the person themselves stays exactly as visible as they were.
  def test_no_trust_stops_the_branch_without_hiding_the_person
    graph = chain("0")

    assert_equal dec("0"), effective(graph)
    assert_operator effective(graph, target: "middle"), :>, dec("0"),
                    "their own standing must be untouched"
  end

  # RULE: a negative multiplier inverts. "I trust this person to be reliably
  # wrong" is a real position, and this is what it means.
  def test_negative_trust_inverts_what_they_recommend
    assert_equal(-effective(chain("1")), effective(chain("-1")))
  end

  def test_partial_trust_scales_what_they_recommend
    assert_equal effective(chain("1")) / 2, effective(chain("0.5"))
  end

  # RULE: it compounds along the path, so two halves make a quarter.
  def test_trust_compounds_along_the_path
    graph = store
    graph.publish("me", "a", reputation: "0.5", trust: "0.5")
    graph.publish("a", "b", reputation: "0.5", trust: "0.5")
    graph.publish("b", "far", reputation: "0.5")

    full = store
    full.publish("me", "a", reputation: "0.5")
    full.publish("a", "b", reputation: "0.5")
    full.publish("b", "far", reputation: "0.5")

    assert_equal engine(full).effective(viewer: "me", target: "far") / 4,
                 engine(graph).effective(viewer: "me", target: "far")
  end

  # --- what a published score means ---------------------------------------

  # RULE: the default is 1 for anyone positive and 0 for anyone blocked, so an
  # attestation only needs an entry where somebody has overridden it.
  def test_the_multiplier_defaults_from_the_score
    assert_equal dec("1"), Score.new(reputation: dec("0.5")).multiplier
    assert_equal dec("0"), Score.new(reputation: dec("0")).multiplier
    assert_equal dec("0"), Score.new(reputation: dec("-1")).multiplier
    assert_equal dec("-1"), Score.new(reputation: dec("0.5"), trust: dec("-1")).multiplier
  end

  # RULE: actions are private now, and a report is the only thing that reaches
  # exactly -1. That is what survives of them, and it is what the mid-session
  # report thresholds read.
  def test_a_published_score_of_minus_one_reads_as_a_report
    assert Score.new(reputation: dec("-1")).reported
    refute Score.new(reputation: dec("-0.9")).reported
  end

  # RULE: a published score is taken as it stands -- the curve already ran in
  # whoever published it, so there is nothing left to compute.
  def test_a_published_score_is_used_as_published
    assert_equal dec("0.5"), Score.new(reputation: dec("0.5")).value
    assert_equal dec("1"), Score.new(reputation: dec("5")).value, "clamped to the range"
  end
end
