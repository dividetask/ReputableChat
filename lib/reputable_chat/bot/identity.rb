# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "ed25519"
require_relative "../cryptography/seed"
require_relative "../cryptography/signature"
require_relative "../cryptography/canonical"

module ReputableChat
  module Bot
    # A bot account: seed phrase in, signatures out.
    #
    # The phrase is a real BIP39 seed and the key is derived exactly as the
    # browser derives it, so a bot account is indistinguishable from a human
    # one -- you can log into any bot from the UI and see what it has been
    # doing. The Argon2id step runs through tools/argon2-derive.mjs, which
    # loads the same vendored hash-wasm the browser loads; a second Ruby
    # implementation of the KDF could drift from it silently.
    class Identity
      SHIM = File.expand_path("../../../tools/argon2-derive.mjs", __dir__)

      class DerivationFailed < StandardError; end

      attr_reader :phrase, :pubkey

      # Fresh entropy in, a valid phrase out. New accounts are made this way
      # rather than by handing every bot a phrase in its config, because a
      # recycling bot burns through one every few days.
      def self.generate_phrase(words: Cryptography::Seed::MIN_WORDS)
        bits    = Cryptography::Seed.entropy_bits_for(words)
        entropy = SecureRandom.random_bytes((bits / 8.0).ceil).unpack1("B*")[0, bits]

        Cryptography::Seed.encode(entropy, words)
      end

      # `seed_config` is the server's own `seed:` section, fetched from
      # /api/defaults. Taking the KDF parameters from the server rather than
      # hardcoding them means a bot follows a raised work factor the same way
      # a browser does.
      def initialize(phrase:, seed_config:, node: ENV.fetch("BOT_NODE", "node"))
        @phrase = Cryptography::Seed.normalize(phrase)
        @kdf    = seed_config.fetch("kdf")
        @node   = node

        Cryptography::Seed.validate!(@phrase, min_words: seed_config.fetch("min_words"))

        @signing = Ed25519::SigningKey.new(stretch)
        @pubkey  = Cryptography::Signature.encode(@signing.verify_key.to_bytes)
      end

      def sign(payload)
        Cryptography::Signature.encode(@signing.sign(Cryptography::Canonical.bytes(payload)))
      end

      # Eight hex characters of the key, the same shorthand the UI shows beside
      # a display name. Only ever used in this tool's own logging.
      def fingerprint = @pubkey[0, 8]

      private

      def stretch
        request = JSON.generate("phrase" => @phrase, "kdf" => @kdf)
        out, err, status = Open3.capture3(@node, SHIM, stdin_data: request)

        raise DerivationFailed, "argon2 shim failed: #{err.strip}" unless status.success?
        raise DerivationFailed, "argon2 shim returned #{out.bytesize} hex chars" unless out.strip.length == 64

        [out.strip].pack("H*")
      end
    end
  end
end
