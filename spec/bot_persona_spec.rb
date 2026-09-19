# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/persona"
require "tmpdir"

# A persona file is the whole of a bot: who it is, how it talks, how often it
# turns up. Anything wrong with one should be said at load time, by name,
# rather than hours into a run.
class BotPersonaSpec < Minitest::Test
  Persona = ReputableChat::Bot::Persona

  def persona(overrides = {})
    Persona.new({ "username" => "Ana", "brain" => "scripted", "lines" => ["hi"] }.merge(overrides))
  end

  def test_a_scripted_bot_with_nothing_to_say_is_refused
    error = assert_raises(Persona::Invalid) { persona("lines" => []) }

    assert_match(/lines/, error.message)
  end

  def test_an_llm_bot_without_a_disposition_is_refused
    error = assert_raises(Persona::Invalid) { persona("brain" => "llm", "disposition" => "") }

    assert_match(/disposition/, error.message)
  end

  # The disposition is the system prompt, so it has to survive being a
  # paragraph as happily as being a word.
  def test_a_disposition_can_be_a_word_or_an_essay
    assert_equal "grumpy", persona("brain" => "llm", "disposition" => "grumpy").disposition
    long = "You are Ana.\n" * 50

    assert_equal long.strip, persona("brain" => "llm", "disposition" => long).disposition
  end

  def test_a_room_the_server_would_reject_is_caught_here
    assert_raises(Persona::Invalid) { persona("room" => "Not A Room") }
  end

  # A posting block that cannot be satisfied is a broken persona, and this is
  # where it should surface.
  def test_a_contradictory_posting_block_fails_at_load
    assert_raises(ReputableChat::Bot::Schedule::Invalid) do
      persona("posting" => { "visits_per_week" => 300.0, "visit_minutes" => 120.0 })
    end
  end

  def test_loading_a_persona_from_disk_round_trips
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.yml")
      File.write(path, "username: Ana\nbrain: scripted\nlines:\n  - hello\n")
      loaded = Persona.load(path)

      assert_equal "Ana", loaded.username
      assert_equal ["hello"], loaded.lines
      assert_equal "general", loaded.room
    end
  end

  # A recycled account that returns under the same display name is obvious to
  # a human reader; the point is to test the reputation system, not the reader.
  def test_a_recycled_account_comes_back_under_a_different_name
    recycler = persona("usernames" => %w[One Two Three], "recycle_after_days" => 3)
    names = Array.new(30) { |i| recycler.username_for(1, random: Random.new(i)) }

    assert_operator names.uniq.size, :>, 1
    assert_empty names.uniq - %w[One Two Three]
  end

  def test_without_a_name_pool_a_later_generation_is_still_distinguishable
    refute_equal persona.username, persona.username_for(2, random: Random.new(1))
    assert_equal "Ana", persona.username_for(0, random: Random.new(1))
  end

  # A fleet started together must not all vanish on the same afternoon.
  def test_account_lifetimes_are_jittered_per_bot
    recycler  = persona("recycle_after_days" => 3)
    lifetimes = Array.new(20) { |i| recycler.lifetime_days(random: Random.new(i)) }

    assert_operator lifetimes.uniq.size, :>, 15
    assert lifetimes.all? { |days| days.between?(2.1, 3.9) }
  end

  def test_a_bot_that_never_recycles_has_no_lifetime
    assert_nil persona.lifetime_days(random: Random.new(1))
    refute_predicate persona, :recycles?
  end

  # Unrated accounts sit at exactly zero and are invisible to everyone. A
  # swarm that could not see itself would have nothing to react to.
  def test_bots_see_unrated_accounts_by_default
    assert_equal({ "display" => { "show_unrated" => true } }, persona.display_overrides)
  end
end
