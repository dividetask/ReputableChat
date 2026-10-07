# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "identity"
require_relative "view"
require "bigdecimal"
require_relative "../config"
require_relative "../reputation/engine"
require_relative "../store/memory"

module ReputableChat
  module Bot
    # The accounts that introduce new bots to the network.
    #
    # A new account sits at exactly zero and is invisible to everyone. That is
    # the sybil defense, and it applies to bots as hard as it applies to
    # anybody -- so a swarm cannot simply opt out of it with show_unrated and
    # call the test realistic. Somebody visible has to vouch.
    #
    # The genesis account cannot do it directly for every bot: Tim friending
    # two hundred accounts would make Tim a rubber stamp and nothing downstream
    # would mean anything. Instead Tim friends a handful of vouchers once, and
    # the vouchers rate new bots as they are born. A bot is then three hops
    # from anyone who rates Tim -- visible, and nowhere near trusted, which is
    # exactly what a brand new account should be.
    #
    # `bin/vouch` creates the pool and gets Tim to friend it.
    class Vouchers
      class Empty < StandardError; end

      Voucher = Struct.new(:name, :seed, :pubkey, :username, keyword_init: true)

      attr_reader :path

      def self.load(path)
        data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        new(path, data)
      end

      def initialize(path, data = {})
        @path      = path
        @vouchers  = Array(data["vouchers"]).map { |row| Voucher.new(**row.transform_keys(&:to_sym)) }
      end

      def size = @vouchers.size
      def all = @vouchers.dup
      def pubkeys = @vouchers.map(&:pubkey)
      def empty? = @vouchers.empty?

      def sample(random: Random.new)
        raise Empty, missing_message if empty?

        @vouchers.sample(random: random)
      end

      def missing_message
        "no vouchers in #{@path}. Run `bin/vouch --count 3` first, or new bots " \
          "will be invisible to everyone including each other."
      end

      # Creates however many are missing. Does not register them -- that needs
      # a session, which is the caller's business.
      def grow_to(count, seed_config:)
        added = []

        while @vouchers.size < count
          number  = @vouchers.size + 1
          phrase  = Identity.generate_phrase
          pubkey  = Identity.new(phrase: phrase, seed_config: seed_config).pubkey
          voucher = Voucher.new(name: "voucher-#{number}", seed: phrase, pubkey: pubkey,
                                username: "introducer #{number}")

          @vouchers << voucher
          added << voucher
        end

        added
      end

      # Written 0600: these are seed phrases, and whoever holds one is that
      # account.
      def save
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate("vouchers" => @vouchers.map { |v| v.to_h.transform_keys(&:to_s) }))
        end
        File.rename(tmp, @path)
        File.chmod(0o600, @path)
        self
      end

      # --- acting as one -----------------------------------------------------

      # Signs in as `voucher` and rates `target` the least amount that clears
      # the visibility line. Deliberately not a friendship: this says "this
      # account exists", not "I know them", and the difference is the whole
      # of what the vouchers are for.
      def introduce(voucher:, target:, client:, seed_config:, defaults:, ack:)
        identity = sign_in(voucher, client, seed_config)
        state    = own_records(client, identity)
        scores   = state.fetch(:scores)
        wanted   = visible_reputation(defaults)
        return :already_rated if scores.key?(target) && BigDecimal(scores.dig(target, "reputation").to_s).positive?

        scores[target] = { "reputation" => wanted, "trust" => "1" }
        client.publish_attestation(
          identity: identity, revision: state.fetch(:attestation_revision) + 1,
          scores: scores, derived: View::NO_CACHE, ack: ack
        )

        :rated
      end

      # Declares the account, so a voucher looks like an account rather than a
      # bare key when somebody goes looking at who introduced all these bots.
      def establish(voucher:, client:, seed_config:, ack:)
        identity = sign_in(voucher, client, seed_config)
        state    = own_records(client, identity)
        return :ready unless state.fetch(:identity_revision).zero?

        client.publish_identity(identity: identity, revision: 1, handle: voucher.username,
                                bio: "introduces new test accounts", ack: ack)
        :published
      end

      private

      def sign_in(voucher, client, seed_config)
        identity = Identity.new(phrase: voucher.seed, seed_config: seed_config)
        session  = client.log_in(identity)
        client.register unless session["registered"]

        identity
      end

      # The published scores, not the actions behind them. A voucher has no
      # private state anywhere and does not need any: the only thing anybody
      # reads is the number.
      def own_records(client, identity)
        declaration = parse(client.identity(identity.pubkey))
        published   = parse(client.attestation(identity.pubkey))

        { identity_revision: declaration ? declaration["revision"].to_i : 0,
          attestation_revision: published ? published["revision"].to_i : 0,
          scores: published ? (published["scores"] || {}) : {} }
      end

      def parse(blob)
        return nil unless blob

        JSON.parse(blob["payload"])
      rescue JSON::ParserError
        nil
      end

      # Read off the curve under the server's own parameters, so retuning the
      # curve moves it rather than leaving a hardcoded number that used to be
      # enough.
      def visible_reputation(defaults)
        @visible_reputation ||= Reputation::Engine.new(
          config: Config.new(defaults: defaults), store: Store::Memory.new
        ).minimum_visible_reputation
      end
    end
  end
end
