# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "identity"
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
      def introduce(voucher:, target:, client:, seed_config:, defaults:)
        identity = sign_in(voucher, client, seed_config)
        config   = own_config(client, identity, voucher)
        ratings = config.fetch("ratings")
        return :already_rated if ratings.dig(target, "net_votes").to_i >= votes(defaults)

        ratings[target] = introduction(ratings[target], defaults)
        client.publish_config(
          identity: identity, version: config.fetch("version") + 1,
          profile: config.fetch("profile"), ratings: ratings
        )

        :rated
      end

      # Registers the account and gives it a profile, so that a voucher looks
      # like an account rather than a bare key when somebody goes looking at
      # who introduced all these bots.
      def establish(voucher:, client:, seed_config:)
        identity = sign_in(voucher, client, seed_config)
        config   = own_config(client, identity, voucher)
        return :ready unless config.fetch("version").zero?

        client.publish_config(identity: identity, version: 1,
                              profile: config.fetch("profile"), ratings: {})
        :published
      end

      private

      def sign_in(voucher, client, seed_config)
        identity = Identity.new(phrase: voucher.seed, seed_config: seed_config)
        session  = client.log_in(identity)
        client.register unless session["registered"]

        identity
      end

      def introduction(before, defaults)
        current = before || { "friend" => false, "reported" => false, "net_votes" => 0, "cleared" => false }

        current.merge("reported" => false, "cleared" => false,
                      "net_votes" => [current["net_votes"].to_i, votes(defaults)].max)
      end

      # Read off the curve under the server's own parameters, so retuning the
      # curve moves it rather than leaving a hardcoded number that used to be
      # enough.
      def votes(defaults)
        @votes ||= Reputation::Engine.new(
          config: Config.new(defaults: defaults), store: Store::Memory.new
        ).minimum_visible_votes
      end

      def own_config(client, identity, voucher)
        blob = client.config(identity.pubkey)

        if blob
          payload = JSON.parse(blob["payload"])
          { "version" => payload["version"].to_i, "profile" => payload["profile"],
            "ratings" => payload["ratings"] || {} }
        else
          { "version" => 0, "ratings" => {},
            "profile" => { "username" => voucher.username, "icon" => nil,
                           "message" => "introduces new test accounts" } }
        end
      end
    end
  end
end
