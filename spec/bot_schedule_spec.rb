# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/schedule"

# The scheduler is the whole of a bot's realism. Every number in a persona
# file is a rate per week, and the rest -- how long it stays, how many posts
# fit in a visit, how long it is away -- is derived, so that no two settings
# can quietly contradict each other.
class BotScheduleSpec < Minitest::Test
  Schedule = ReputableChat::Bot::Schedule

  # Simulates `weeks` of a bot's life and counts what it actually did.
  def tally(overrides = {}, weeks: 300, seed: 1)
    schedule = Schedule.new(overrides, random: Random.new(seed))
    counts   = Hash.new(0)
    elapsed  = 0.0

    while elapsed < weeks * Schedule::WEEK
      elapsed += schedule.away_seconds
      counts[:visits] += 1
      deadline = elapsed + schedule.visit_seconds
      at = elapsed + schedule.gap_seconds

      while at < deadline
        counts[schedule.next_action] += 1
        at += schedule.gap_seconds
      end
      elapsed = deadline
    end

    counts.transform_values { |n| n / weeks.to_f }
  end

  # The point of stating rates per week: what you ask for is what the swarm
  # actually produces. The obvious derivation (visit_length / mean_gap)
  # undercounts by several percent and would make every persona file a lie.
  def test_the_configured_weekly_rates_are_what_actually_happens
    rates = tally

    assert_in_delta 14.0, rates[:visits], 14.0 * 0.05, "visits per week drifted"
    assert_in_delta 12.0, rates[:post], 12.0 * 0.05, "posts per week drifted"
    assert_in_delta 45.0, rates[:react], 45.0 * 0.05, "reactions per week drifted"
  end

  def test_rates_hold_for_a_bot_that_barely_speaks
    rates = tally({ "posts_per_week" => 1.0, "reactions_per_week" => 60.0,
                    "visits_per_week" => 25.0, "visit_minutes" => 15.0 }, weeks: 600)

    assert_in_delta 1.0, rates[:post], 0.15, "a lurker's one post a week drifted"
    assert_in_delta 60.0, rates[:react], 60.0 * 0.05
  end

  # Most of being in a chat room is reading it.
  def test_an_action_is_usually_neither_a_post_nor_a_reaction
    assert_operator Schedule.new.read_probability, :>, 0.25
  end

  # The burstiness is a consequence of the two-state model, not a setting:
  # posts can only happen while the bot is present, so they arrive in
  # clusters minutes apart separated by hours of nothing.
  def test_actions_within_a_visit_are_minutes_apart_not_hours
    schedule = Schedule.new({}, random: Random.new(4))
    gaps     = Array.new(2000) { schedule.gap_seconds }.sort
    median   = gaps[gaps.size / 2]

    assert_operator median, :<, 180, "half the within-visit gaps should be under three minutes"
    assert_operator gaps.first, :>=, 10, "the floor between actions was not respected"
  end

  def test_the_gap_between_visits_is_hours_not_minutes
    assert_in_delta 11.8, Schedule.new.away_mean / 3600, 0.2
  end

  # Twenty bots launched together must not all arrive together: that looks
  # nothing like twenty people and hits the server hardest at the least
  # useful moment.
  def test_bots_started_together_do_not_arrive_together
    delays = Array.new(50) { |i| Schedule.new({}, random: Random.new(i)).initial_delay }

    assert_operator delays.uniq.size, :>, 45, "initial delays are not spread out"
    assert delays.all?(&:positive?)
  end

  # A contradictory persona should fail when it is loaded, naming what to
  # change -- not hours later, halfway through a run.
  def test_a_week_that_cannot_hold_the_visits_is_refused
    error = assert_raises(Schedule::Invalid) do
      Schedule.new({ "visits_per_week" => 100.0, "visit_minutes" => 200.0 })
    end

    assert_match(/leaves no time away/, error.message)
  end

  def test_asking_for_more_than_the_visits_afford_says_what_to_change
    error = assert_raises(Schedule::Invalid) do
      Schedule.new({ "visits_per_week" => 2.0, "visit_minutes" => 5.0,
                     "posts_per_week" => 500.0, "reactions_per_week" => 500.0 })
    end

    assert_match(/raise visits_per_week or visit_minutes/, error.message)
  end

  def test_a_bot_that_only_reacts_is_allowed
    schedule = Schedule.new({ "posts_per_week" => 0.0 })

    assert_equal 0.0, schedule.post_probability
    assert_operator schedule.reaction_probability, :>, 0
  end

  def test_a_nonsense_rate_is_refused_by_name
    error = assert_raises(Schedule::Invalid) { Schedule.new({ "visits_per_week" => -3 }) }

    assert_match(/visits_per_week/, error.message)
  end
end
