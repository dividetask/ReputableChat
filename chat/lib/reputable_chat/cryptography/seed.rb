# frozen_string_literal: true

require "digest"

module ReputableChat
  module Cryptography
    # BIP39 wordlist encoding and checksum.
    #
    # The server never sees a seed -- this exists as the reference
    # implementation that public/js/seed.js must match byte for byte, and as
    # the source of the shared test vectors in spec/seed_spec.rb.
    #
    # Sizing (see docs/project/identity.md): 2048 words is 11 bits each, and 8
    # bits go to the checksum. Eight words is therefore 80 bits of entropy.
    # Because there is no username to salt with, an attacker grinds candidate
    # seeds against every registered public key at once, so the cost of
    # breaking SOME account is 2**80 / users rather than 2**80. At 10M users
    # that is ~457 years against a memory-hard KDF. Seven words would be ~81
    # days. The KDF is not optional at any length.
    module Seed
      WORDLIST_PATH = File.expand_path("../../../config/bip39-english.txt", __dir__)
      BITS_PER_WORD = 11
      CHECKSUM_BITS = 8
      MIN_WORDS     = 8

      class InvalidSeed < StandardError; end

      module_function

      def wordlist
        @wordlist ||= File.readlines(WORDLIST_PATH, chomp: true).map(&:strip).freeze
      end

      def word_index
        @word_index ||= wordlist.each_with_index.to_h.freeze
      end

      # Normalized form: lowercase, single-spaced. Both the checksum and the
      # KDF run over this, so whitespace and case can never change an identity.
      def normalize(phrase)
        phrase.to_s.downcase.strip.split(/\s+/).join(" ")
      end

      def words(phrase) = normalize(phrase).split(" ")

      def valid?(phrase, min_words: MIN_WORDS)
        validate!(phrase, min_words: min_words)
        true
      rescue InvalidSeed
        false
      end

      # Raises with a reason the UI can show. Distinguishing "not a word" from
      # "checksum failed" matters: the first is a typo the user can fix, the
      # second means they have transposed or mis-remembered something.
      def validate!(phrase, min_words: MIN_WORDS)
        list = words(phrase)

        raise InvalidSeed, "a seed needs at least #{min_words} words" if list.size < min_words

        unknown = list.reject { |w| word_index.key?(w) }
        raise InvalidSeed, "not in the wordlist: #{unknown.join(', ')}" if unknown.any?

        raise InvalidSeed, "checksum failed - check for a mistyped or swapped word" unless checksum_ok?(list)

        true
      end

      def checksum_ok?(list)
        bits = list.map { |w| word_index.fetch(w).to_s(2).rjust(BITS_PER_WORD, "0") }.join
        entropy_bits = bits[0...-CHECKSUM_BITS]
        provided     = bits[-CHECKSUM_BITS..]

        provided == checksum_for(entropy_bits, list.size)
      end

      # The word count is hashed alongside the entropy so that seeds of
      # different lengths cannot collide once the entropy is byte-padded.
      def checksum_for(entropy_bits, word_count)
        padded = entropy_bits.ljust((entropy_bits.length / 8.0).ceil * 8, "0")
        bytes  = [padded].pack("B*")
        digest = Digest::SHA256.digest([word_count].pack("C") + bytes)

        digest.unpack1("B*")[0, CHECKSUM_BITS]
      end

      # Builds a valid phrase from raw entropy bits. Used by the tests and by
      # the client when generating a new seed.
      def encode(entropy_bits, word_count)
        bits = entropy_bits + checksum_for(entropy_bits, word_count)
        bits.chars.each_slice(BITS_PER_WORD).map { |slice| wordlist.fetch(slice.join.to_i(2)) }.join(" ")
      end

      def entropy_bits_for(word_count) = (word_count * BITS_PER_WORD) - CHECKSUM_BITS
    end
  end
end
