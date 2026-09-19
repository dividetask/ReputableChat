# frozen_string_literal: true

require "json"
require_relative "../config"
require_relative "../reputation/engine"
require_relative "../reputation/session"
require_relative "../store/memory"

module ReputableChat
  module Bot
    # What this account can actually see.
    #
    # A bot reads the room through the same reputation it would see in a
    # browser: it walks out from its own ratings, fetches a hop per request,
    # sorts everyone into trusted / tolerated / blocked, and drops the blocked.
    # Mirrors loadNetwork() and Session in public/js.
    #
    # A visit is a login, so the sort happens once on arrival and holds for the
    # rest of the visit -- which is the rule the design is built on, not a
    # shortcut. Reacting during a visit changes nobody's bucket until the bot
    # comes back.
    Message = Struct.new(:signature, :author, :seq, :body, :ts, :reply_to, :received_at,
                         keyword_init: true)

    class View
      attr_reader :profile, :version, :ratings, :session, :messages, :reactions

      def initialize(client:, identity:, persona:, defaults:)
        @client   = client
        @identity = identity
        @persona  = persona
        @config   = Config.new(defaults: defaults, overrides: persona.display_overrides)
      end

      # Everything a visit starts with: own config, the graph, the room.
      def arrive!
        load_own_config
        build_session
        refresh_room
        self
      end

      # Called on every poll while the bot is present. Deliberately does not
      # rebuild the session: buckets do not move mid-visit, by design.
      def refresh_room
        @messages  = @client.messages(@persona.room).filter_map { |row| parse_message(row) }
        @reactions = @client.reactions(@persona.room)

        # Authors who are not in the walk still need their profile, or every
        # name in the room is a base64 fragment. The browser does exactly this
        # on each refresh. It adds them to the graph for their names only --
        # the session's own snapshot was taken on arrival and does not change.
        learn_authors
        self
      end

      # The highest sequence number the server has from this account. The room
      # only keeps the last hundred messages, so this can undercount and is
      # only ever used to move a counter forward, never back.
      def highest_seq_for(pubkey)
        @seqs ||= {}
        @seqs[pubkey] || 0
      end

      def visible_messages = @messages.select { |m| @session.visible?(m.author) }

      def visible_from_others
        visible_messages.reject { |m| m.author == @identity.pubkey }
      end

      # Display names, for prompting the model with something more human than
      # a base64 key.
      def display_name(pubkey)
        return @profile["username"] if pubkey == @identity.pubkey

        @profiles[pubkey]&.dig("username") || "user-#{pubkey[0, 6]}"
      end

      # Ratings are the published form of everything the bot has done to
      # somebody: reactions land here as net_votes, friending as a flag. This
      # is what the rest of the network reads, so a reaction that never makes
      # it into a config never affects anyone's reputation.
      def adjust_rating(pubkey, friend: nil, votes: 0)
        current = @ratings[pubkey] || { "friend" => false, "reported" => false, "net_votes" => 0 }
        updated = current.merge("net_votes" => current.fetch("net_votes", 0) + votes)
        updated = updated.merge("friend" => friend) unless friend.nil?

        @ratings[pubkey] = updated
      end

      # The version must climb or the server rejects the write as a rollback.
      def publish_config!
        @version += 1
        @client.publish_config(
          identity: @identity, version: @version, profile: @profile, ratings: publishable_ratings
        )
      rescue Client::Conflict
        # Somebody wrote a newer version under this key -- another instance of
        # the same bot, usually. Re-read and try once from where it actually is.
        load_own_config
        @version += 1
        @client.publish_config(
          identity: @identity, version: @version, profile: @profile, ratings: publishable_ratings
        )
      end

      def set_profile(username:, bio:)
        @profile = { "username" => username, "message" => bio, "icon" => nil }
      end

      private

      # Only ratings that say something. An entry of all-defaults is noise in
      # a config that already grows without bound.
      def publishable_ratings
        @ratings.select do |_, r|
          r["friend"] || r["reported"] || r["cleared"] || r.fetch("net_votes", 0) != 0
        end
      end

      def load_own_config
        payload  = parse_payload(@client.config(@identity.pubkey))
        @version = payload ? payload["version"].to_i : 0
        @ratings = payload ? (payload["ratings"] || {}) : {}
        @profile = payload ? payload["profile"] : nil
        @profile ||= { "username" => @persona.username, "message" => @persona.bio, "icon" => nil }
      end

      # The walk out from the viewer, a hop per request, bounded by max_hops
      # and max_configs together -- a positive-only graph still branches, so
      # hop count alone does not bound the fetch.
      def build_session
        engine   = Reputation::Engine.new(config: @config, store: Store::Memory.new)
        @graph   = Store::Memory.new
        @profiles = {}

        add_ratings(@identity.pubkey, @ratings)

        frontier = [@identity.pubkey]
        seen     = { @identity.pubkey => true }
        hops     = @config.fetch("ladder.max_hops").to_i
        budget   = @config.fetch("ladder.max_configs").to_i

        hops.times do
          wanted = []
          frontier.each do |rater|
            @graph.ratings_by(rater).each do |subject, rating|
              next if seen.key?(subject) || (seen.size + wanted.size) >= budget
              next unless positive?(engine, rating)

              wanted << subject
            end
          end
          break if wanted.empty?

          fetch_configs(wanted)
          wanted.each { |pubkey| seen[pubkey] = true }
          frontier = wanted
        end

        @session = Reputation::Session.new(
          engine: Reputation::Engine.new(config: @config, store: @graph),
          viewer: @identity.pubkey
        )
      end

      def learn_authors
        @seqs = Hash.new(0)
        @messages.each { |m| @seqs[m.author] = [@seqs[m.author], m.seq.to_i].max }

        authors = (@messages.map(&:author) + @reactions.map { |r| r["author"] }).uniq
        unknown = authors.reject { |pubkey| pubkey.nil? || @profiles.key?(pubkey) }

        fetch_configs(unknown) unless unknown.empty?
      end

      def fetch_configs(pubkeys)
        # Recorded even when the fetch finds nothing, so an author who has
        # never published a config is not asked for again on every poll.
        pubkeys.each { |pubkey| @profiles[pubkey] = nil unless @profiles.key?(pubkey) }

        @client.configs(pubkeys).each do |blob|
          payload = parse_payload(blob)
          # MVP: signatures are taken on trust, exactly as the browser does
          # (session.verify_signatures). Guarding the pubkey match is the one
          # check that costs nothing.
          next unless payload && payload["pubkey"] == blob["pubkey"]

          add_ratings(blob["pubkey"], payload["ratings"] || {})
          @profiles[blob["pubkey"]] = payload["profile"]
        end
      end

      def add_ratings(pubkey, ratings)
        ratings.each { |subject, raw| @graph.put(pubkey, subject, Reputation::Rating.from_h(raw)) }
      end

      def positive?(engine, rating)
        rating.value(curve: engine.curve, friend_value: @config.decimal("actions.friend.value")) >
          @config.decimal("gate.min_rating")
      end

      def parse_payload(blob)
        return nil unless blob

        JSON.parse(blob["payload"])
      rescue JSON::ParserError
        nil
      end

      def parse_message(row)
        payload = JSON.parse(row["payload"])

        Message.new(
          signature: row["signature"], author: row["author"], body: payload["body"],
          seq: row["seq"], ts: payload["ts"], reply_to: row["reply_to"],
          received_at: row["received_at"]
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
