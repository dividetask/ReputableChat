# frozen_string_literal: true

require "set"
require_relative "record"

module Agnostic
  # A record's history -- everything its acks reach -- answered without
  # listing it, so a check costs what is new since the last heartbeats, not
  # the whole chain.
  #
  # Walking back from the acks, the walk stops at each heartbeat it meets.
  # Everything behind a heartbeat is already in the store's generations: an
  # account's heartbeat g brought generation g into its history, and its
  # history holds the account's previous heartbeat, so the records with a
  # generation of g or less under that account are exactly that heartbeat's
  # history and the heartbeat itself. That holds while the account has one
  # heartbeat for each beat index up to g. Behind a heartbeat of an account
  # that has forked -- two heartbeats sharing an index at or below its own --
  # the history is listed in full instead, as it always was.
  class History
    attr_reader :store, :seeds

    # seeds: the acks of the record whose history this is.
    def initialize(histories, seeds)
      @histories = histories
      @store = histories.store
      @seeds = seeds.select { |h| Record.hash?(h) }.uniq
      walk
    end

    def include?(hash) = among([hash]).include?(hash)

    # Which of these hashes are in this history, as a Set.
    def among(hashes)
      found = Set.new
      rest = []
      hashes.uniq.each { |h| @members.include?(h) ? found << h : rest << h }
      unless rest.empty? || @behind.empty?
        rest.each_slice(500) do |slice|
          store.db[:generations].where(record: slice, account: @behind.keys)
               .select_map(%i[record account generation])
               .each { |record, account, generation| found << record if generation <= @behind[account] }
        end
        rest.reject! { |h| found.include?(h) }
      end
      rest.each { |h| found << h if forked_part.include?(h) } unless @forked.empty?
      found
    end

    # The highest beat index of the account's heartbeats in this history, or
    # nil. Below the account's first fork, holding beat j means holding every
    # beat before it, so a binary search finds the newest.
    def newest_beat(account)
      (@newest ||= {})[account] ||= [newest_linear(account), newest_forked(account)].compact.max || :none
      @newest[account] == :none ? nil : @newest[account]
    end

    # The history listed in full: only for an account that has forked.
    def to_set = @to_set ||= store.closure(@seeds)

    private

    def walk
      @members = Set.new
      @behind = {}   # account => highest beat index met, below its first fork
      @forked = []   # heartbeats met past their account's first fork
      frontier = @seeds
      until frontier.empty?
        rows = frontier.each_slice(500).flat_map do |slice|
          store.db[:records].where(hash: slice).select_map(%i[hash kind account beat_index])
        end
        known = rows.to_set(&:first)
        frontier.each { |h| @members << h unless known.include?(h) } # not stored: a closure holds it all the same
        expand = []
        rows.each do |hash, kind, account, beat_index|
          @members << hash
          next expand << hash unless kind == "heartbeat"

          if beat_index < @histories.first_fork(account)
            @behind[account] = [@behind[account] || 0, beat_index].max
          else
            @forked << hash
          end
        end
        parents = expand.each_slice(500).flat_map { |slice| store.db[:acks].where(child: slice).select_map(:parent) }
        frontier = parents.uniq.reject { |h| @members.include?(h) }
      end
    end

    def forked_part = @forked_part ||= store.closure(@forked)

    def newest_linear(account)
      low = 0
      high = [@histories.first_fork(account) - 1, store.latest_beat_index(account)].min
      while low < high
        mid = (low + high + 1) / 2
        beat = store.beat_at(account, mid)
        beat && include?(beat) ? low = mid : high = mid - 1
      end
      low.zero? ? nil : low
    end

    def newest_forked(account)
      fork = @histories.first_fork(account)
      return if fork == Float::INFINITY

      beats = store.beats_from(account, fork)
      among(beats.map(&:first)).then { |held| beats.select { |h, _| held.include?(h) }.map(&:last).max }
    end
  end
end
