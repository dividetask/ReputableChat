# frozen_string_literal: true

require "set"

module Agnostic
  # Histories, memoized for the length of one check. A record's history never
  # changes once it is signed, so a cached one is never stale; the cache is
  # dropped with the check only to bound memory.
  class Histories
    def initialize(store)
      @store = store
      @cache = {}
    end

    attr_reader :store

    # The history of a stored record: everything its acks reach, itself excluded.
    def of(hash) = @cache[hash] ||= store.closure([hash]).tap { |set| set.delete(hash) }

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
      new(store: store, histories: histories, hashes: store.closure(record.ack), genesis: genesis)
    end

    # The view a stored record had when it was signed.
    def as_seen_by(hash)
      View.new(store: store, histories: histories, hashes: histories.of(hash), genesis: genesis)
    end

    def include?(hash) = hashes.include?(hash)

    def records_of(account, kind: nil, notice_kind: nil)
      memo(:records_of, account, kind, notice_kind) do
        store.by_account(account, kind: kind, notice_kind: notice_kind).select { |r| include?(r.digest) }
      end
    end

    def about(subject, notice_kind)
      memo(:about, subject, notice_kind) do
        store.by_subject(subject, notice_kind: notice_kind).select { |r| include?(r.digest) }
      end
    end

    def endorsers(hash) = store.endorsers(hash).select { |r| include?(r.digest) }

    def spenders(output, account) = store.spenders(output, account).select { |r| include?(r.digest) }

    def keys(account) = memo(:keys, account) { KeyState.new(self, account) }

    def disputes(account) = memo(:disputes, account) { Disputes.new(self, account) }

    def disputed?(account) = disputes(account).unsettled.any?

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

    attr_reader :confirmed, :tentative, :voided

    def initialize(view, account)
      @view = view
      first = view.store.fetch(account)
      @confirmed = { "pubkey" => first&.[]("pubkey"), "mpubkey" => first&.[]("mpubkey") }
      @tentative = { "pubkey" => [], "mpubkey" => [] }
      @voided = Set.new
      replay(account)
    end

    # The account's last confirmed key of this kind, and every tentative
    # change's key, superseded ones included.
    def allowed(field) = ([confirmed[field]] + tentative[field].map { |c| c["body"] }).compact.uniq

    # The latest key of this kind: the newest tentative change's, or the last
    # confirmed one where nothing is tentative.
    def current(field)
      changes = tentative[field]
      leaves = changes.reject { |c| changes.any? { |o| o != c && @view.histories.ancestor?(c.digest, o.digest) } }
      leaves.empty? ? [confirmed[field]].compact : leaves.map { |c| c["body"] }.uniq
    end

    def void?(hash) = voided.include?(hash)

    private

    def replay(account)
      changes = FIELDS.keys.flat_map { |kind| @view.records_of(account, kind: "notice", notice_kind: kind) }
      quorums = @view.about(account, "quorum")
      (changes + quorums).sort_by(&:seq).each do |record|
        field = FIELDS[record.notice_kind]
        next @tentative[field] << record if field

        confirm(record)
      end
    end

    # A quorum naming a key change confirms it, and voids every other change of
    # the same kind that was tentative when the quorum was signed.
    def confirm(quorum)
      named = @view.store.fetch(quorum.target.first)
      field = named && FIELDS[named.notice_kind]
      return unless field

      seen = @view.histories.of(quorum.digest)
      @confirmed[field] = named["body"]
      @tentative[field].each { |c| @voided << c.digest if c.digest != named.digest && seen.include?(c.digest) }
      @tentative[field] = @tentative[field].reject { |c| c.digest == named.digest || @voided.include?(c.digest) }
    end
  end

  # What disputes an account (section 8), and which of those no later quorum
  # has settled.
  class Disputes
    Cause = Struct.new(:reason, :records)

    attr_reader :causes, :unsettled

    def initialize(view, account)
      @view = view
      @account = account
      @causes = compromised + contests + key_conflicts + spend_conflicts + endorsement_conflicts
      quorums = view.about(account, "quorum")
      @unsettled = @causes.reject do |cause|
        quorums.any? { |q| cause.records.all? { |r| view.histories.of(q.digest).include?(r.digest) } }
      end
    end

    def records = unsettled.flat_map(&:records).uniq(&:digest)

    # The records that conflict with this one, in any cause.
    def conflicting_with(record)
      causes.select { |c| c.reason == :conflict && c.records.any? { |r| r.digest == record.digest } }
            .flat_map(&:records).reject { |r| r.digest == record.digest }.uniq(&:digest)
    end

    private

    def compromised = @view.about(@account, "compromised").map { |n| Cause.new(:compromised, [n]) }

    def contests
      @view.records_of(@account).select { |r| r.facts["contests"] }.map { |r| Cause.new(:contest, [r]) }
    end

    def key_conflicts
      KeyState::FIELDS.keys.flat_map do |kind|
        pairs(@view.records_of(@account, kind: "notice", notice_kind: kind))
      end
    end

    def spend_conflicts
      spends = @view.records_of(@account).select { |r| r.transfer&.key?("in") }
      by_output = spends.flat_map { |r| r.transfer["in"].map { |o| [o, r] } }.group_by(&:first)
      by_output.values.flat_map { |entries| pairs(entries.map(&:last)) }
    end

    # Each of two concurrent records endorses a different spend of the same
    # output of the account's own currency.
    def endorsement_conflicts
      choices = []
      @view.records_of(@account).each do |r|
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

          Cause.new(:conflict, [r1, r2])
        end
      end
    end

    def pairs(records)
      records.combination(2).filter_map do |a, b|
        Cause.new(:conflict, [a, b]) if @view.histories.concurrent?(a.digest, b.digest)
      end
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
