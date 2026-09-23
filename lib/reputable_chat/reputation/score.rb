# frozen_string_literal: true

require "bigdecimal"
require_relative "decimals"

module ReputableChat
  module Reputation
    # One rater's published opinion of one target, as it travels between users.
    #
    # An attestation carries scores rather than actions: the curve runs once, in
    # the author's client, and readers take the number. `Rating` is the other
    # half of that -- what an author works from to produce one of these.
    #
    # It answers the same two questions a Rating does, so the engine reads
    # either without knowing which it has.
    Score = Struct.new(:reputation, :trust, keyword_init: true) do

      def self.from_h(hash)
        new(
          reputation: BigDecimal(hash["reputation"].to_s),
          trust:      hash.key?("trust") ? BigDecimal(hash["trust"].to_s) : nil
        )
      end

      def to_h
        { "reputation" => reputation.to_s("F"), "trust" => multiplier.to_s("F") }
      end

      # The curve already ran in whoever published this, so there is nothing
      # left to compute. The keywords are accepted and ignored so that a Rating
      # and a Score are interchangeable at the point the engine reads them.
      def value(curve: nil, friend_value: nil) = reputation.clamp(NEGATIVE, ONE)

      # A report is the only thing that reaches exactly -1, so a published score
      # of -1 is a report. Actions are private now; this is what survives of
      # them, and it is enough for the mid-session report thresholds.
      def reported = reputation <= NEGATIVE

      # Defaulted rather than stored for everyone: 1 for anyone positive, 0 for
      # anyone blocked. An attestation only needs an entry where somebody has
      # overridden it.
      def multiplier
        return trust if trust

        reputation > ZERO ? ONE : ZERO
      end
    end
  end
end
