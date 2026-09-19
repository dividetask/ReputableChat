# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/state"
require "tmpdir"

# What a bot has to remember between runs. Losing any of it has consequences
# that are quiet rather than loud: a forgotten seq collides with its own
# history, a forgotten vote list double-reacts, a forgotten seed is an
# account nobody can ever open again.
class BotStateSpec < Minitest::Test
  State = ReputableChat::Bot::State

  def with_state
    Dir.mktmpdir do |dir|
      yield State.load(File.join(dir, "bot.json"), name: "bot"), dir
    end
  end

  def test_everything_needed_to_be_the_same_account_survives_a_restart
    with_state do |state, dir|
      state.recycle!(seed: "a b c", pubkey: "KEY", username: "Ana", retire_after_days: 3)
      state.seq = 7
      state.prev = "SIG"
      state.version = 4
      state.vote("MSG")
      state.save

      reloaded = State.load(File.join(dir, "bot.json"), name: "bot")

      assert_equal "a b c", reloaded.seed
      assert_equal 7, reloaded.seq
      assert_equal "SIG", reloaded.prev
      assert_equal 4, reloaded.version
      assert reloaded.voted?("MSG"), "one vote per message did not survive the restart"
    end
  end

  # The bot must never use the old key again -- that is what makes it a new
  # account -- but the file keeps it so the abandoned account can still be
  # opened in the browser and looked at.
  def test_a_recycled_bot_stops_using_its_old_account_but_does_not_destroy_it
    with_state do |state, _dir|
      state.recycle!(seed: "old seed", pubkey: "OLD", username: "First")
      state.seq = 9
      state.vote("MSG")

      state.recycle!(seed: "new seed", pubkey: "NEW", username: "Second")

      assert_equal "NEW", state.pubkey
      assert_equal 0, state.seq, "a new account starts its sequence again"
      refute state.voted?("MSG"), "a new account has voted on nothing"
      assert_equal %w[OLD], state.retired.map { |r| r["pubkey"] }
      assert_equal "old seed", state.retired.first["seed"]
    end
  end

  def test_generation_counts_the_accounts_burned_through
    with_state do |state, _dir|
      assert_equal 0, state.generation
      state.recycle!(seed: "a", pubkey: "A")
      state.recycle!(seed: "b", pubkey: "B")

      assert_equal 1, state.generation
    end
  end

  def test_a_bot_that_never_recycles_never_expires
    with_state do |state, _dir|
      state.recycle!(seed: "a", pubkey: "A", retire_after_days: nil,
                     now: Time.now.to_i - (400 * 86_400))

      refute_predicate state, :expired?
    end
  end

  def test_an_account_expires_once_it_has_lived_its_span
    with_state do |state, _dir|
      born = Time.now.to_i - (4 * 86_400)
      state.recycle!(seed: "a", pubkey: "A", retire_after_days: 3, now: born)

      assert_predicate state, :expired?
    end
  end

  # Time compression is a testing convenience; it must not leave behind a
  # state file that retires itself the moment it is used at normal speed.
  def test_compressed_time_ages_a_bot_without_rewriting_its_timestamps
    with_state do |state, _dir|
      born = Time.now.to_i - 600
      state.recycle!(seed: "a", pubkey: "A", retire_after_days: 3, now: born)

      refute state.expired?, "ten minutes is not three days"
      assert state.expired?(speed: 1000), "compressed time should have aged it"
      assert_equal born, state.born_at, "the file must keep honest wall-clock times"
    end
  end

  # The room only serves the last hundred messages, so remembering thousands
  # buys nothing and the file would grow without bound.
  def test_what_it_remembers_seeing_stays_bounded
    with_state do |state, _dir|
      (State::REMEMBERED + 200).times { |i| state.see("SIG#{i}") }

      assert_equal State::REMEMBERED, state.to_h["seen"].size
      assert state.seen?("SIG#{State::REMEMBERED + 199}"), "the newest should always be remembered"
    end
  end

  def test_a_seed_is_never_left_half_written
    with_state do |state, dir|
      state.recycle!(seed: "a b c", pubkey: "KEY")
      state.save

      assert_equal "a b c", JSON.parse(File.read(File.join(dir, "bot.json")))["seed"]
      refute_path_exists File.join(dir, "bot.json.tmp")
    end
  end
end
