# frozen_string_literal: true

require "set"
require "bigdecimal"
require_relative "record"

module ReputableChat
  module Chain
    # The chain as this server holds it, and the half of the rules that needs a
    # record's history: which keys it may sign with, whether a quorum counts,
    # whether what it spends exists, whether it holds a record a heartbeat
    # orphaned.
    #
    # Records join in the order they are added, and a record can only be added
    # once everything it acknowledges is here, so that order is always one in
    # which every record comes after its whole history. Ancestry questions use
    # it to stop early: nothing can be in the history of a record older than it.
    #
    # Held in memory and rebuilt from the database at boot. Whether a record is
    # valid is decided by the record and its history alone (section 1), so a
    # record that was valid when stored stays valid, and replaying stored
    # records does not check them again.
    class Ledger
      # A record whose ack names something this ledger does not hold. Not a
      # verdict on the record: send what it acknowledges first.
      class Unknown < Invalid; end

      # Rules versions whose records this code knows how to judge.
      VERSIONS = ["v0.001"].freeze

      HEARTBEAT_GAP  = 480
      ORPHAN_AFTER   = 256
      ADOPTION_COUNT = 16
      HISTORY_CACHE  = 256

      # Every record, as seen by nothing in particular: the view the server
      # takes when asked for a record's state rather than its validity.
      EVERYTHING = Object.new.tap { |o| o.define_singleton_method(:include?) { |_| true } }.freeze

      attr_reader :genesis

      # `orphan_after` is the rules' 256, and is a parameter only so a test can
      # reach it without signing hundreds of heartbeats.
      def initialize(genesis:, versions: VERSIONS, orphan_after: ORPHAN_AFTER)
        @versions = versions
        @orphan_after = orphan_after
        @records = {}
        @order = []
        @index = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
        @conflicts = Hash.new { |h, k| h[k] = [] }
        @histories = {}
        @states = {}

        raise Invalid, "the genesis record is not a genesis: it must be a first identity declaration with an empty ack" unless genesis.genesis?

        @genesis = genesis
        join(genesis, Set.new)
      end

      def [](hash) = @records[hash]
      def include?(hash) = @records.key?(hash)
      def size = @order.size
      def records = @order

      # Adds a record that has been checked. Returns :duplicate for one already
      # held, and raises Invalid with the rule it breaks otherwise.
      def add(record)
        return :duplicate if include?(record.record_hash)

        view = validate!(record)
        join(record, view)
        :ok
      end

      # A record read back from storage: indexed, not judged again.
      def adopt(record)
        return :duplicate if include?(record.record_hash)

        missing = record.acks.reject { |h| include?(h) }
        raise Unknown, "stored record #{record.record_hash} acknowledges #{missing.first}, which is not stored" unless missing.empty?

        view = history_of_new(record)
        record.signer ||= choose_signer(record, view, strict: false)
        annotate(record, view)
        join(record, view)
        :ok
      end

      # --- history -------------------------------------------------------------

      # The hashes of every record in `record`'s history: what its ack names,
      # and their histories, never the record itself.
      def history(record)
        cached = @histories[record.record_hash]
        return cached if cached

        set = walk(record.acks)
        remember(record.record_hash, set)
      end

      # Whether `older` is in `newer`'s history.
      def ancestor?(older, newer)
        return false if older.equal?(newer) || older.seq.nil? || newer.seq.nil?
        return false if older.seq >= newer.seq

        cached = @histories[newer.record_hash]
        return cached.include?(older.record_hash) if cached

        target = older.record_hash
        floor = older.seq
        seen = Set.new
        stack = newer.acks.dup
        until stack.empty?
          hash = stack.pop
          return true if hash == target
          next unless seen.add?(hash)

          rec = @records[hash]
          stack.concat(rec.acks) if rec && rec.seq > floor
        end
        false
      end

      def concurrent?(a, b) = !a.equal?(b) && !ancestor?(a, b) && !ancestor?(b, a)

      # --- accounts, as seen by a view ------------------------------------------

      def records_of(account) = @index[:account][account]

      # The account a working key signs for: the oldest account that declared
      # it or moved to it and may still sign with it. nil for a key no account
      # uses.
      def account_for(pubkey)
        @index[:key][pubkey].uniq.find do |account|
          keys(account, EVERYTHING, "pubkey")[:allowed].include?(pubkey)
        end
      end
      def declarations_of(account) = @index[:declaration][account]

      # The account's newest identity declaration in the view: the one no other
      # in the view has in its history, and of several such the latest signed.
      def declaration(account, view = EVERYTHING)
        decls = declarations_of(account).select { |d| view.include?(d.record_hash) }
        newest(decls)
      end

      def attestation(account, view = EVERYTHING)
        newest(@index[:attestation][account].select { |a| view.include?(a.record_hash) })
      end

      # The keys an account may sign with, as seen by a view, for one role:
      # "pubkey" for the working key or "mpubkey" for the master key.
      #
      # confirmed: the first declaration's key, or the one the latest quorum
      #            named; tentative: changes since, not void; void: changes a
      #            quorum overruled, and changes signed with their keys.
      def keys(account, view, role)
        first = @records[account]
        changes = @index[:key_change][account].select { |c| c.changes_role == role && view.include?(c.record_hash) }
        quorums = @index[:quorum][account].select do |q|
          view.include?(q.record_hash) && (n = @records[q.targets.first]).key_change? && n.changes_role == role
        end

        latest = quorums.reject { |q| quorums.any? { |o| ancestor?(q, o) } }
        named_by_any = quorums.map { |q| @records[q.targets.first] }
        named = latest.map { |q| @records[q.targets.first] }
        settled = latest.each_with_object(Set.new) { |q, s| s.merge(history(q)) }

        confirmed = named.empty? ? [first[role]].compact : named.map { |n| n["body"] }.uniq
        tentative = []
        void = []
        void_keys = Set.new

        changes.each do |c|
          next if named_by_any.include?(c)

          overruled = settled.include?(c.record_hash) ||
                      named_by_any.any? { |n| concurrent?(c, n) } ||
                      (c.signer&.first == role && void_keys.include?(c.signer.last))
          if overruled
            void << c
            void_keys << c["body"]
          else
            tentative << c
          end
        end

        tips = tentative.reject { |c| tentative.any? { |o| ancestor?(c, o) } }
        {
          confirmed: confirmed,
          tentative: tentative,
          void: void,
          void_keys: void_keys,
          in_force: tips.empty? ? confirmed : tips.map { |c| c["body"] }.uniq,
          allowed: (confirmed + tentative.map { |c| c["body"] }).to_set
        }
      end

      # The developer's account alone, unless a declaration names others
      # (section 3). A later list takes effect only once the list in force has
      # endorsed it, or, while the account is not disputed, built on it.
      def adjudicators(account, view)
        decls = declarations_of(account).select { |d| view.include?(d.record_hash) }
        return [genesis.record_hash] if decls.empty?

        list = adjudicator_list(decls.first)
        decls.drop(1).each do |d|
          proposed = adjudicator_list(d)
          next if proposed == list

          list = proposed if adopted?(d, list, account, view)
        end
        list
      end

      # The records that hold an account disputed as seen by a view: each
      # trigger is the set of records that made it. A quorum for the account
      # settles a trigger when it names one of its records -- the rest are then
      # void (section 8) whether or not the quorum's history holds them -- or
      # when its history holds all of them.
      def open_disputes(account, view)
        triggers = []
        @index[:compromised][account].each { |n| triggers << [n] if view.include?(n.record_hash) }
        @conflicts[account].each { |a, b| triggers << [a, b] if view.include?(a.record_hash) && view.include?(b.record_hash) }
        @index[:contesting][account].each { |r| triggers << [r, *r.contests] if view.include?(r.record_hash) }

        quorums = @index[:quorum][account].select { |q| view.include?(q.record_hash) }
        triggers.reject do |recs|
          quorums.any? do |q|
            recs.any? { |x| x.record_hash == q.targets.first } || recs.all? { |x| ancestor?(x, q) }
          end
        end
      end

      def disputed?(account, view) = !open_disputes(account, view).empty?

      # A record's state as seen by everything this ledger holds (section 1).
      def state(hash)
        @states[hash] ||= compute_state(@records[hash])
      end

      private

      # --- joining ---------------------------------------------------------------

      def join(record, view)
        record.seq = @order.size
        @records[record.record_hash] = record
        @order << record
        remember(record.record_hash, view)
        index!(record)
        @states.clear
      end

      def index!(r)
        a = r.account
        @index[:account][a] << r
        @index[:key][r["pubkey"]] << a if r.first_declaration?
        @index[:key][r["body"]] << a if r.notice_kind == Record::KEY_CHANGE
        if r.kind == "identity"
          @index[:declaration][a] << r
          @index[:issuer][a] << r if r.issuing?
        end
        @index[:attestation][a] << r if r.kind == "attestation"
        @index[:key_change][a] << r if r.key_change?
        @index[:heartbeat][a] << r if r.kind == "heartbeat"
        @index[:contesting][a] << r unless r.contests.to_a.empty?
        r.spends.each { |h| @index[:spend][[a, h]] << r }
        r.endorses.each { |h| @index[:endorser][h] << r }

        case r.notice_kind
        when Record::COMPROMISED then @index[:compromised][@records[r.targets.first].account] << r
        when Record::QUORUM then @index[:quorum][@records[r.targets.first].account] << r
        end

        record_conflicts(r)
      end

      # Two concurrent records of one account conflict (section 8). Found as
      # the later of the two joins: the earlier cannot hold it, so they are
      # concurrent exactly when the later does not hold the earlier.
      def record_conflicts(r)
        a = r.account
        held = history(r)
        others = []

        others.concat(@index[:key_change][a].select { |c| c.changes_role == r.changes_role }) if r.key_change?
        r.spends.each { |h| others.concat(@index[:spend][[a, h]]) }
        issuer_endorsed_spends(r).each do |spend, key|
          (@index[:spend][key] - [spend]).each do |rival|
            others.concat(@index[:endorser][rival.record_hash].select { |e| e.account == a })
          end
        end

        others.uniq.each do |o|
          next if o.equal?(r) || held.include?(o.record_hash)

          @conflicts[a] << [o, r]
        end
      end

      # The spends of its own currency a record endorses, each with the output
      # it spends: [spend, [spender, output record hash]].
      def issuer_endorsed_spends(r)
        r.endorses.flat_map do |h|
          s = @records[h]
          next [] unless s && s.currency == r.account && !s.spends.empty?

          s.spends.map { |out| [s, [s.account, out]] }
        end
      end

      def remember(hash, set)
        @histories.delete(@histories.first.first) if @histories.size >= HISTORY_CACHE && !@histories.key?(hash)
        @histories[hash] = set
      end

      def walk(acks)
        seen = Set.new
        stack = acks.dup
        until stack.empty?
          hash = stack.pop
          next unless seen.add?(hash)

          rec = @records[hash]
          stack.concat(rec.acks) if rec
        end
        seen
      end

      def history_of_new(record) = walk(record.acks)

      def newest(records)
        tips = records.reject { |r| records.any? { |o| ancestor?(r, o) } }
        tips.max_by { |r| [r["ts"], r.record_hash] }
      end

      # --- validity ----------------------------------------------------------------

      def invalid(message) = raise(Invalid, message)
      def short(hash) = hash[0, 12]
      def plain(number) = number.to_s("F").sub(/\.0\z/, "")

      def validate!(r)
        invalid("there is already a genesis record") if r.genesis?

        missing = r.acks.reject { |h| include?(h) }
        raise Unknown, "ack names #{short(missing.first)}, which this server does not hold; send it first" unless missing.empty?

        check_versions!(r)
        view = history_of_new(r)

        # Treated as joined for the length of the check, so ancestry questions
        # about it work like any other record's; undone if it fails.
        r.seq = @order.size
        remember(r.record_hash, view)
        begin
          check_account!(r, view)
          r.signer = choose_signer(r, view, strict: true)
          check_endorse!(r, view)
          annotate(r, view)
          check_notice!(r, view)
          check_transfer!(r, view) if r.transfer
          check_issuer_endorsements!(r, view)
          check_heartbeat!(r, view) if r.kind == "heartbeat"
          check_orphans!(r, view)
        rescue Invalid
          r.seq = nil
          @histories.delete(r.record_hash)
          raise
        end
        view
      end

      # A record conforms to the rules its history leads to (sections 2 and 9):
      # the version it acknowledges, or for a release, the next one.
      def check_versions!(r)
        versions = r.acks.map { |h| @records[h].version }.uniq

        if r.kind == "release"
          invalid("a release's ack names records of one version, the previous") unless versions.size == 1
          invalid("a release starts a new version, not #{r.version} again") if versions.first == r.version
          invalid("this server implements rules #{@versions.join(', ')}, and cannot judge a release from #{versions.first}") unless @versions.include?(versions.first)
        else
          invalid("every record an ack names must share this record's version, #{r.version}") unless versions == [r.version]
          invalid("this server implements rules #{@versions.join(', ')}, not #{r.version}") unless @versions.include?(r.version)
        end
      end

      def check_account!(r, view)
        return if r.first_declaration?

        first = @records[r.account]
        invalid("id #{short(r.account)} names no account in this record's history") unless
          first&.first_declaration? && view.include?(r.account)
      end

      # Which carried key signed, and that the account may sign with it
      # (section 2). Strict when judging a new record; a stored one only needs
      # its signer recovered.
      def choose_signer(r, view, strict:)
        return r.signers.first if r.first_declaration?

        allowed = { "pubkey" => keys(r.account, view, "pubkey")[:allowed],
                    "mpubkey" => keys(r.account, view, "mpubkey")[:allowed] }
        if r.notice_kind == Record::MASTER_KEY_CHANGE
          allowed["pubkey"] = Set.new
        end

        chosen = r.signers.find { |role, key| allowed[role].include?(key) }
        return chosen if chosen
        return r.signers.first unless strict

        if r.notice_kind == Record::MASTER_KEY_CHANGE
          invalid("a master key change is signed with the account's current master key")
        end
        invalid("signed with a key this account may not sign with, as seen by this record")
      end

      def check_endorse!(r, view)
        outside = r.endorses.reject { |h| view.include?(h) }
        invalid("endorse names #{short(outside.first)}, which is not in this record's history") unless outside.empty?
      end

      # Facts about a record that depend on its history and never change.
      def annotate(r, view)
        role, key = r.signer
        changes = @index[:key_change][r.account].select { |c| c.changes_role == role && view.include?(c.record_hash) }
        r.contests = changes.select { |c| c.replaced.include?(key) && c["body"] != key }
        r.replaced = keys(r.account, view, r.changes_role)[:in_force] if r.key_change?

        r.beats = r.acks.each_with_object({}) do |h, merged|
          a = @records[h]
          a.beats&.each { |pub, n| merged[pub] = n if n > (merged[pub] || -1) }
          merged[a.account] = a.beat if a.kind == "heartbeat" && a.beat > (merged[a.account] || -1)
        end
        r.beat = @index[:heartbeat][r.account].count { |h| view.include?(h.record_hash) } if r.kind == "heartbeat"
      end

      # --- section 7 ---------------------------------------------------------------

      def check_notice!(r, view)
        case r.notice_kind
        when Record::COMPROMISED then check_compromised!(r, view)
        when Record::QUORUM then check_quorum!(r, view)
        end
      end

      def check_compromised!(r, view)
        named = r.targets.map do |h|
          invalid("a compromised notice's target must be in its history") unless view.include?(h)
          @records[h]
        end
        accounts = named.map(&:account).uniq
        invalid("a compromised notice names records of one account") unless accounts.size == 1

        account = accounts.first
        return if r.account == account
        return if adjudicators(account, view).include?(r.account)

        invalid("a compromised notice is signed with the account's own key or by one of its adjudicators")
      end

      def check_quorum!(r, view)
        target = @records[r.targets.first]
        invalid("a quorum's target must be in its history") unless target && view.include?(target.record_hash)

        account = target.account
        adjudicators = adjudicators(account, view)
        rivals = conflicting(target, view)
        endorsers = ->(rec) { @index[:endorser][rec.record_hash].select { |e| view.include?(e.record_hash) }.map(&:account) }

        backing = endorsers.call(target)
        doubled = adjudicators.select { |a| backing.include?(a) && rivals.any? { |x| endorsers.call(x).include?(a) } }
        left = adjudicators - doubled

        named = r.endorses.map { |h| @records[h] }.select { |e| e.endorses.include?(target.record_hash) }.map(&:account)
        count = (left & named).size
        unless count * 2 > left.size
          invalid("a quorum needs more than half of #{left.size} adjudicators endorsing its target; its endorse names #{count}")
        end

        check_master_bound!(r, target, account, view)
      end

      def conflicting(target, view)
        @conflicts[target.account].filter_map do |a, b|
          other = a.equal?(target) ? b : (b.equal?(target) ? a : nil)
          other if other && view.include?(other.record_hash)
        end
      end

      # Once the master key has moved a key, only what the master key reaches
      # may be named (section 7).
      def check_master_bound!(_r, target, account, view)
        master_changes = @index[:key_change][account].select { |c| view.include?(c.record_hash) && c.signer&.first == "mpubkey" }
        return if master_changes.empty?

        disputing = open_disputes(account, view).flatten.uniq
        bound = disputing.any? do |x|
          (x.key_change? && x.signer&.first == "mpubkey") ||
            master_changes.any? { |c| c.changes_role == x.signer&.first && c.replaced.include?(x.signer&.last) }
        end
        return unless bound
        return if target.signer&.first == "mpubkey"
        return if master_changes.any? { |c| c.changes_role == target.signer&.first && c["body"] == target.signer&.last }

        invalid("a quorum here may name only a record signed with the master key or a key a master-signed change introduced")
      end

      # --- section 11 -----------------------------------------------------------------

      def currency?(account, r, view)
        return true if r.kind == "identity" && r.account == account && r.issuing?

        @index[:issuer][account].any? { |d| view.include?(d.record_hash) }
      end

      def check_transfer!(r, view)
        currency = r.currency
        invalid("#{short(currency)} is not a currency as seen by this record") unless currency?(currency, r, view)

        r.outputs.each do |o|
          to = o["to"]
          next if to == r.account
          next if @records[to]&.first_declaration? && view.include?(to)

          invalid("an output pays #{short(to)}, which is not an account in this record's history")
        end

        spent = BigDecimal("0")
        r.spends.each do |h|
          invalid("it spends #{short(h)}, which is not in its history") unless view.include?(h)

          source = @records[h]
          output = source.output_to(r.account)
          invalid("it spends #{short(h)}, which made no output for this account") unless output
          invalid("it spends #{short(h)}, which is of another currency") unless source.currency == currency
          if @index[:spend][[r.account, h]].any? { |s| view.include?(s.record_hash) }
            invalid("it spends #{short(h)}, already spent by a record in its history")
          end
          spent += BigDecimal(output["value"])
        end

        return unless r.transfer.key?("in") && r.transfer.key?("out")

        made = r.outputs.sum(BigDecimal("0")) { |o| BigDecimal(o["value"]) }
        invalid("it spends #{plain(spent)} and makes #{plain(made)}; they must be equal") unless spent == made
      end

      def check_issuer_endorsements!(r, view)
        chosen = Hash.new { |h, k| h[k] = [] }
        issuer_endorsed_spends(r).each { |spend, key| chosen[key] << spend }

        chosen.each do |key, spends|
          invalid("it endorses both spends of one output") if spends.uniq.size > 1

          rivals = @index[:spend][key] - spends
          rivals.each do |rival|
            already = @index[:endorser][rival.record_hash].any? { |e| e.account == r.account && view.include?(e.record_hash) }
            invalid("it endorses a spend when its history holds the issuer's endorsement of the other") if already
          end
        end
      end

      # --- section 10 -----------------------------------------------------------------

      def check_heartbeat!(r, view)
        mine = @index[:heartbeat][r.account].select { |h| view.include?(h.record_hash) }
        tips = mine.reject { |h| mine.any? { |o| ancestor?(h, o) } }
        invalid("its author's earlier heartbeats are not one chain") if tips.size > 1

        previous = tips.first
        return unless previous

        if previous.version == r.version && !r.acks.include?(previous.record_hash)
          invalid("a heartbeat must directly ack its author's previous heartbeat, #{short(previous.record_hash)}")
        end
        gap = r["ts"] - previous["ts"]
        invalid("a heartbeat comes at least #{HEARTBEAT_GAP} seconds after its author's previous one; this is #{gap}") if gap < HEARTBEAT_GAP
      end

      # No record may hold both a record and the heartbeat that orphaned it.
      def check_orphans!(r, view)
        r.beats.each do |publisher, newest|
          next if newest < @orphan_after

          beat = @index[:heartbeat][publisher].find { |h| h.beat == newest && view.include?(h.record_hash) }
          next unless beat

          joined = history(beat)
          seen = Set.new
          stack = r.acks.dup
          until stack.empty?
            hash = stack.pop
            next if hash == beat.record_hash || joined.include?(hash) || !seen.add?(hash)

            x = @records[hash]
            held = x.beats[publisher] || 0
            if newest - held >= @orphan_after
              invalid("it holds #{short(hash)} and heartbeat #{short(beat.record_hash)}, which orphaned it")
            end
            stack.concat(x.acks)
          end
        end
      end

      # --- section 3 -------------------------------------------------------------------

      def adjudicator_list(declaration)
        list = declaration["adjudicators"]
        list.nil? || list.empty? ? [genesis.record_hash] : list
      end

      def adopted?(declaration, list, account, view)
        majority = ->(n) { n * 2 > list.size }
        endorsing = @index[:endorser][declaration.record_hash].select { |e| view.include?(e.record_hash) }.map(&:account)
        return true if majority.call((list & endorsing).size)
        return false if disputed?(account, view)

        built = list.count do |adjudicator|
          records_of(adjudicator).count { |x| view.include?(x.record_hash) && ancestor?(declaration, x) } >= ADOPTION_COUNT
        end
        majority.call(built)
      end

      # --- states ---------------------------------------------------------------------

      def compute_state(r)
        return nil unless r

        account = r.account
        role, key = r.signer
        state = keys(account, EVERYTHING, r.key_change? ? r.changes_role : role)

        return "void" if r.key_change? && state[:void].include?(r)
        return "void" if role && keys(account, EVERYTHING, role)[:void_keys].include?(key)
        return "void" if conflicts_with_confirmed?(r)
        return "void" if spend_lost?(r)
        return "disputed" if disputed?(account, EVERYTHING)
        return "confirmed" if @index[:quorum][account].any? { |q| q.targets.first == r.record_hash }
        return "tentative" if r.key_change? && state[:tentative].include?(r)

        "valid"
      end

      def conflicts_with_confirmed?(r)
        @conflicts[r.account].any? do |a, b|
          other = a.equal?(r) ? b : (b.equal?(r) ? a : nil)
          other && @index[:quorum][r.account].any? { |q| q.targets.first == other.record_hash }
        end
      end

      # The issuer chose the other spend of an output this one spends, or this
      # one spends an output a void record made.
      def spend_lost?(r)
        return false if r.spends.empty?

        r.spends.any? do |h|
          return true if state(h) == "void"

          issuer = r.currency
          (@index[:spend][[r.account, h]] - [r]).any? do |rival|
            @index[:endorser][rival.record_hash].any? { |e| e.account == issuer }
          end
        end
      end
    end
  end
end
