# frozen_string_literal: true

require "monitor"
require_relative "record"
require_relative "rules"

module Agnostic
  # The one way a record gets onto this server, whoever sent it: a client, a
  # peer, or the server itself. A record is accepted only when it is valid
  # under the rules, held when something it acknowledges has not arrived yet,
  # and refused otherwise.
  #
  # Every check and insert happens under one lock. Two records are often valid
  # alone and not together -- two heartbeats from one author, two spends of one
  # output -- so a check is only good until the next insert.
  class Ingest
    Result = Struct.new(:status, :hash, :problems, :missing, keyword_init: true) do
      def to_h = { "status" => status.to_s, "hash" => hash, "problems" => problems, "missing" => missing }.compact
    end

    attr_reader :store, :rules

    def initialize(store:, rules:, settings:, clock: -> { Time.now.to_i })
      @store = store
      @rules = rules
      @settings = settings
      @clock = clock
      @lock = Monitor.new
      @listeners = []
    end

    # Called with each record accepted, and where it came from.
    def on_accept(&block) = @listeners << block

    def submit(record, source: nil)
      @lock.synchronize do
        result = admit(record, source)
        result.status == :accepted ? result.tap { cascade(record) } : result
      end
    end

    # Drops held records that have waited too long for their ancestors.
    def expire
      @lock.synchronize { store.expire_pending(@clock.call - @settings.integer("pending", "max_age_seconds")) }
    end

    private

    def admit(record, source)
      return refused(nil, ["a record is a payload string and a signature string"]) unless record.digest
      return Result.new(status: :known, hash: record.digest) if store.known?(record.digest)

      early = too_far_ahead(record)
      return refused(record.digest, [early]) if early

      verdict = rules.check(record)
      return refused(record.digest, verdict.problems) unless verdict.problems.empty?
      return hold(record, verdict.missing, source) unless verdict.missing.empty?

      store.insert(record)
      store.release(record.digest)
      @listeners.each { |listener| listener.call(record, source) }
      Result.new(status: :accepted, hash: record.digest)
    end

    # Guideline, section 10: servers refuse records whose ts is far from their
    # own clock. Checked toward the future only -- a record legitimately
    # arrives long after it was signed when a server catches up with a peer.
    def too_far_ahead(record)
      ts = record.fields["ts"]
      return unless ts.is_a?(Integer)

      ahead = ts - @clock.call
      limit = @settings.integer("records", "max_future_seconds")
      "ts is #{ahead} seconds ahead of this server's clock, over the #{limit} allowed" if ahead > limit
    rescue Canonical::NotCanonical
      nil
    end

    def hold(record, missing, source)
      unless store.pending?(record.digest) || store.pending_count < @settings.integer("pending", "max_records")
        return refused(record.digest, ["this server is holding as many records as it will for missing ancestors"])
      end

      store.hold(record, missing: missing, source: source, at: @clock.call)
      Result.new(status: :pending, hash: record.digest, missing: missing)
    end

    # Records held for this one, and anything held for them in turn.
    def cascade(record)
      queue = [record.digest]
      until queue.empty?
        arrived = queue.shift
        store.waiting_for(arrived).each do |row|
          waiting = Record.new(payload: row[:payload], signature: row[:signature])
          result = admit(waiting, row[:source])
          store.release(waiting.digest) if result.status == :refused
          queue << waiting.digest if result.status == :accepted
        end
      end
    end

    def refused(hash, problems) = Result.new(status: :refused, hash: hash, problems: problems)
  end
end
