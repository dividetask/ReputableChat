# frozen_string_literal: true

require "argon2"
require "digest"
require "ed25519"
require "securerandom"

module Agnostic
  # Seed phrases, made and read the way the browser does
  # (chat/public/js/seed.js and identity.js), so a phrase this server writes
  # signs in the chat client as the same account.
  #
  # A phrase is BIP39 English words: 11 bits each, the last 8 bits a checksum
  # over the entropy and the word count. The key is Argon2id over the
  # normalized phrase, salted with the derivation domain, and its 32 bytes are
  # the Ed25519 private key.
  module Seed
    # The canonical BIP39 English list, in shared/ at the root: the chat reads
    # the same file, so a phrase is the same account in either.
    WORDLIST = File.expand_path("../../../shared/bip39-english.txt", __dir__)
    BITS_PER_WORD = 11
    CHECKSUM_BITS = 8
    WORDS = 12

    # chat/config/reputation.yml, seed.kdf. Changing any of these derives a
    # different key from every phrase, which strands every account; a spec
    # holds them equal to the chat's.
    KDF = { domain: "reputablechat:seed:v1", iterations: 3, memory_kib: 65_536, parallelism: 1 }.freeze

    class InvalidSeed < StandardError; end

    module_function

    def wordlist = @wordlist ||= File.readlines(WORDLIST, chomp: true).map(&:strip).freeze

    def normalize(phrase) = phrase.to_s.downcase.strip.split(/\s+/).join(" ")

    def generate(words = WORDS)
      bits = entropy_bits(words)
      entropy = SecureRandom.bytes((bits / 8.0).ceil).unpack1("B*")[0, bits]
      (entropy + checksum(entropy, words)).chars.each_slice(BITS_PER_WORD)
                                          .map { |slice| wordlist.fetch(slice.join.to_i(2)) }.join(" ")
    end

    def validate!(phrase)
      list = normalize(phrase).split(" ")
      unknown = list.reject { |w| wordlist.include?(w) }
      raise InvalidSeed, "not in the wordlist: #{unknown.join(', ')}" unless unknown.empty?

      bits = list.map { |w| wordlist.index(w).to_s(2).rjust(BITS_PER_WORD, "0") }.join
      raise InvalidSeed, "checksum failed" unless bits[-CHECKSUM_BITS..] == checksum(bits[0...-CHECKSUM_BITS], list.size)

      normalize(phrase)
    end

    def signing_key(phrase)
      phrase = validate!(phrase)
      hex = Argon2::Engine.hash_argon2id(phrase.b, KDF[:domain].b, KDF[:iterations],
                                         Math.log2(KDF[:memory_kib]).to_i, KDF[:parallelism], 32)
      Ed25519::SigningKey.new([hex].pack("H*"))
    end

    def entropy_bits(words) = (words * BITS_PER_WORD) - CHECKSUM_BITS

    # The word count is hashed with the entropy so phrases of different
    # lengths cannot collide once the entropy is padded to whole bytes.
    def checksum(entropy, words)
      padded = entropy.ljust((entropy.length / 8.0).ceil * 8, "0")
      Digest::SHA256.digest([words].pack("C") + [padded].pack("B*")).unpack1("B*")[0, CHECKSUM_BITS]
    end
  end
end
