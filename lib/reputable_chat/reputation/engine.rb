# frozen_string_literal: true

require "bigdecimal"
require_relative "curve"
require_relative "ladder"
require_relative "rating"

module ReputableChat
  module Reputation
    # Computes one viewer's subjective reputation for other users.
    #
    # Nothing here needs to agree with what another client computes. Each
    # viewer's number is their own view of the network, built from other
    # people's published ratings; two clients differing in the last decimal
    # place just means two slightly different subjective views, which is the
    # point. BigDecimal is used not for cross-client agreement but because
    # visibility is decided by `effective > 0`, and in binary floating point
    # values that should cancel to exactly zero land on +/-1e-17 instead and
    # flip people across that line at random.
    class Engine
      ZERO = BigDecimal("0")

      attr_reader :config, :store, :curve, :ladder

      def initialize(config:, store:)
        @config       = config
        @store        = store
        @curve        = Curve.new(config)
        @ladder       = Ladder.new(config)
        @friend_value = config.decimal("actions.friend.value")
        @grey_below   = config.decimal("display.grey_if_below")
        @scale        = config.scale
      end

      # Effective reputation of `target` from `viewer`'s point of view.
      def effective(viewer:, target:)
        return ZERO if viewer == target

        depths = reachable_depths(viewer)
        total  = ZERO

        (0..ladder.max_depth).each do |depth|
          values = ratings_at(depths, depth, target)
          next if values.empty?

          mean = values.sum(ZERO) / BigDecimal(values.size)
          total += ladder.weight(depth) * mean
        end

        total.round(@scale)
      end

      # :hidden | :grey | :normal
      def visibility(viewer:, target:)
        classify(effective(viewer: viewer, target: target))
      end

      def classify(effective)
        return :hidden unless effective.positive?
        return :grey   if effective < @grey_below

        :normal
      end

      # Breadth-first walk out from the viewer, gated at every hop.
      #
      # Reaching depth d means every link on the path was rated above zero by
      # the person one step closer in -- a single non-positive link and the
      # whole branch beyond it goes unread. Each person is counted once, at
      # their shortest distance, so someone reachable by two paths does not get
      # to vote twice.
      def reachable_depths(viewer)
        depths   = { viewer => 0 }
        frontier = [viewer]

        (0...ladder.max_depth).each do |depth|
          next_frontier = []

          frontier.each do |rater|
            store.ratings_by(rater).each do |subject, rating|
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

      # Mean is taken over the people who actually rated the target at this
      # depth, not over everyone at this depth with non-raters counted as zero.
      def ratings_at(depths, depth, target)
        depths.filter_map do |rater, rater_depth|
          next unless rater_depth == depth
          next if rater == target

          rating = store.rating(rater, target)
          rating && value_of(rating)
        end
      end

      def value_of(rating)
        rating.value(curve: curve, friend_value: @friend_value)
      end

      def positive?(rating)
        value_of(rating).positive?
      end
    end
  end
end
