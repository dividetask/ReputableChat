# frozen_string_literal: true

require "bigdecimal"
require_relative "canonical"
require_relative "formats"
require_relative "keys"
require_relative "record"
require_relative "view"

module Agnostic
  # docs/project/rules/v0.001.md, enforced. Each check names the section it
  # comes from; the wording of the rules lives there and only there.
  #
  # A record is checked in two passes. The first needs nothing but the record.
  # The second needs its history, so it runs only once every record it
  # acknowledges is held here; until then the record is missing parents rather
  # than invalid.
  class Rules
    VERSION = "v0.001"
    TYPES = %w[attestation heartbeat identity message notice reaction release].freeze
    TYPE_PART = /\A[a-z0-9.-]{1,32}\z/

    ACK_RECORDS = 16
    HEARTBEAT_ACK_BYTES = 1_048_576
    LIST_RECORDS = 256
    FILES = 16
    ADJUDICATORS = 16
    SCORE_BYTES = 1_048_576
    HEARTBEAT_FIELDS = %w[type id pubkey mpubkey ack body ts endorse].freeze
    HEARTBEAT_FLOOR = 480
    SPLIT_BEATS = 256
    TRANSFER_FIELDS = %w[currency in out].freeze

    Verdict = Struct.new(:problems, :missing) do
      def valid? = problems.empty? && missing.empty?
    end

    attr_reader :store, :genesis

    # genesis: the Record this chain starts from.
    def initialize(store:, genesis:)
      @store = store
      @genesis = genesis
    end

    # On success the record carries what the store keeps beside it: the key
    # that signed it, the account it is about, its heartbeat count, and facts
    # later checks read rather than recompute.
    def check(record)
      problems = []
      structure(record, problems)
      return Verdict.new(problems, []) unless problems.empty?

      missing = record.ack.reject { |h| store.known?(h) }
      return Verdict.new([], missing) unless missing.empty?

      history(record, problems)
      Verdict.new(problems, [])
    rescue Canonical::NotCanonical => e
      Verdict.new([e.message], [])
    end

    # --- the record alone -----------------------------------------------------------

    def structure(record, problems)
      return problems.push("a record is a payload string and a signature string, neither holding a newline") unless record.digest

      record.fields
      problems.push("signature is not 64 bytes of base64url") unless Keys.signature?(record.signature)
      common(record, problems)
      return unless problems.empty?

      send(:"#{record.kind}_structure", record, problems)
      transfer_structure(record, problems) if record.key?("transfer")
      signed(record, problems) if problems.empty?
    end

    # Section 2.
    def common(record, problems)
      type(record, problems)
      return unless problems.empty?

      if record.first_declaration?
        problems.push("a first identity declaration must carry pubkey") unless record.key?("pubkey")
      else
        problems.push("id must be an account ID") unless Formats.record_hash?(record["id"])
      end
      %w[pubkey mpubkey].each do |field|
        problems.push("#{field} must be a signing key") if record.key?(field) && !Formats.signing_key?(record[field])
      end
      problems.push("a record must carry pubkey, mpubkey or both") unless record.key?("pubkey") || record.key?("mpubkey")
      ack(record, problems)
      problems.push("body must be Text of at most 16,000 bytes") unless Formats.text?(record["body"], max: 16_000)
      problems.push("ts must be a timestamp") unless Formats.timestamp?(record["ts"])
      rules_field(record, problems)
      optional(record, problems)
    end

    def type(record, problems)
      parts = record.type_parts
      unless Formats.text?(record["type"], min: 1, max: 128) && parts.size >= 3 && parts[0] == "reputablechat" &&
             parts[1..].all? { |p| p.match?(TYPE_PART) } && TYPES.include?(parts[1])
        return problems.push("type must be reputablechat:<record type>:<rules version>, in at most 128 bytes")
      end
      if record.release?
        problems.push("a release carries a rules version other than the one it follows") if record.version == VERSION
      elsif record.version != VERSION
        problems.push("rules version #{record.version} is not one this server implements (#{VERSION})")
      end
    end

    def ack(record, problems)
      ack = record["ack"]
      return problems.push("ack must be a sorted list of record hashes with no duplicates") unless
        ack.is_a?(Array) && ack.all? { |h| Formats.record_hash?(h) } && Formats.strictly_sorted?(ack)

      if record.heartbeat?
        problems.push("a heartbeat's ack must fit in 1,048,576 bytes") if Canonical.dump(ack).bytesize > HEARTBEAT_ACK_BYTES
      elsif ack.size > ACK_RECORDS
        problems.push("ack names #{ack.size} records, over the limit of #{ACK_RECORDS}")
      end
      problems.push("only the genesis record has an empty ack") if ack.empty? && record.digest != genesis.digest
    end

    def rules_field(record, problems)
      genesis = record.digest == self.genesis.digest
      if record.release? || genesis
        problems.push("rules must be Text of 1 to 64,000 bytes") unless Formats.text?(record["rules"], min: 1, max: 64_000)
      elsif record.key?("rules")
        problems.push("only the genesis record and releases carry rules")
      end
    end

    def optional(record, problems)
      %w[target endorse].each do |field|
        next unless record.key?(field)

        problems.push("#{field} must be a sorted list of at most 256 record hashes with no duplicates") unless
          Formats.hash_list?(record[field], max: LIST_RECORDS)
      end
      if record.key?("title") && !Formats.text?(record["title"], min: 1, max: 280)
        problems.push("title must be Text of 1 to 280 bytes")
      end
      if record.key?("file")
        files = record["file"]
        problems.push("file must list at most 16 files with no duplicates") unless
          files.is_a?(Array) && files.size <= FILES && files.all? { |f| Formats.file?(f) } && files.uniq.size == files.size
      end
      if record.key?("url") && !(Formats.text?(record["url"], min: 1, max: 2_048) && !record["url"].match?(/[[:space:]]/))
        problems.push("url must be Text of 1 to 2,048 bytes with no whitespace")
      end
      if record.key?("lang") && !(Formats.text?(record["lang"], min: 1, max: 35) && record["lang"].match?(/\A[A-Za-z0-9-]+\z/))
        problems.push("lang must be 1 to 35 bytes of letters, digits and hyphens")
      end
    end

    # Section 3.
    def identity_structure(record, problems)
      problems.push("an identity declaration's title, its handle, must be 1 to 64 bytes") unless
        Formats.text?(record["title"], min: 1, max: 64)
      problems.push("epubkey must be an encryption key") if record.key?("epubkey") && !Formats.encryption_key?(record["epubkey"])
      return unless record.key?("adjudicators")

      list = record["adjudicators"]
      problems.push("adjudicators must list at most 16 account IDs with no duplicates") unless
        list.is_a?(Array) && list.size <= ADJUDICATORS && list.all? { |a| Formats.record_hash?(a) } && list.uniq.size == list.size
    end

    # Section 4.
    def attestation_structure(record, problems)
      return problems.push("an attestation requires scores") unless record["scores"].is_a?(Hash)

      %w[scores derived].each do |field|
        next unless record.key?(field)
        next problems.push("#{field} must be a map of account ID to rating") unless record[field].is_a?(Hash)

        record[field].each do |account, score|
          next if Formats.record_hash?(account) && score?(score)

          problems.push("#{field} entry #{account.to_s[0, 16]} must be an account ID holding reputation and trust, " \
               "each a decimal from -1 to +1")
        end
      end
      size = %w[scores derived].sum { |f| record.key?(f) ? Canonical.dump(record[f]).bytesize : 0 }
      problems.push("scores and derived together exceed #{SCORE_BYTES} bytes") if size > SCORE_BYTES
    end

    def score?(score)
      score.is_a?(Hash) && score.keys.sort == %w[reputation trust] &&
        score.values.all? { |v| Formats.decimal?(v) && Formats.decimal(v).abs <= 1 }
    end

    # Section 5: a message has no meaning beyond its fields.
    def message_structure(_record, _problems); end

    # Section 6.
    def reaction_structure(record, problems)
      problems.push("a reaction requires target") if record.target.empty?
    end

    # Section 7.
    def notice_structure(record, problems)
      return problems.push("a notice requires kind, 1 to 64 bytes") unless Formats.text?(record["kind"], min: 1, max: 64)

      case record["kind"]
      when "compromised"
        problems.push("a compromised notice requires target") if record.target.empty?
      when "key-change", "master-key-change"
        problems.push("a #{record['kind']} notice's body is the new key and nothing else") unless Formats.signing_key?(record["body"])
      when "quorum"
        problems.push("a quorum names exactly one record in target") unless record.target.size == 1
      end
    end

    # Section 9.
    def release_structure(_record, _problems); end

    # Section 10.
    def heartbeat_structure(record, problems)
      extra = record.fields.keys - HEARTBEAT_FIELDS
      problems.push("a heartbeat carries #{extra.sort.join(', ')}, beyond what it may hold") unless extra.empty?
      problems.push("a heartbeat's body is empty") unless record["body"] == ""
    end

    # Section 2, transfer.
    def transfer_structure(record, problems)
      t = record["transfer"]
      return problems.push("transfer must be an object") unless t.is_a?(Hash)
      return problems.push("transfer may hold only currency, in and out") unless (t.keys - TRANSFER_FIELDS).empty?
      return problems.push("transfer must hold in, out or both") unless t.key?("in") || t.key?("out")
      return problems.push("transfer names a currency exactly when it spends: currency and in go together") unless
        t.key?("currency") == t.key?("in")

      problems.push("transfer currency must be an account ID") if t.key?("currency") && !Formats.record_hash?(t["currency"])
      if t.key?("in") && !Formats.hash_list?(t["in"], min: 1, max: LIST_RECORDS)
        problems.push("transfer in must be a sorted list of 1 to 256 record hashes with no duplicates")
      end
      return unless t.key?("out")

      out = t["out"]
      return problems.push("transfer out must hold 1 to 256 outputs") unless out.is_a?(Array) && out.size.between?(1, LIST_RECORDS)

      valid = out.all? do |o|
        o.is_a?(Hash) && o.keys.sort == %w[to value] && Formats.record_hash?(o["to"]) &&
          Formats.decimal?(o["value"]) && Formats.decimal(o["value"]).positive?
      end
      return problems.push("each output holds value, a decimal greater than zero, and to, an account ID") unless valid

      problems.push("transfer out must be sorted by to, with no two to the same account") unless
        Formats.strictly_sorted?(out.map { |o| o["to"] })
    end

    # Section 1: the signature verifies against pubkey or mpubkey.
    def signed(record, problems)
      fields = %w[pubkey mpubkey].select do |field|
        record.key?(field) && Keys.verify(record[field], record.signature, record.payload)
      end
      return problems.push("the signature verifies against no key the record carries") if fields.empty?

      record.facts["verified"] = fields
    end

    # --- the record and its history ---------------------------------------------------

    def history(record, problems)
      return genesis_facts(record) if record.digest == genesis.digest

      histories = Histories.new(store)
      view = View.of(record, store: store, histories: histories, genesis: genesis.digest)
      acked = store.fetch_many(record.ack)

      ack_versions(record, acked, problems)
      account(record, view, problems)
      return unless problems.empty?

      signer(record, view, problems)
      return unless problems.empty?

      record.subject = record.account
      problems.push("endorse names a record outside its history") unless record.endorse.all? { |h| view.include?(h) }
      notice(record, view, problems) if record.kind == "notice"
      transfer(record, view, problems) if record.transfer
      endorsed_spends(record, view, problems) unless record.endorse.empty?
      heartbeat(record, view, problems) if record.heartbeat?
      split(record, view, problems)
      record.facts.delete("verified")
    end

    def genesis_facts(record)
      record.signer_field = record.facts.delete("verified").first
      record.signer = record[record.signer_field]
      record.subject = record.account
    end

    # Section 2, ack, and section 9: every record named shares this record's
    # version, except that a release names records of the version before it.
    # The newest rules any record here acknowledges are therefore its own.
    def ack_versions(record, acked, problems)
      expected = record.release? ? VERSION : record.version
      wrong = acked.reject { |r| r.version == expected }
      return if wrong.empty?

      if record.release?
        problems.push("a release following rules #{wrong.first.version}, which this server does not implement")
      else
        problems.push("a record of #{record.version} acks a record of #{wrong.first.version}")
      end
    end

    # Section 2, account ID: the first declaration it names is in its history.
    def account(record, view, problems)
      return if record.first_declaration?

      first = view.include?(record["id"]) ? store.fetch(record["id"]) : nil
      problems.push("id names no first identity declaration in this record's history") unless first&.first_declaration?
    end

    # Section 2, working key: which keys may sign, and when signing contests.
    def signer(record, view, problems)
      verified = record.facts["verified"]
      if record.first_declaration?
        field = verified.first
      else
        keys = view.keys(record.account)
        field = verified.find { |f| keys.allowed(f).include?(record[f]) }
        unless field
          return problems.push("signed with a key that is neither the account's last confirmed key nor a tentative change's")
        end

        key = record[field]
        record.facts["contests"] = true unless keys.current(field).include?(key)
      end
      record.signer_field = field
      record.signer = record[field]
    end

    # Section 7.
    def notice(record, view, problems)
      case record.notice_kind
      when "compromised" then compromised(record, view, problems)
      when "key-change", "master-key-change" then key_change(record, view, problems)
      when "quorum" then quorum(record, view, problems)
      end
    end

    def compromised(record, view, problems)
      named = store.fetch_many(record.target)
      unless named.size == record.target.size && record.target.all? { |h| view.include?(h) }
        return problems.push("a compromised notice names records outside its history")
      end

      accounts = named.map(&:account).uniq
      return problems.push("a compromised notice names records of more than one account") unless accounts.size == 1

      subject = accounts.first
      record.subject = subject
      return if record.account == subject || view.adjudicators(subject).include?(record.account)

      problems.push("a compromised notice is signed by the account or one of its adjudicators")
    end

    def key_change(record, view, problems)
      keys = view.keys(record.account)
      field = KeyState::FIELDS.fetch(record.notice_kind)
      record.facts["replaced"] = keys.current(field)
      if field == "mpubkey"
        return if record.signer_field == "mpubkey" && keys.current("mpubkey").include?(record.signer)

        problems.push("a master key change is signed with the current master key")
      else
        return if keys.current(record.signer_field).include?(record.signer)

        problems.push("a key change is signed with one of the account's current keys")
      end
    end

    def quorum(record, view, problems)
      named_hash = record.target.first
      named = view.include?(named_hash) && store.fetch(named_hash)
      return problems.push("a quorum names a record in its history") unless named

      subject = named.subject
      record.subject = subject
      keys = view.keys(subject)
      disputes = view.disputes(subject)
      key_change = KeyState::FIELDS.key?(named.notice_kind) && named.account == subject

      # Which record a quorum should name is described in section 7, but its
      # validity turns only on the count and the master key: the example chain
      # names a spend whose rival is outside the quorum's own history.
      return problems.push("a quorum names a key change that is already void") if key_change && keys.void?(named.digest)

      master_only(named, view, disputes, problems)
      count(record, named, view, disputes, problems)
    end

    # The master key prevails through the quorum: once a master-signed key
    # change is in dispute, only what the master key reached can be named.
    def master_only(named, view, disputes, problems)
      master_changes = KeyState::FIELDS.keys.flat_map do |kind|
        view.records_of(named.subject, kind: "notice", notice_kind: kind)
      end.select { |c| c.signer_field == "mpubkey" }
      replaced = master_changes.flat_map { |c| Array(c.facts["replaced"]) }
      triggered = disputes.records.any? do |r|
        (KeyState::FIELDS.key?(r.notice_kind) && r.signer_field == "mpubkey") || replaced.include?(r.signer)
      end
      return unless triggered
      return if named.signer_field == "mpubkey" || master_changes.any? { |c| c["body"] == named.signer }

      problems.push("with a master-signed key change in dispute, a quorum names only what the master key signed or introduced")
    end

    def count(record, named, view, disputes, problems)
      group = [named] + disputes.conflicting_with(named)
      adjudicators = view.adjudicators(named.subject)
      doubled = adjudicators.select do |a|
        group.count { |g| view.endorsers(g.digest).any? { |e| e.account == a } } > 1
      end
      counted = adjudicators - doubled
      endorsing = store.fetch_many(record.endorse)
                       .select { |e| e.endorse.include?(named.digest) && counted.include?(e.account) }
                       .map(&:account).uniq
      return if !counted.empty? && endorsing.size * 2 > counted.size

      problems.push("a quorum needs more than half of the account's adjudicators to have endorsed what it names " \
           "(#{endorsing.size} of #{counted.size})")
    end

    # Section 11.
    def transfer(record, view, problems)
      t = record.transfer
      currency = Currency.of(record)
      issues = Currency.issues?(record)
      record.facts["issues"] = true if issues && record.kind == "identity"
      unless view.currency?(currency) || record.facts["issues"]
        return problems.push("the transfer moves #{currency[0, 8]}, which is not a currency as seen by this record")
      end

      Array(t["out"]).each do |o|
        next if o["to"] == record.account

        declaration = view.include?(o["to"]) ? store.fetch(o["to"]) : nil
        problems.push("an output pays an account that is not in this record's history") unless declaration&.first_declaration?
      end
      spend(record, view, currency, problems) if t.key?("in")
    end

    def spend(record, view, currency, problems)
      total = BigDecimal("0")
      record.transfer["in"].each do |hash|
        source = view.include?(hash) && store.fetch(hash)
        value = source && Currency.output_to(source, record.account)
        next problems.push("the transfer spends an output that is not in its history or not its own") unless value
        next problems.push("the transfer spends an output of another currency") unless Currency.of(source) == currency
        next problems.push("the transfer spends an output already spent in its history") unless
          view.spenders(hash, record.account).empty?

        total += value
      end
      return unless record.transfer.key?("out")

      made = record.transfer["out"].sum(BigDecimal("0")) { |o| BigDecimal(o["value"]) }
      problems.push("the transfer spends #{Formats.write(total)} and makes #{Formats.write(made)}") unless made == total
    end

    # Section 11, double spends: no record endorses both spends, nor a spend
    # once the issuer has chosen the other.
    def endorsed_spends(record, view, problems)
      spends = store.fetch_many(record.endorse).select { |r| r.transfer&.key?("in") }
      spends.each do |spend|
        spend.transfer["in"].each do |output|
          others = view.spenders(output, spend.account).reject { |r| r.digest == spend.digest }
          next if others.empty?
          if others.any? { |o| record.endorse.include?(o.digest) }
            return problems.push("the record endorses both spends of one output")
          end

          source = store.fetch(output)
          issuer = source && Currency.of(source)
          chosen = others.any? do |other|
            view.endorsers(other.digest).any? do |e|
              e.account == issuer && !view.as_seen_by(e.digest).disputed?(issuer)
            end
          end
          return problems.push("the record endorses a spend after the issuer chose the other") if chosen
        end
      end
    end

    # Section 10.
    def heartbeat(record, view, problems)
      beats = view.records_of(record.account, kind: "heartbeat")
      latest = beats.map(&:beat_index).max
      previous = beats.select { |b| b.beat_index == latest }
      previous.each do |prev|
        if prev.version == record.version && !record.ack.include?(prev.digest)
          problems.push("a heartbeat directly acks its author's previous heartbeat")
        end
        if record.ts - prev.ts < HEARTBEAT_FLOOR
          problems.push("a heartbeat comes at least #{HEARTBEAT_FLOOR} seconds after its author's previous one " \
               "(this is #{record.ts - prev.ts})")
        end
      end
      record.beat_index = (latest || 0) + 1
    end

    # Section 10, split: no history holds both a record and a heartbeat that
    # orphaned it.
    def split(_record, view, problems)
      authors = store.heartbeat_authors
      authors.each do |author|
        beats = view.records_of(author, kind: "heartbeat")
        next if beats.empty?

        top = beats.max_by(&:beat_index)
        next if top.beat_index <= SPLIT_BEATS

        covered = view.histories.of(top.digest)
        (view.hashes - covered - [top.digest]).each do |hash|
          held = view.histories.of(hash)
          newest = beats.select { |b| held.include?(b.digest) }.map(&:beat_index).max || 1
          orphaner = beats.find { |b| b.beat_index == newest + SPLIT_BEATS }
          next unless orphaner && !view.histories.of(orphaner.digest).include?(hash)

          return problems.push("the history holds #{hash} and #{orphaner.digest}, a heartbeat that orphaned it")
        end
      end
    end
  end
end
