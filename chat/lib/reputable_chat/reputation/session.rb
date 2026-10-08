# frozen_string_literal: true

require_relative "engine"
require_relative "../store/memory"

module ReputableChat
  module Reputation
    # One login's worth of reputation.
    #
    # Scores are computed once, everyone is sorted into Trusted, Tolerated or
    # Blocked, and the numbers are then discarded. For the rest of the session
    # the buckets are what matters: further likes and dislikes, from you or
    # anyone else, do not move anyone until the next login.
    #
    # Reports are the one exception, because waiting a whole session to act on
    # one defeats the point of having them.
    class Session
      attr_reader :viewer, :engine, :buckets

      def initialize(engine:, viewer:)
        @viewer  = viewer
        @depths  = engine.reachable_depths(viewer)
        @engine  = Engine.new(config: engine.config, store: snapshot(engine))
        @buckets = {}
        @reports = Hash.new { |h, k| h[k] = {} }
        @blocks  = config_thresholds
      end

      # Sorts the given users once. Anyone met later is sorted on first sight.
      def build(candidates)
        candidates.each { |pubkey| bucket_of(pubkey) }
        self
      end

      # Always against the walk taken at login, never a fresh one -- that is
      # what makes other people's config changes invisible until next time.
      def bucket_of(pubkey)
        @buckets[pubkey] ||= engine.bucket(viewer: viewer, target: pubkey, depths: @depths)
      end

      def trusted   = pubkeys_in(:trusted)
      def tolerated = pubkeys_in(:tolerated)
      def blocked   = pubkeys_in(:blocked)

      def visible?(pubkey) = bucket_of(pubkey) != :blocked

      # How far a rater sits from the viewer, or nil if outside the walk.
      def hops_to(pubkey) = @depths[pubkey]

      # Records a report seen during the session and blocks the subject if the
      # thresholds are met.
      #
      # The score is gone by now, so this cannot ask whether the report
      # outweighs what is already there -- it is a flat count of reporters at
      # each distance. That makes it stricter than the login-time maths, and a
      # subject blocked this way may well come back on the next login once the
      # report is weighed against everything else. That is expected.
      def report(subject:, reporter:)
        hops = reporter == viewer ? 0 : hops_to(reporter)
        return bucket_of(subject) if hops.nil?

        @reports[subject][reporter] = hops
        resort(subject)
      end

      # Undoes a report made this session and re-sorts the subject from the
      # snapshot, which still holds the rating from before the report. An
      # accidental click should not be irreversible until the next login.
      def unreport(subject:, reporter:)
        reporters = @reports[subject]
        reporters.delete(reporter)
        @reports.delete(subject) if reporters.empty?

        resort(subject)
      end

      def reporters_of(subject) = @reports[subject].dup

      def blocked_by_reports?(subject)
        counts = @reports[subject].values.tally

        @blocks.any? { |hops, needed| counts.fetch(hops, 0) >= needed }
      end

      # Itemised score for the "recalculate" view: who contributed what.
      # Deliberately re-derived rather than cached, since the session discards
      # scores by design.
      def explain(target)
        engine.breakdown(viewer: viewer, target: target, depths: @depths)
              .merge(bucket: bucket_of(target), reporters: reporters_of(target))
      end

      private

      # Re-sorts one person from the snapshot, then re-applies the report
      # thresholds. Both report and unreport go through here so that removing
      # one report cannot clear somebody else's.
      def resort(subject)
        @buckets.delete(subject)
        bucket_of(subject)
        @buckets[subject] = :blocked if blocked_by_reports?(subject)

        @buckets[subject]
      end

      # Copies the ratings the walk reached, so the session reads a fixed
      # graph. Freezing only the walk is not enough -- a new rating published
      # by someone already in it would still leak through. Bounded by
      # ladder.max_accounts, since that is what bounded the walk.
      def snapshot(source)
        frozen = Store::Memory.new
        @depths.each_key do |rater|
          source.store.ratings_by(rater).each { |subject, rating| frozen.put(rater, subject, rating) }
        end
        frozen
      end

      def pubkeys_in(bucket) = @buckets.select { |_, b| b == bucket }.keys

      def config_thresholds
        raw = engine.config.fetch("session.report_blocks")
        raw.to_h { |hops, needed| [Integer(hops), Integer(needed)] }
      end
    end
  end
end
