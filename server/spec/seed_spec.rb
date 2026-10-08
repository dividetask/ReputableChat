# frozen_string_literal: true

require_relative "spec_helper"
require "agnostic/seed"

# A phrase the server writes has to be the same account in a browser client,
# so its words, checksum and key derivation are the clients'.
class SeedSpec < Minitest::Test
  # The development genesis account's phrase, public on purpose.
  GENESIS_SEED = File.expand_path("fixtures/development-genesis.seed", __dir__)

  def test_the_wordlist_is_the_canonical_bip39_english_list
    assert_equal "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
                 Digest::SHA256.file(Agnostic::Seed::WORDLIST).hexdigest
  end

  # The development genesis phrase is public, and its key is known: the one
  # a browser derives from it, and the one the development genesis carries.
  # Change the derivation or its parameters and this is a different account.
  def test_a_phrase_derives_the_key_the_browser_derives
    phrase = File.read(GENESIS_SEED)
    assert_equal "DRaBa2gChkx35qTlH8xqTG96uOX_T8TEDmuGQqy6Ndk",
                 Agnostic::Keys.public_key(Agnostic::Seed.signing_key(phrase))
  end

  def test_the_derivation_parameters_are_the_networks
    assert_equal({ domain: "reputablechat:seed:v1", iterations: 3, memory_kib: 65_536, parallelism: 1 },
                 Agnostic::Seed::KDF)
  end

  def test_a_new_phrase_is_twelve_words_with_a_valid_checksum
    phrase = Agnostic::Seed.generate
    assert_equal 12, phrase.split.size
    assert_equal phrase, Agnostic::Seed.validate!(phrase)
  end

  def test_a_swapped_word_fails_the_checksum
    words = File.read(GENESIS_SEED).split
    words[0], words[1] = words[1], words[0]
    assert_raises(Agnostic::Seed::InvalidSeed) { Agnostic::Seed.validate!(words.join(" ")) }
  end
end
