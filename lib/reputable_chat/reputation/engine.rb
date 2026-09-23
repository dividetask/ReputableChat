# frozen_string_literal: true

require "bigdecimal"
require_relative "curve"
require_relative "ladder"
require_relative "rating"
require_relative "score"

module ReputableChat
  module Reputation
    # One viewer's subjective reputation for other users. Nothing here needs to
    # agree with another client. BigDecimal is used because the Blocked line is
    # `effective > 0`, and float values that should cancel to zero land on
    # +/-1e-17 and flip people across it.
    class Engine
      ZERO = BigDecimal("0")
      ONE  = BigDecimal("1")

      attr_reader :config, :store, :curve, :ladder

      def initialize(config:, store:)
        @config        = config
        @store         = store
        @curve         = Curve.new(config)
        @ladder        = Ladder.new(config)
        @friend_value  = config.decimal("actions.friend.value")
        @min_rating    = config.decimal("gate.min_rating")
        @visible_above = config.decimal("display.visible_above")
        @trusted_at    = config.decimal("display.trusted_at")
        @show_unrated  = config.fetch("display.show_unrated") ? true : false
        @scale         = config.scale
      end

      # Effective reputation of `target` from `viewer`'s point of view.
      #
      # `depths` lets a caller supply a walk taken earlier. A Session passes
      # the one it took at login so that attestations published since stay
      # invisible until the next login.
      def effective(viewer:, target:, depths: nil)
        breakdown(viewer: viewer, target: target, depths: depths).fetch(:effective)
      end

      # The same sum, itemised: which hop, who rated, what each contributed.
      # `effective` is defined in terms of this so the number the UI explains
      # cannot drift from the number it acts on.
      def breakdown(viewer:, target:, depths: nil)
        return { effective: ZERO, levels: [] } if viewer == target

        depths ||= reachable_depths(viewer)
        # Passed down rather than memoized on the engine: one engine answers
        # for whatever viewer it is asked about, and a cache that did not know
        # that would hand one person's trust to another.
        trust = trust_to(viewer, depths)
        levels = []
        total  = ZERO

        (0..ladder.max_hops).each do |depth|
          raters = raters_at(depths, depth, target, trust)
          next if raters.empty?

          mean         = raters.sum(ZERO) { |r| r.fetch(:rating) } / BigDecimal(raters.size)
          weight       = ladder.weight(depth)
          contribution = weight * mean
          total       += contribution

          levels << { hops: depth, weight: weight, raters: raters,
                      mean: mean, contribution: contribution }
        end

        { effective: total.round(@scale), levels: levels }
      end

      # Which of the three session lists this user belongs on.
      def bucket(viewer:, target:, depths: nil)
        depths ||= reachable_depths(viewer)

        classify(effective(viewer: viewer, target: target, depths: depths),
                 rated: rated?(target, depths))
      end

      # :trusted | :tolerated | :blocked
      #
      # Blocked at or below zero. That covers the unrated (who sit at exactly
      # zero) and anyone the network is net-negative on, and it is what stops a
      # distant report from making someone MORE visible than staying unrated
      # would. `show_unrated` lets a user opt into seeing the unrated anyway;
      # it does not let anyone see the net-negative.
      def classify(effective, rated: true)
        return :tolerated if !rated && @show_unrated && effective.zero?
        return :blocked   unless effective > @visible_above
        return :tolerated if effective < @trusted_at

        :trusted
      end

      # Breadth-first walk out from the viewer, gated at every hop.
      #
      # Reaching a hop means every link on the path was rated above the gate by
      # the person one step closer in. Each person is counted once, at their
      # shortest distance. The walk also stops once max_accounts have been
      # discovered, whichever limit is hit first -- a positive-only graph still
      # How much each person's recommendations are worth, compounded along the
      # path that reached them. The viewer trusts their own judgement fully; a
      # nought prunes, which is why it never appears here.
      def trust_to(viewer, depths)
        trust = { viewer => ONE }

        depths.sort_by { |_, depth| depth }.each do |rater, _|
          carried = trust.fetch(rater, ONE)
          store.ratings_by(rater).each do |subject, rating|
            next if trust.key?(subject)

            trust[subject] = carried * multiplier_of(rating)
          end
        end

        trust
      end

      # branches, so seven hops is unbounded in practice.
      def reachable_depths(viewer)
        depths   = { viewer => 0 }
        frontier = [viewer]
        budget   = ladder.max_accounts

        (0...ladder.max_hops).each do |depth|
          next_frontier = []

          frontier.each do |rater|
            store.ratings_by(rater).each do |subject, rating|
              return depths if depths.size >= budget

              next if depths.key?(subject)
              next unless positive?(rating)

              depths[subject] = depth + 1
              next_frontier << subject
            end
          end

          break if next_frontier.empty?

          frontier = next_frontier
        end

        depths
      end

      private

      def rated?(target, depths)
        depths.any? { |rater, _| rater != target && store.rating(rater, target) }
      end

      # The people who actually rated the target at this depth. The mean is
      # taken over these, not over everyone at this depth with non-raters
      # counted as zero.
      def raters_at(depths, depth, target, trust = {})
        depths.filter_map do |rater, rater_depth|
          next unless rater_depth == depth
          next if rater == target

          rating = store.rating(rater, target)
          next unless rating

          # What a rater says is worth what the path to them is worth. The
          # multiplier compounds, so a nought anywhere makes everything past it
          # count for nothing and a negative inverts what they recommend.
          weight = trust.fetch(rater, ONE)
          { pubkey: rater, rating: value_of(rating) * weight, reported: rating.reported }
        end
      end

      def value_of(rating)
        rating.value(curve: curve, friend_value: @friend_value)
      end

      # A Rating has no multiplier of its own -- it is what an author works
      # from, not what they publish -- so it carries the default.
      def multiplier_of(rating)
        return rating.multiplier if rating.respond_to?(:multiplier)

        value_of(rating) > ZERO ? ONE : ZERO
      end

      def positive?(rating)
        value_of(rating) > @min_rating
      end
    end
  end
end
