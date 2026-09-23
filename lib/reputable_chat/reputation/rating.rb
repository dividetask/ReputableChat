# frozen_string_literal: true

require "bigdecimal"
require_relative "decimals"

module ReputableChat
  module Reputation
    # One rater's published opinion of one target.
    #
    # This is what actually travels between users. The published form carries
    # the ACTIONS, not a computed score, so that retuning the curve does not
    # strand every signed config in the network behind a stale number -- each
    # reader applies their own config to everyone else's raw counts.
    Rating = Struct.new(:friend, :reported, :net_votes, :cleared, keyword_init: true) do

      def self.from_h(hash)
        new(
          friend:    !!hash["friend"],
          reported:  !!hash["reported"],
          net_votes: Integer(hash["net_votes"] || 0),
          cleared:   !!hash["cleared"]
        )
      end

      def to_h
        { "friend" => !!friend, "reported" => !!reported,
          "net_votes" => net_votes.to_i, "cleared" => !!cleared }
      end

      # Precedence: report, then friend, then cleared, then accumulated votes.
      #
      # A report is absolute WITHIN this rater: it overrides however many of the
      # target's comments this rater liked. Across raters it is only -1 in the
      # mean, so roughly three friendships at the same depth outvote it.
      #
      # `cleared` pins someone to zero no matter how many times they have been
      # emoted or replied to, before or after. Friending is a deliberate act and
      # outranks it, which is why the UI does not offer to clear a friend.
      def value(curve:, friend_value:)
        return NEGATIVE if reported
        return friend_value + curve.value(net_votes.to_i) if friend
        return ZERO if cleared

        curve.value(net_votes.to_i).clamp(NEGATIVE, ONE)
      end
    end
  end
end
