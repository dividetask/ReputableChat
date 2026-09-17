# frozen_string_literal: true

require "bigdecimal"

module ReputableChat
  module Reputation
    # Depth weights: weight(d) = (1 - k) * k**d
    #
    # These sum to 1, so an effective reputation stays inside -1..1 with no
    # clamping. Depth 0 takes 1-k, which makes the ceiling for anyone you have
    # never personally rated exactly k.
    class Ladder
      ONE = BigDecimal("1")

      attr_reader :k, :max_hops, :max_configs, :scale

      def initialize(config)
        @k           = config.decimal("constants.k")
        @max_hops    = config.integer("ladder.max_hops")
        @max_configs = config.integer("ladder.max_configs")
        @scale       = config.scale
        @weights     = (0..@max_hops).map { |d| ((ONE - @k) * (@k**d)).round(@scale) }.freeze
      end

      def weight(depth)
        @weights.fetch(depth)
      end

      # The most any stranger can reach: the hops past 0 sum to k.
      def stranger_ceiling
        @weights[1..].sum(BigDecimal("0"))
      end
    end
  end
end
