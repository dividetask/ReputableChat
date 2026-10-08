# frozen_string_literal: true

require_relative "formats"
require_relative "record"
require_relative "settings"
require_relative "store"

module Agnostic
  # The operator's local commands for this server's ratings (rake rate, unrate,
  # ratings). They write to the store directly, so only someone on the machine
  # can use them; the server publishes the change in its next attestation.
  class ManualRatings
    def self.open(settings: Settings.load) = new(Store.new(settings.database_url))

    def initialize(store, clock: -> { Time.now.to_i })
      @store = store
      @clock = clock
    end

    def set(account, reputation, trust)
      raise ArgumentError, "#{account.inspect} is not an account ID" unless Record.hash?(account)

      [["reputation", reputation], ["trust", trust]].each do |name, value|
        unless Formats.decimal?(value) && Formats.decimal(value).abs <= 1
          raise ArgumentError, "#{name} #{value.inspect} is not a decimal from -1 to 1, written as the rules spell one ('0.5', not '.5')"
        end
      end

      @store.override_rating(account, reputation: reputation, trust: trust, at: @clock.call)
      "#{account} rated #{reputation}, trust #{trust}, by hand; published after the next heartbeat"
    end

    def clear(account)
      removed = @store.clear_rating_override(account.to_s)
      return "#{account} had no rating set by hand" if removed.zero?

      "#{account}'s rating by hand removed; reachability decides it again from the next heartbeat"
    end

    def list
      overrides = @store.rating_overrides.to_h { |o| [o[:account], o] }
      published = @store.published_ratings.to_h { |p| [p[:account], p] }
      (overrides.keys | published.keys).sort.map do |account|
        o = overrides[account]
        p = published[account]
        set = o ? "by hand #{o[:reputation]} (trust #{o[:trust]})" : "by reachability"
        out = p ? "published #{p[:reputation]} (trust #{p[:trust]})" : "not yet published"
        "#{account}  #{set}, #{out}"
      end
    end
  end
end
