# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/brain"
require "reputable_chat/bot/brains/scripted"
require "reputable_chat/bot/brains/markov"
require "reputable_chat/bot/persona"

# Whatever a brain produces has to be something the server will accept and a
# reader would believe. The server rejects control characters and anything
# over 4000 bytes; a tiny model will happily supply both.
class BotBrainSpec < Minitest::Test
  Brain   = ReputableChat::Bot::Brain
  Persona = ReputableChat::Bot::Persona

  # The prefix strip exists for "Assistant: ..." and "Ana: ...". Applying it
  # to any word before a colon silently ate the first word of half the spam
  # lines, which is the kind of damage nothing downstream would report.
  def test_a_colon_in_a_message_is_not_mistaken_for_a_name_prefix
    assert_equal "URGENT: your account will be suspended",
                 Brain.clean("URGENT: your account will be suspended", name: "Ana")
  end

  def test_the_speakers_own_name_prefix_is_removed
    assert_equal "hey there", Brain.clean("Ana: hey there", name: "Ana")
  end

  def test_a_models_role_prefix_is_removed
    assert_equal "sure thing", Brain.clean("Assistant: sure thing", name: "Ana")
  end

  def test_wrapping_quotes_are_removed
    assert_equal "quoted line", Brain.clean('"quoted line"')
  end

  def test_a_quoted_phrase_inside_a_line_is_left_alone
    assert_equal 'he said "no" and left', Brain.clean('he said "no" and left')
  end

  # Newlines are legal in a body but a chat message is one line, and a model
  # asked for one line does not always oblige.
  def test_a_multi_line_answer_becomes_one_line
    assert_equal "first second", Brain.clean("first\nsecond")
  end

  def test_control_characters_the_server_would_reject_are_stripped
    cleaned = Brain.clean("hello\u0000there")

    refute_match(/[\x00-\x08]/, cleaned)
  end

  def test_an_over_long_answer_is_cut_on_a_word_boundary
    cleaned = Brain.clean("word " * 200)

    assert_operator cleaned.length, :<=, Brain::MAX_CHARS
    refute_match(/\s\z/, cleaned)
  end

  # Nothing usable is a normal outcome, not an error: the bot reads the room
  # instead, like a person who started typing and thought better of it.
  def test_nothing_usable_becomes_nothing_rather_than_an_empty_post
    assert_nil Brain.clean("   ")
    assert_nil Brain.clean(nil)
    assert_nil Brain.clean("Ana:", name: "Ana")
  end

  def context(recent: [])
    Brain::Context.new(kind: :post, target: nil, target_name: nil,
                       recent: recent, name: "Ana", room: "general")
  end

  def test_a_scripted_bot_does_not_repeat_itself_immediately
    persona = Persona.new({ "username" => "S", "brain" => "scripted",
                            "lines" => %w[one two three four] })
    brain   = Brain::Scripted.new(persona: persona, random: Random.new(2))
    said    = Array.new(12) { brain.compose(context) }

    assert_empty said.each_cons(2).select { |a, b| a == b }, "said the same line twice running"
  end

  # Until it has read enough, the chain would just parrot its input back.
  def test_a_markov_bot_falls_back_to_its_seed_lines_until_it_has_read_enough
    persona = Persona.new({ "username" => "S", "brain" => "markov",
                            "lines" => ["a quiet opener here"] })
    brain   = Brain::Markov.new(persona: persona, random: Random.new(3))

    assert_equal "a quiet opener here", brain.compose(context)
  end

  def test_a_markov_bot_speaks_from_what_it_has_read
    persona = Persona.new({ "username" => "S", "brain" => "markov",
                            "lines" => ["seed line here"] })
    brain   = Brain::Markov.new(persona: persona, random: Random.new(3))
    corpus  = Array.new(40) { |i| ["someone", "the build is broken again today number #{i}"] }

    said = brain.compose(context(recent: corpus))

    refute_nil said
    assert(said.split.any? { |word| %w[build broken again today].include?(word) },
           "nothing it said came from what it read: #{said.inspect}")
  end
end
