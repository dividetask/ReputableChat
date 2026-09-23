# frozen_string_literal: true

require "digest"
require_relative "../cryptography/canonical"

module ReputableChat
  module Reputation
    # A hash of the parameters a score was computed under.
    #
    # An attestation publishes the author's own calculated scores as a cache.
    # Reputation is subjective and configuration is per-user, so those numbers
    # are only worth anything to a reader whose parameters match -- the author
    # may run a different k, a different curve, or show_unrated on. Without
    # this fingerprint a reader who used the cache would silently adopt a
    # stranger's settings, and a retune would make every published cache
    # quietly wrong instead of detectably stale.
    #
    # Must agree with public/js/fingerprint.js.
    module Fingerprint
      DOMAIN = "reputablechat:params:v1"

      # Every key that can change a computed score, and nothing else. Seed and
      # session keys are absent deliberately: they cannot move a number, so
      # including them would invalidate caches for no reason.
      SCORING_KEYS = %w[
        precision.scale
        constants.k
        ladder.max_hops
        ladder.max_accounts
        gate.min_rating
        actions.friend.value
        actions.report.value
        vote_curve.cap
        vote_curve.a
        vote_curve.b
        display.visible_above
        display.trusted_at
        display.show_unrated
      ].freeze

      module_function

      def of(config) = digest(values(config))

      def digest(values)
        Digest::SHA256.hexdigest("#{DOMAIN}\n#{Cryptography::Canonical.dump(values)}".b)
      end

      # Values are stringified so that a YAML "0.1" and a JSON 0.1 cannot
      # fingerprint differently for the same setting.
      def values(config)
        SCORING_KEYS.to_h { |key| [key, config.fetch(key).to_s] }
      end
    end
  end
end
