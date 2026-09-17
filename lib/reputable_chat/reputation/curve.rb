# frozen_string_literal: true

require "bigdecimal"

module ReputableChat
  module Reputation
    # Maps a net emote count to a rating contribution.
    #
    #   value(x) = sign(x) * min(cap, A*x^2 + B*|x|)
    #
    # Quadratic so that the first few emotes are nearly weightless and later
    # ones bite progressively harder. The sign is applied to the magnitude
    # rather than fed through the polynomial -- A*x^2 is positive for negative
    # x, so plugging a negative count straight in would make dislikes read as
    # likes.
    class Curve
      ZERO = BigDecimal("0")

      attr_reader :cap, :a, :b, :scale

      def initialize(config)
        @cap   = config.decimal("vote_curve.cap")
        @a     = config.decimal("vote_curve.a")
        @b     = config.decimal("vote_curve.b")
        @scale = config.scale
        @shape = config.fetch("vote_curve.shape").to_s
        @cache = {}

        return if @shape == "quadratic"

        raise ArgumentError, "unsupported vote_curve.shape: #{@shape.inspect}"
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
