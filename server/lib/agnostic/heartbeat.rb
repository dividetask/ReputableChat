# frozen_string_literal: true

require_relative "canonical"
require_relative "rules"

module Agnostic
  # This server's heartbeats (section 10): records that acknowledge as much of
  # the frontier as fits, so that branches rejoin.
  #
  # For now a heartbeat acknowledges every record this server holds that
  # nothing else acknowledges yet, whoever wrote it. The server computes no
  # reputation, so it has no basis to leave anything out; a later version may.
  class Heartbeat
    def initialize(store:, ingest:, host:, settings:, clock: -> { Time.now.to_i })
      @store = store
      @ingest = ingest
      @host = host
      @settings = settings
      @clock = clock
    end

    def interval = @settings.integer("heartbeat", "interval_seconds")

    def previous = @store.by_account(@host.id, kind: "heartbeat").max_by(&:beat_index)

    def seconds_until_due(now = @clock.call)
      last = previous
      last ? last.ts + interval - now : 0
    end

    def due?(now = @clock.call)
      last = previous
      last.nil? || now - last.ts >= interval
    end

    # Publishes a heartbeat if one is due. Returns the Ingest result, or nil.
    def beat(now = @clock.call)
      return unless due?(now)

      last = previous
      required = last ? [last.digest] : []
      record = build(required, candidates(required), now)
      result = @ingest.submit(record)
      result.status == :accepted ? result : retry_without_splits(required, now, result)
    end

    private

    # Records of this rules version that nothing acknowledges. A release is of
    # the next version, so a heartbeat may not name it.
    def candidates(required)
      @store.frontier.select { |r| r.version == Rules::VERSION }.map(&:digest) - required
    end

    # As many as fit in the ack limit, the oldest first so nothing waits
    # forever behind newer records.
    def build(required, candidates, now)
      ack = required.dup
      bytes = Canonical.dump(ack).bytesize
      candidates.each do |hash|
        added = hash.bytesize + 3 # quotes and a comma
        break if bytes + added > Rules::HEARTBEAT_ACK_BYTES

        ack << hash
        bytes += added
      end
      @host.sign("heartbeat", { "ack" => ack.sort, "body" => "", "ts" => now })
    end

    # A heartbeat whose history would hold both sides of a split is invalid
    # (section 10). Leave out one side: the orphaned record and whatever holds
    # it -- unless this server's own chain holds it, in which case this server
    # is on that side and leaves out the heartbeat that orphaned it instead.
    def retry_without_splits(required, now, failed)
      own = @store.closure(required + [@host.id])
      kept = candidates(required)
      result = failed
      while (pair = split_pair(result))
        orphan, orphaner = pair
        drop = own.include?(orphan) ? orphaner : orphan
        kept = kept.reject { |hash| @store.closure([hash]).include?(drop) }
        result = @ingest.submit(build(required, kept, now))
      end
      result
    end

    def split_pair(result)
      return unless result.status == :refused

      result.problems.to_a.each do |p|
        return [Regexp.last_match(1), Regexp.last_match(2)] if p =~ /holds ([0-9a-f]{64}) and ([0-9a-f]{64}), a heartbeat/
      end
      nil
    end
  end
end
