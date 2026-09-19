# frozen_string_literal: true

require "json"
require "fileutils"

module ReputableChat
  module Bot
    # What a bot has to remember between runs, and across a restart.
    #
    # The seed lives here rather than in the persona file because a recycling
    # bot goes through one every few days, and because one persona backs any
    # number of bots: `bin/bot personas/scammer.yml --name scammer-07` gives
    # that instance its own account and its own state without a config file of
    # its own.
    #
    # `seq` matters more than it looks. The server enforces one message per
    # (author, seq), so a bot that forgets its counter starts colliding with
    # its own history and every post it makes is rejected.
    class State
      # Enough backlog to know what it has already seen without the file
      # growing without bound. The room only serves the last 100 messages
      # anyway, so remembering many more than that buys nothing.
      REMEMBERED = 500

      attr_reader :path, :name
      attr_accessor :seed, :pubkey, :seq, :prev, :version, :born_at, :ratings,
                    :retire_after_days, :username

      def self.load(path, name:)
        data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        new(path, name: name, data: data)
      end

      def initialize(path, name:, data: {})
        @path    = path
        @name    = name
        @seed    = data["seed"]
        @pubkey  = data["pubkey"]
        @seq     = data["seq"] || 0
        @prev    = data["prev"]
        @version = data["version"] || 0
        @born_at = data["born_at"]
        @username = data["username"]
        @retire_after_days = data["retire_after_days"]
        @ratings = data["ratings"] || {}
        @seen    = data["seen"] || []
        @voted   = data["voted"] || []
        @retired = data["retired"] || []
      end

      def seen?(signature)  = @seen.include?(signature)
      def voted?(signature) = @voted.include?(signature)

      def see(signature)
        @seen = (@seen + [signature]).last(REMEMBERED) unless seen?(signature)
      end

      # One vote per message, whether it was spent reacting or replying --
      # the same rule the browser keeps in its private config.
      def vote(signature)
        @voted = (@voted + [signature]).last(REMEMBERED) unless voted?(signature)
      end

      def voted_signatures = @voted.dup

      def age_days(now: Time.now.to_i) = @born_at ? (now - @born_at) / 86_400.0 : 0.0

      def generation = @retired.size

      # `speed` is the runner's time compression. The file keeps honest
      # wall-clock timestamps; only the bot's sense of how long it has been
      # around is scaled, so a sped-up run cannot leave a state file that
      # retires itself the moment it is used at normal speed.
      def expired?(now: Time.now.to_i, speed: 1.0)
        return false unless @retire_after_days

        age_days(now: now) * speed >= @retire_after_days
      end

      # Starts a new account under the same persona. The old phrase is kept in
      # the file so you can still log into an abandoned account and look at it;
      # the bot itself never touches it again, which is the point.
      def recycle!(seed:, pubkey:, username: nil, retire_after_days: nil, now: Time.now.to_i)
        if @pubkey
          @retired = (@retired + [{ "seed" => @seed, "pubkey" => @pubkey, "username" => @username,
                                    "retired_at" => now }]).last(50)
        end

        @seed    = seed
        @pubkey  = pubkey
        @seq     = 0
        @prev    = nil
        @version = 0
        @born_at = now
        @username = username
        @retire_after_days = retire_after_days
        @ratings = {}
        @seen    = []
        @voted   = []
      end

      def retired = @retired.dup

      def save
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp"
        File.write(tmp, JSON.pretty_generate(to_h))
        File.rename(tmp, @path) # atomic, so a kill mid-write cannot lose the seed
      end

      def to_h
        { "name" => @name, "seed" => @seed, "pubkey" => @pubkey, "born_at" => @born_at,
          "username" => @username, "retire_after_days" => @retire_after_days,
          "seq" => @seq, "prev" => @prev, "version" => @version,
          "ratings" => @ratings, "seen" => @seen, "voted" => @voted, "retired" => @retired }
      end
    end
  end
end
