# frozen_string_literal: true

require "yaml"
require_relative "schedule"

module ReputableChat
  module Bot
    # One bot's configuration file: who it is, how it talks, how often it shows
    # up, and whether it burns its account down every few days.
    #
    # `disposition` is the whole of the bot's character. It goes to the model
    # as the system prompt, so it can be one word or several paragraphs.
    class Persona
      class Invalid < StandardError; end

      BRAINS = %w[scripted markov llm].freeze

      DEFAULTS = {
        "room" => "general",
        "bio" => "",
        "brain" => "scripted",
        "lines" => [],
        "disposition" => "",
        "reply_ratio" => 0.7,
        "friend_per_visit" => 0.02,
        # On by default, unlike a human account. An unrated account sits at
        # exactly zero and is therefore invisible to everyone, including other
        # bots -- a swarm that could not see itself would have nothing to
        # react to and would never get started.
        "show_unrated" => true,
        "poll_seconds" => 10,
        "emote_bias" => { "positive" => 8, "neutral" => 2, "negative" => 1 },
        "recycle_after_days" => nil,
        "seed" => nil,
        "usernames" => [],
        "posting" => {},
        "llm" => {}
      }.freeze

      LLM_DEFAULTS = {
        "endpoint" => "http://localhost:11434/v1/chat/completions",
        "model" => "gemma3:270m",
        "max_tokens" => 60,
        "temperature" => 1.0,
        "timeout_seconds" => 60
      }.freeze

      attr_reader :path, :username, :usernames, :bio, :room, :disposition, :brain, :lines,
                  :emote_bias, :reply_ratio, :friend_per_visit, :show_unrated,
                  :poll_seconds, :recycle_after_days, :seed, :posting, :llm

      def self.load(path)
        raw = YAML.safe_load_file(path)
        raise Invalid, "#{path} is not a YAML mapping" unless raw.is_a?(Hash)

        new(raw, path: path)
      end

      def initialize(raw, path: nil)
        settings = DEFAULTS.merge(raw || {})
        @path    = path

        @username           = text(settings, "username")
        @usernames          = Array(settings["usernames"]).map(&:to_s).reject(&:empty?)
        @bio                = settings["bio"].to_s
        @room               = text(settings, "room")
        @disposition        = settings["disposition"].to_s.strip
        @brain              = text(settings, "brain")
        @lines              = Array(settings["lines"]).map(&:to_s).reject(&:empty?)
        @emote_bias         = DEFAULTS["emote_bias"].merge(settings["emote_bias"] || {})
        @reply_ratio        = fraction(settings, "reply_ratio")
        @friend_per_visit   = fraction(settings, "friend_per_visit")
        @show_unrated       = settings["show_unrated"] ? true : false
        @poll_seconds       = Integer(settings["poll_seconds"])
        @recycle_after_days = settings["recycle_after_days"]&.to_f
        @seed               = settings["seed"]
        @posting            = settings["posting"] || {}
        @llm                = LLM_DEFAULTS.merge(settings["llm"] || {})

        validate!
      end

      # The user layer of the three-layer config, so a bot sees the room
      # through the same resolution path a browser would.
      def display_overrides = { "display" => { "show_unrated" => @show_unrated } }

      def schedule(random: Random.new) = Schedule.new(@posting, random: random)

      # Bots that recycle are the spam simulation: they post for a few days,
      # abandon the account and start again somewhere new, so a reputation
      # earned against them stops mattering. That whack-a-mole is the thing
      # worth testing, and it is the one place where "forgetting" credentials
      # is a feature.
      def recycles? = !@recycle_after_days.nil?

      # A recycled account that comes back under the same display name is
      # obvious to a human reader, and this is meant to test the reputation
      # system rather than the reader. `usernames` supplies the pool; without
      # one a later generation just takes a numeric suffix.
      def username_for(generation, random: Random.new)
        return @usernames.sample(random: random) unless @usernames.empty?
        return @username if generation.zero?

        "#{@username}#{random.rand(100..999)}"
      end

      # Drawn per account so a fleet started together does not all vanish on
      # the same afternoon.
      def lifetime_days(random: Random.new)
        return nil unless recycles?

        @recycle_after_days * (0.7 + (0.6 * random.rand))
      end

      private

      def validate!
        raise Invalid, "brain must be one of #{BRAINS.join(', ')}" unless BRAINS.include?(@brain)
        raise Invalid, "a scripted bot needs at least one entry under `lines`" if @brain == "scripted" && @lines.empty?
        raise Invalid, "an llm bot needs a `disposition` to act on" if @brain == "llm" && @disposition.empty?
        raise Invalid, "room must match [a-z0-9][a-z0-9-]*" unless @room.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
        raise Invalid, "poll_seconds must be at least 2" if @poll_seconds < 2
        raise Invalid, "recycle_after_days must be positive" if @recycle_after_days&.<=(0)

        if @emote_bias.values.sum { |v| Float(v) } <= 0
          raise Invalid, "emote_bias needs at least one positive weight"
        end

        schedule # surfaces a contradictory posting block here rather than mid-run
      end

      def text(settings, key)
        value = settings[key].to_s.strip
        raise Invalid, "#{key} is required" if value.empty?

        value
      end

      def fraction(settings, key)
        value = Float(settings.fetch(key), exception: false)
        raise Invalid, "#{key} must be a number between 0 and 1" if value.nil? || !value.between?(0, 1)

        value
      end
    end
  end
end
