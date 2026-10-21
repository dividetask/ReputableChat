# frozen_string_literal: true

require "monitor"

module Agnostic
  # At most so many requests per caller in any minute. Kept in memory: a
  # restart forgives everyone, which costs nothing worth keeping.
  class RateLimit
    WINDOW = 60

    def initialize(per_minute:, clock: -> { Time.now.to_i })
      @per_minute = per_minute
      @clock = clock
      @seen = Hash.new { |h, k| h[k] = [] }
      @lock = Monitor.new
    end

    # Seconds to wait before asking again, or nil when the request may go.
    def wait(caller)
      @lock.synchronize do
        now = @clock.call
        times = @seen[caller]
        times.shift while times.any? && times.first <= now - WINDOW
        return times.first + WINDOW - now if times.size >= @per_minute

        times << now
        nil
      end
    end
  end
end
