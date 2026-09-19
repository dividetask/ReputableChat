# frozen_string_literal: true

require "base64"
require "securerandom"
require "ed25519"
require_relative "../operator"
require_relative "../cryptography/seed"
require_relative "../cryptography/signature"
require_relative "../cryptography/canonical"

module ReputableChat
  module Bot
    # A bot account: seed phrase in, signatures out.
    #
    # The phrase is a real BIP39 seed and the key is derived exactly as the
    # browser derives it, so a bot account is indistinguishable from a human
    # one -- you can log into any bot from the login screen and see what it has
    # been doing.
    #
    # Argon2id runs through Operator, which is the same script/derive_key.mjs
    # the genesis account uses and the same vendored hash-wasm the browser
    # loads. Signing is then plain Ruby: the KDF output IS the Ed25519 private
    # key, so once it is in hand there is no reason to pay for a subprocess per
    # signature.
    class Identity
      class DerivationFailed < StandardError; end

      attr_reader :phrase, :pubkey

      # Fresh entropy in, a valid phrase out. New accounts are made this way
      # rather than by writing a phrase into every persona file, because a
      # recycling bot burns through one every few days.
      def self.generate_phrase(words: Cryptography::Seed::MIN_WORDS)
        bits    = Cryptography::Seed.entropy_bits_for(words)
        entropy = SecureRandom.random_bytes((bits / 8.0).ceil).unpack1("B*")[0, bits]

        Cryptography::Seed.encode(entropy, words)
      end

      # `seed_config` is the server's own `seed:` section, fetched from
      # /api/defaults. Taking the KDF parameters from the server rather than
      # hardcoding them means a bot follows a raised work factor the way a
      # browser does.
      def initialize(phrase:, seed_config:)
        @phrase = Cryptography::Seed.normalize(phrase)
        Cryptography::Seed.validate!(@phrase, min_words: seed_config.fetch("min_words"))

        derived  = derive(seed_config.fetch("kdf"))
        @signing = Ed25519::SigningKey.new(Base64.urlsafe_decode64(derived.fetch("private_key")))
        @pubkey  = Cryptography::Signature.encode(@signing.verify_key.to_bytes)

        return if @pubkey == derived["pubkey"]

        raise DerivationFailed, "ruby derived #{@pubkey} but node derived #{derived['pubkey']}"
      end

      def sign(payload)
        Cryptography::Signature.encode(@signing.sign(Cryptography::Canonical.bytes(payload)))
      end

      # Eight characters of the key, the shorthand the UI shows beside a
      # display name. Only used in this tool's own logging.
      def fingerprint = @pubkey[0, 8]

      private

      def derive(kdf)
        Operator.derive(@phrase, kdf)
      rescue Operator::HelperFailed => e
        raise DerivationFailed, e.message
      end
    end
  end
end
