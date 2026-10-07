# frozen_string_literal: true

require "json"
require_relative "../config"
require_relative "../reputation/engine"
require_relative "../reputation/score"
require_relative "../reputation/session"
require_relative "../store/memory"

module ReputableChat
  module Bot
    # What this account can actually see, and what it publishes.
    #
    # A bot reads the room through the same reputation it would see in a
    # browser: it walks out from its own opinions, fetches a hop of
    # attestations per request, sorts everyone into trusted / tolerated /
    # blocked, and drops the blocked.
    #
    # A visit is a login, so the sort happens once on arrival and holds for the
    # rest of the visit -- which is the rule the design is built on, not a
    # shortcut. Reacting during a visit changes nobody's bucket until the bot
    # comes back.
    #
    # The bot's own actions are private and live in its state file; what goes
    # out is the attestation, which carries the numbers those actions come to.
    # Nothing else can see an action, so nothing else needs it.
    Message = Struct.new(:hash, :signature, :pubkey, :body, :ts, :reply_to, :received_at,
                         keyword_init: true)

    class View
      # Deliberately empty, as in script/tim.rb. `derived` is the author's own
      # calculated reputations for everyone their walk reached, offered to
      # readers whose own reach ran out. A bot could publish a real one; until
      # something decides that a swarm's caches are worth reading, publishing
      # none says "I am offering you nothing" where a half-filled one would
      # offer a number nobody asked how it was reached.
      NO_CACHE = { "scores" => {} }.freeze

      attr_reader :handle, :bio, :identity_revision, :attestation_revision,
                  :session, :messages, :reactions

      def initialize(client:, identity:, persona:, defaults:, genesis_hash:)
        @client       = client
        @identity     = identity
        @persona      = persona
        @genesis_hash = genesis_hash
        @config       = Config.new(defaults: defaults, overrides: persona.display_overrides)
      end

      # Everything a visit starts with. `ratings` is the bot's own private
      # actions, which only it holds.
      def arrive!(ratings)
        load_own_records
        build_session(ratings)
        refresh_room
        self
      end

      # Called on every poll while the bot is present. Deliberately does not
      # rebuild the session: buckets do not move mid-visit, by design.
      def refresh_room
        @messages  = @client.messages.filter_map { |row| parse_message(row) }
        @reactions = @client.reactions

        # Authors who are not in the walk still need their declaration, or
        # every name in the room is a base64 fragment. The browser does the
        # same on each refresh. It adds nothing to the graph -- the session's
        # snapshot was taken on arrival and does not change.
        learn_authors
        self
      end

      def visible_messages = @messages.select { |m| @session.visible?(m.pubkey) }

      def visible_from_others
        visible_messages.reject { |m| m.pubkey == @identity.pubkey }
      end

      def display_name(pubkey)
        return @handle if pubkey == @identity.pubkey

        @handles[pubkey] || "user-#{pubkey[0, 6]}"
      end

      # The record this bot's next record acknowledges: the most recent one it
      # can see whose author it rates above the bar, or the genesis if there is
      # none. Subjective by construction -- it is the acknowledging user's own
      # reputation that decides, which is why the server cannot check it.
      def ack
        bar = @config.decimal("chain.min_reputation_to_acknowledge")

        recent = @messages.reverse.find do |message|
          next false unless message.hash
          next true if message.pubkey == @identity.pubkey

          @session.explain(message.pubkey).fetch(:effective) > bar
        end

        recent ? recent.hash : @genesis_hash
      end

      # --- publishing -------------------------------------------------------

      # Who the bot says it is. Separate from the attestation because a display
      # name and an opinion change on completely different clocks.
      def publish_identity!(handle:, bio:)
        @handle = handle
        @bio    = bio
        @identity_revision += 1

        @client.publish_identity(identity: @identity, revision: @identity_revision,
                                 handle: handle, bio: bio, ack: ack_or_genesis)
      rescue Client::Conflict
        reload_identity_revision
        @identity_revision += 1
        @client.publish_identity(identity: @identity, revision: @identity_revision,
                                 handle: handle, bio: bio, ack: ack_or_genesis)
      end

      # The numbers the bot's private actions come to. A reaction that never
      # reaches an attestation changes nobody's reputation: the records are the
      # display form, this is the reputation form.
      def publish_attestation!(ratings)
        @attestation_revision += 1
        send_attestation(ratings)
      rescue Client::Conflict
        # Somebody wrote a newer revision under this key -- another instance of
        # the same bot, usually. Re-read and try once from where it actually is.
        reload_attestation_revision
        @attestation_revision += 1
        send_attestation(ratings)
      end

      private

      def send_attestation(ratings)
        @client.publish_attestation(
          identity: @identity, revision: @attestation_revision,
          scores: scoring_engine.publishable_scores(ratings),
          derived: NO_CACHE, ack: ack_or_genesis
        )
      end

      # An engine with nothing in its store: it is wanted for the curve and the
      # friend value, not for a walk.
      def scoring_engine
        @scoring_engine ||= Reputation::Engine.new(config: @config, store: Store::Memory.new)
      end

      # Before the room has been fetched there is nothing to acknowledge but
      # the bottom of the chain, which is the right answer for an account's
      # first record anyway.
      def ack_or_genesis = @messages ? ack : @genesis_hash

      def load_own_records
        declaration = parse_payload(@client.identity(@identity.pubkey))
        @identity_revision = declaration ? declaration["revision"].to_i : 0
        @handle = declaration ? declaration["handle"] : @persona.username
        @bio    = declaration ? declaration["bio"] : @persona.bio

        reload_attestation_revision
      end

      def reload_identity_revision
        declaration = parse_payload(@client.identity(@identity.pubkey))
        @identity_revision = declaration ? declaration["revision"].to_i : 0
      end

      def reload_attestation_revision
        published = parse_payload(@client.attestation(@identity.pubkey))
        @attestation_revision = published ? published["revision"].to_i : 0
      end

      # The walk out from the viewer, a hop per request, bounded by max_hops
      # and max_configs together -- a positive-only graph still branches, so
      # hop count alone does not bound the fetch.
      #
      # The viewer's own row is its private actions; everyone else's is the
      # scores they published. The engine reads either without knowing which it
      # has, which is the whole point of a Score answering the same questions a
      # Rating does.
      def build_session(ratings)
        @graph   = Store::Memory.new
        @handles = {}
        @fetched = {}

        ratings.each { |target, action| @graph.put(@identity.pubkey, target, Reputation::Rating.from_h(action)) }

        frontier = [@identity.pubkey]
        seen     = { @identity.pubkey => true }
        hops     = @config.fetch("ladder.max_hops").to_i
        budget   = @config.fetch("ladder.max_accounts").to_i

        hops.times do
          wanted = []
          frontier.each do |rater|
            @graph.ratings_by(rater).each do |subject, score|
              next if seen.key?(subject) || (seen.size + wanted.size) >= budget
              next unless positive?(score)

              wanted << subject
            end
          end
          break if wanted.empty?

          fetch_attestations(wanted)
          wanted.each { |pubkey| seen[pubkey] = true }
          frontier = wanted
        end

        @session = Reputation::Session.new(
          engine: Reputation::Engine.new(config: @config, store: @graph),
          viewer: @identity.pubkey
        )
      end

      def fetch_attestations(pubkeys)
        fresh = pubkeys.reject { |pubkey| @fetched.key?(pubkey) }
        return if fresh.empty?

        fresh.each { |pubkey| @fetched[pubkey] = true }

        @client.attestations(fresh).each do |blob|
          payload = parse_payload(blob)
          # MVP: signatures are taken on trust, exactly as the browser does
          # (session.verify_signatures). Guarding the pubkey match is the one
          # check that costs nothing.
          next unless payload && payload["pubkey"] == blob["pubkey"]

          (payload["scores"] || {}).each do |target, score|
            @graph.put(blob["pubkey"], target, Reputation::Score.from_h(score))
          end
        end
      end

      # Display names only. Recorded even when the fetch finds nothing, so an
      # author who has never declared an identity is not asked for again on
      # every poll.
      def learn_authors
        authors = (@messages.map(&:pubkey) + @reactions.map { |r| r["pubkey"] }).compact.uniq
        unknown = authors.reject { |pubkey| @handles.key?(pubkey) }
        return if unknown.empty?

        unknown.each { |pubkey| @handles[pubkey] = nil }

        @client.identities(unknown).each do |blob|
          payload = parse_payload(blob)
          next unless payload && payload["pubkey"] == blob["pubkey"]

          @handles[blob["pubkey"]] = payload["handle"]
        end
      end

      def positive?(score)
        score.value(curve: scoring_engine.curve,
                    friend_value: @config.decimal("actions.friend.value")) >
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
          hash: row["hash"], signature: row["signature"], pubkey: row["pubkey"],
          body: payload["body"], ts: payload["ts"], reply_to: row["reply_to"],
          received_at: row["received_at"]
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
