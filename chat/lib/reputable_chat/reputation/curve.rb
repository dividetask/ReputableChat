# frozen_string_literal: true

require "bigdecimal"

module ReputableChat
  module Reputation
    # Maps a net emote count to a rating: sign(x) * min(cap, A*x^2 + B*|x|).
    #
    # Quadratic so the first few emotes are nearly weightless and later ones
    # bite progressively harder. The sign is applied to the magnitude rather
    # than fed through the polynomial -- A*x^2 is positive for negative x, so a
    # negative count would otherwise read as a positive one.
    class Curve
      ZERO = BigDecimal("0")

      attr_reader :cap, :a, :b, :scale

      def initialize(config)
        @cap   = config.decimal("vote_curve.cap")
        @a     = config.decimal("vote_curve.a")
        @b     = config.decimal("vote_curve.b")
        @scale = config.scale
        @cache = {}
      end

      def value(net_votes)
        net = Integer(net_votes)
        return ZERO if net.zero?

        magnitude = @cache[net.abs] ||= magnitude_for(net.abs)
        net.negative? ? -magnitude : magnitude
      end

      # Net vote count at which the cap is first reached. Useful for docs and
      # for sanity-checking a retune.
      def saturation_point
        (1..10_000).find { |x| magnitude_for(x) >= cap }
      end

      private

      def magnitude_for(abs_net)
        x = BigDecimal(abs_net)
        raw = (a * x * x) + (b * x)
        raw = ZERO if raw.negative?
        raw > cap ? cap : raw.round(scale)
      end
    end
  end
end
