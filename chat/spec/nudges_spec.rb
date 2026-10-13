# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "reputable_chat/nudges"
require "reputable_chat/store/database"

# What the chat learns fetching from other chat servers moves the agnostic
# server's rating of them, by a nudge the chat computes (Nudges).
class NudgesSpec < Minitest::Test
  Chain = Struct.new(:sent) do
    def nudge(**fields) = sent << fields
  end

  def setup
    @store = ReputableChat::Store::Database.new("sqlite:/")
    @chain = Chain.new([])
    @now = 10_000_000
  end

  def nudges(step: "0.01", missing_penalty: "0.25")
    ReputableChat::Nudges.new(store: @store, chain: @chain, step: step, missing_penalty: missing_penalty,
                              clock: -> { @now })
  end

  def account = "a" * 64

  # RULE (yours): +step for a server that always has what it is asked for,
  # -step for one that never answers.
  def test_the_nudge_runs_from_minus_step_to_plus_step
    always = nudges
    3.times { always.record(account, :reached) }
    assert_equal "0.01", always.reputation(account)

    other = "b" * 64
    3.times { always.record(other, :unreached) }
    assert_equal "-0.01", always.reputation(other)
  end

  # RULE (yours): a missing file scores 1 - missing_penalty, between the two.
  def test_a_missing_file_scores_between_reached_and_unreached
    finder = nudges(missing_penalty: "0.25")
    finder.record(account, :missing)

    assert_equal "0.005", finder.reputation(account), "0.01 * (2 * 0.75 - 1)"
  end

  # RULE (yours): sent rounded to three decimals, and only when that changes;
  # trust is left at 0.
  def test_a_nudge_is_sent_only_when_it_changes
    finder = nudges
    3.times { finder.record(account, :reached) }

    assert_equal [{ app: "chat", account: account, reputation: "0.01", trust: "0" }], @chain.sent
  end

  # RULE (yours): over the last 30 days; once every attempt has aged out the
  # nudge is taken back.
  def test_attempts_older_than_the_window_stop_counting
    finder = nudges
    finder.record(account, :unreached)
    @now += ReputableChat::Nudges::WINDOW + 1
    finder.record("c" * 64, :reached)

    assert_includes @chain.sent, { app: "chat", account: account, reputation: "0", trust: "0" }
  end

  # RULE (yours): the agnostic server takes the chat's nudge, on its local
  # listener, and publishes it in its ratings.
  def test_the_agnostic_server_takes_the_chats_nudge
    other = "e" * 64
    ChainServer.client.nudge(app: "chat", account: other, reputation: "0.004", trust: "0")
    rating = ChainServer.client.ratings.fetch(other)

    assert_equal "0.004", rating.dig("nudges", "chat", "reputation")
  ensure
    ChainServer.client.nudge(app: "chat", account: other, reputation: "0", trust: "0")
  end
end
