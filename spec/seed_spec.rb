# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/crypto/seed"
require "securerandom"

# Shared vectors: public/js/seed.js must produce identical results.
class SeedSpec < Minitest::Test
  Seed = ReputableChat::Crypto::Seed

  def test_wordlist_is_the_canonical_bip39_english_list
    assert_equal 2048, Seed.wordlist.size
    assert_equal "abandon", Seed.wordlist.first
    assert_equal "zoo", Seed.wordlist.last
    assert_equal 2048, Seed.wordlist.map { |w| w[0, 4] }.uniq.size,
                 "four-character prefixes must stay unique for type-ahead"
  end

  def test_eight_words_carries_eighty_bits_of_entropy
    assert_equal 80, Seed.entropy_bits_for(8)
  end

  def test_round_trips_generated_seeds
    20.times do
      bits = Array.new(80) { rand(2) }.join
      phrase = Seed.encode(bits, 8)

      assert_equal 8, Seed.words(phrase).size
      assert Seed.valid?(phrase), "generated seed should validate: #{phrase}"
    end
  end

  def test_rejects_short_seeds
    phrase = Seed.encode(Array.new(80) { rand(2) }.join, 8)
    short  = Seed.words(phrase).first(7).join(" ")

    refute Seed.valid?(short)
    assert_raises(Seed::InvalidSeed) { Seed.validate!(short) }
  end

  def test_rejects_words_outside_the_list
    phrase = Seed.encode(Array.new(80) { rand(2) }.join, 8)
    broken = Seed.words(phrase).tap { |w| w[3] = "asdfgh" }.join(" ")

    error = assert_raises(Seed::InvalidSeed) { Seed.validate!(broken) }
    assert_match(/not in the wordlist/, error.message)
  end

  # A transposition keeps every word legal, so only the checksum catches it.
  def test_checksum_catches_transposed_words
    caught = 0
    50.times do
      words = Seed.words(Seed.encode(Array.new(80) { rand(2) }.join, 8))
      words[2], words[5] = words[5], words[2]
      caught += 1 unless Seed.valid?(words.join(" "))
    end

    # 8-bit checksum: expect ~255/256 caught. Allow slack for the rare
    # transposition of two identical words.
    assert_operator caught, :>=, 48, "checksum should catch nearly every transposition"
  end

  def test_normalization_ignores_case_and_spacing
    phrase = Seed.encode(Array.new(80) { rand(2) }.join, 8)
    messy  = "  #{phrase.upcase.gsub(' ', '   ')}  "

    assert_equal phrase, Seed.normalize(messy)
    assert Seed.valid?(messy)
  end

  def test_longer_seeds_are_accepted
    [9, 12].each do |n|
      phrase = Seed.encode(Array.new(Seed.entropy_bits_for(n)) { rand(2) }.join, n)

      assert_equal n, Seed.words(phrase).size
      assert Seed.valid?(phrase), "#{n}-word seed should validate"
    end
  end
end
