# frozen_string_literal: true

require "set"
require_relative "history"

module Agnostic
  # Histories, memoized for the length of one check. A record's history never
  # changes once it is signed, so a cached one is never stale; the cache is
  # dropped with the check only to bound memory, and with it what it read of
  # the heartbeats' forks, which only a new heartbeat changes.
  class Histories
    def initialize(store)
      @store = store
      @cache = {}
      @forks = {}
    end

    attr_reader :store

    # The history of a stored record: everything its acks reach, itself excluded.
    def of(hash) = @cache[hash] ||= History.new(self, store.acks_of(hash))

    # The history of a record about to be checked, from its acks.
    def from(acks) = History.new(self, acks)

    def first_fork(account) = @forks.fetch(account) { @forks[account] = store.first_fork(account) }

    def ancestor?(a, b) = of(b).include?(a)

    def concurrent?(a, b) = a != b && !ancestor?(a, b) && !ancestor?(b, a)
  end

  # The chain as one record sees it: its history and nothing else. Every
  # question the rules ask "as seen by a record" is asked of one of these.
  class View
    attr_reader :store, :histories, :hashes, :genesis

    def initialize(store:, histories:, hashes:, genesis:)
      @store = store
      @histories = histories
      @hashes = hashes
      @genesis = genesis
      @memo = {}
    end

    def self.of(record, store:, histories:, genesis:)
      new(store: store, histories: histories, hashes: histories.from(record.ack), genesis: genesis)
    end

    # The view a stored record had when it was signed.
    def as_seen_by(hash)
      View.new(store: store, histories: histories, hashes: histories.of(hash), genesis: genesis)
    end

    def include?(hash) = hashes.include?(hash)

    def records_of(account, kind: nil, notice_kind: nil)
      memo(:records_of, account, kind, notice_kind) do
        within(store.by_account(account, kind: kind, notice_kind: notice_kind))
      end
    end

    def about(subject, notice_kind)
      memo(:about, subject, notice_kind) do
        within(store.by_subject(subject, notice_kind: notice_kind))
      end
    end

    def endorsers(hash) = within(store.endorsers(hash))

    def spenders(output, account) = within(store.spenders(output, account))

    # The highest beat index of the account's heartbeats in this view, or nil.
    def newest_beat(account)
      return hashes.newest_beat(account) if hashes.respond_to?(:newest_beat)

      records_of(account, kind: "heartbeat").map(&:beat_index).max
    end

    # Those of these records in this view, in their order.
    def within(records)
      return records.select { |r| include?(r.digest) } unless hashes.respond_to?(:among)

      held = hashes.among(records.map(&:digest))
      records.select { |r| held.include?(r.digest) }
    end

    def keys(account) = memo(:keys, account) { KeyState.new(self, account) }

    def deciding(hash, from)
      return from if from&.holds?(hash)

      record = memo(:record, hash) { store.fetch(hash) }
      record && disputes(record.subject || record.account)
    end

    def disputes(account) = memo(:disputes, account) { Disputes.new(self, account) }

    def disputed?(account) = disputes(account).any?

    # A record's fate, decided by the dispute of the account it belongs to,
    # or that a notice names. from: the Disputes asking, which answers for
    # its own account's records (a quorum being checked counts there).
    def void?(hash, from = nil) = deciding(hash, from)&.void?(hash) || false

    def record_disputed?(hash, from = nil) = deciding(hash, from)&.disputed?(hash) || false

    def adjudicators(account) = memo(:adjudicators, account) { Adjudicators.new(self, account).in_force }

    # As seen by a record: an identity declaration in its history issued this
    # account's currency.
    def currency?(account)
      records_of(account, kind: "identity").any? { |r| r.facts["issues"] }
    end

    private

    def memo(*key) = @memo.key?(key) ? @memo[key] : (@memo[key] = yield)
  end

  # An account's keys as a view sees them (section 2, working key; section 7).
  class KeyState
    FIELDS = { "key-change" => "pubkey", "master-key-change" => "mpubkey" }.freeze

    attr_reader :confirmed, :tentative

    # disputes: whose settlement to read; a quorum being checked passes the
    # one that counts it.
    def initialize(view, account, disputes: view.disputes(account))
      @view = view
      @first = view.store.fetch(account)
      @confirmed = { "pubkey" => @first&.[]("pubkey"), "mpubkey" => @first&.[]("mpubkey") }
      @tentative = { "pubkey" => [], "mpubkey" => [] }
      @changes = FIELDS.to_h { |kind, field| [field, view.records_of(account, kind: "notice", notice_kind: kind)] }
      settle(disputes)
    end

    # The account's last confirmed key of this kind, and every tentative
    # change's key, superseded ones included.
    def allowed(field) = ([confirmed[field]] + tentative[field].map { |c| c["body"] }).compact.uniq

    # The latest key of this kind: the newest tentative change's, or the last
    # confirmed one where nothing is tentative.
    def current(field)
      leaves = current_changes(field)
      leaves.empty? ? [confirmed[field]].compact : leaves.map { |c| c["body"] }.uniq
    end

    # The newest tentative changes of this kind, whose keys current returns.
    def current_changes(field)
      changes = tentative[field]
      changes.reject { |c| changes.any? { |o| o != c && @view.histories.ancestor?(c.digest, o.digest) } }
    end

    # The records that introduced this key: the first declaration that set
    # it, or the changes of this kind that moved to it. A record signed with
    # it relies on them (section 8).
    def introduced(field, key)
      from_first = @first && @first[field] == key ? [@first.digest] : []
      from_first + @changes[field].select { |c| c["body"] == key }.map(&:digest)
    end

    private

    # A confirmed change's key is the confirmed key of its kind. It and every
    # earlier change of that kind along its acks are obsolete: neither
    # tentative nor void, and no longer able to sign (section 7). Void
    # changes sign nothing.
    def settle(disputes)
      @changes.each do |field, changes|
        confirmed = changes.select { |c| disputes.confirmed?(c.digest) }
        newest = confirmed.reject { |c| confirmed.any? { |o| o != c && @view.histories.ancestor?(c.digest, o.digest) } }
        @confirmed[field] = newest.max_by(&:seq)["body"] unless newest.empty?
        @tentative[field] = changes.reject do |c|
          disputes.void?(c.digest) ||
            confirmed.any? { |o| o.digest == c.digest || @view.histories.ancestor?(c.digest, o.digest) }
        end
      end
    end
  end

  # What is disputed, confirmed and void among an account's records, as a
  # view sees them (section 8).
  #
  # Records conflict in pairs: two concurrent changes of the same key; a
  # record and the key change it contests; a compromised notice and each
  # record it names; two concurrent records each endorsing a different spend
  # of the same output of the account's own currency; and two concurrent
  # spends of one output, which the currency's issuer settles rather than a
  # quorum (section 11).
  #
  # A quorum confirms the records it names and every record of the account
  # they rely on, and nothing else. A record that conflicts with a confirmed
  # one is void, and so is a record that relies on a void one, of any
  # account. A record is disputed while it is in a conflict neither side of
  # which is settled, or while it relies on a disputed record, of any
  # account. The account is disputed while any of its records is.
  #
  # extra: a quorum not yet stored, counted as if it were -- what checking a
  # quorum needs, since whether it is valid turns on what it would settle.
  class Disputes
    attr_reader :confirmed

    def initialize(view, account, extra: nil)
      @view = view
      @account = account
      @records = view.records_of(account)
      @notices = view.about(account, "compromised")
      @relies = @records.to_h { |r| [r.digest, Array(r.facts["relies"])] }
      @pairs = contests + key_conflicts + notice_pairs + endorsement_conflicts
      @spends = spend_conflicts
      @confirmed = Set.new
      @void = {}
      @disputed = {}
      quorums = view.about(account, "quorum") + [extra].compact
      quorums.sort_by { |q| q.seq || Float::INFINITY }.each { |q| q.target.each { |h| confirm(h) if view.include?(h) } }
      issuer_choices
    end

    def confirmed?(hash) = @confirmed.include?(hash)

    # Void: it conflicts with a confirmed record, or relies on a void one.
    def void?(hash)
      return @void[hash] if @void.key?(hash)

      @void[hash] = (@lost&.include?(hash) || partners(hash).any? { |p| confirmed?(p.digest) && !confirmed?(hash) } ||
                     relies(hash).any? { |h| @view.void?(h, self) }) || false
    end

    def settled?(hash) = confirmed?(hash) || void?(hash)

    # Disputed: in a conflict neither side of which is settled, or relying
    # on a disputed record.
    def disputed?(hash)
      return @disputed[hash] if @disputed.key?(hash)

      @disputed[hash] = !settled?(hash) &&
                        (partners(hash).any? { |p| !settled?(p.digest) } || relies(hash).any? { |h| @view.record_disputed?(h, self) })
    end

    # The account's records and the notices about it.
    def all = @records + @notices

    def any? = all.any? { |r| disputed?(r.digest) }

    # The disputed records.
    def records = all.select { |r| disputed?(r.digest) }

    # One of two spends of an output that the issuer has not chosen between.
    def undecided_spend?(hash) = @spends.any? { |a, b| [a.digest, b.digest].include?(hash) && !confirmed?(a.digest) && !confirmed?(b.digest) }

    def conflict?(a, b) = (@pairs + @spends).any? { |x, y| [x.digest, y.digest].sort == [a, b].sort }

    # The records that conflict with this one.
    def conflicting_with(record) = partners(record.digest)

    # Whether this account's dispute decides the record: its own, or a notice
    # about it.
    def holds?(hash) = all.any? { |r| r.digest == hash }

    private

    def partners(hash)
      (@partners ||= (@pairs + @spends).each_with_object(Hash.new { |h, k| h[k] = [] }) do |(a, b), out|
        out[a.digest] << b
        out[b.digest] << a
      end)[hash].uniq(&:digest)
    end

    def relies(hash) = @relies.fetch(hash) { Array(@view.store.fetch(hash)&.facts&.[]("relies")) }

    def confirm(hash)
      stack = [hash]
      while (h = stack.pop)
        next unless @confirmed.add?(h)

        stack.concat(@relies.fetch(h, []).select { |r| @relies.key?(r) })
      end
    end

    # Section 11: the issuer confirms the spend it endorses, while its own
    # account is not disputed as the endorsing record sees it, and the
    # other spend is lost.
    def issuer_choices
      @lost = Set.new
      @spends.each do |a, b|
        chosen = [a, b].find { |s| chosen_by_issuer?(s) }
        next unless chosen

        @confirmed << chosen.digest
        @lost << (chosen == a ? b : a).digest
      end
    end

    def chosen_by_issuer?(spend)
      issuer = spend.transfer["currency"]
      @view.endorsers(spend.digest).any? { |e| e.account == issuer && !@view.as_seen_by(e.digest).disputed?(issuer) }
    end

    def contests
      @records.select { |r| r.facts["contests"] }.flat_map do |r|
        Array(r.facts["contests"]).filter_map { |h| h.is_a?(String) && (c = @view.store.fetch(h)) ? [r, c] : nil }
      end
    end

    def notice_pairs = @notices.flat_map { |n| @view.store.fetch_many(n.target).map { |t| [n, t] } }

    def key_conflicts
      KeyState::FIELDS.keys.flat_map do |kind|
        concurrent_pairs(@view.records_of(@account, kind: "notice", notice_kind: kind))
      end
    end

    def spend_conflicts
      spends = @records.select { |r| r.transfer&.key?("in") }
      by_output = spends.flat_map { |r| r.transfer["in"].map { |o| [o, r] } }.group_by(&:first)
      by_output.values.flat_map { |entries| concurrent_pairs(entries.map(&:last).uniq(&:digest)) }
    end

    # Each of two concurrent records endorses a different spend of the same
    # output of the account's own currency.
    def endorsement_conflicts
      choices = []
      @records.each do |r|
        r.endorse.each do |e|
          spend = @view.store.fetch(e)
          next unless spend&.transfer&.key?("in")

          spend.transfer["in"].each do |output|
            source = @view.store.fetch(output)
            choices << [output, spend.digest, r] if source && Currency.of(source) == @account
          end
        end
      end
      choices.group_by(&:first).values.flat_map do |entries|
        entries.combination(2).filter_map do |(_, s1, r1), (_, s2, r2)|
          next if s1 == s2 || r1.digest == r2.digest
          next unless @view.histories.concurrent?(r1.digest, r2.digest)

          [r1, r2]
        end
      end
    end

    def concurrent_pairs(records)
      records.combination(2).select { |a, b| @view.histories.concurrent?(a.digest, b.digest) }
    end
  end

  # The adjudicators in force for an account (section 3).
  class Adjudicators
    REQUIRED_RECORDS = 16

    def initialize(view, account)
      @view = view
      @account = account
    end

    def in_force
      first = @view.store.fetch(@account)
      list = normalize(first&.[]("adjudicators"))
      proposals = @view.records_of(@account, kind: "identity")
                       .reject(&:first_declaration?).select { |r| r.key?("adjudicators") }
      proposals.each do |proposal|
        proposed = normalize(proposal["adjudicators"])
        list = proposed if proposed != list && takes_effect?(proposal, list)
      end
      list
    end

    # An absent or empty list names the developer's account alone.
    def normalize(list) = list.is_a?(Array) && !list.empty? ? list : [@view.genesis]

    private

    def takes_effect?(proposal, list)
      majority = (list.size / 2) + 1
      endorsed = @view.endorsers(proposal.digest).map(&:account).uniq & list
      return true if endorsed.size >= majority
      return false if @view.disputed?(@account)

      later = @view.store.descendants(proposal.digest)
      published = list.count do |adjudicator|
        @view.records_of(adjudicator).count { |r| later.include?(r.digest) } >= REQUIRED_RECORDS
      end
      published >= majority
    end
  end

  # Section 11, the parts that more than one rule needs.
  module Currency
    module_function

    # The currency a record's transfer moves: named, or the author's own when
    # it issues.
    def of(record)
      transfer = record.transfer
      transfer && (transfer["currency"] || record.account)
    end

    def issues?(record)
      transfer = record.transfer
      transfer && !transfer.key?("currency") && !transfer.key?("in")
    end

    # What the record pays an account, as a BigDecimal, or nil.
    def output_to(record, account)
      entry = Array(record.transfer&.fetch("out", nil)).find { |o| o["to"] == account }
      entry && BigDecimal(entry["value"])
    end
  end
end
