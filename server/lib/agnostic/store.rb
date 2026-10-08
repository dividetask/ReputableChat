# frozen_string_literal: true

require "json"
require "set"
require "sequel"
require_relative "record"

module Agnostic
  # The records this server holds, and the indexes the rules need to read them.
  #
  # Only valid records are stored, and a record is stored only after every
  # record it acknowledges, so seq is a topological order: a record's history
  # always has lower seqs than it does. The payload is kept exactly as it
  # arrived and served back byte-identical.
  class Store
    attr_reader :db

    def initialize(url)
      @db = Sequel.connect(url)
      @db.run("PRAGMA journal_mode = WAL") if url.start_with?("sqlite://") && !url.end_with?("/")
      @db.run("PRAGMA foreign_keys = ON") if sqlite?
      migrate
    end

    def sqlite? = db.database_type == :sqlite

    # --- writing --------------------------------------------------------------

    def insert(record)
      db.transaction do
        seq = db[:records].insert(
          hash: record.digest, payload: record.payload, signature: record.signature,
          type: record["type"], account: record.account, subject: record.subject, kind: record.kind,
          version: record.version, notice_kind: record.notice_kind, ts: record.ts,
          signer: record.signer, signer_field: record.signer_field,
          beat_index: record.beat_index, facts: JSON.generate(record.facts),
          received_at: Time.now.to_i
        )
        record.seq = seq
        rows(:acks, record, record.ack) { |h| { child: record.digest, parent: h } }
        rows(:targets, record, record.target) { |h| { record: record.digest, target: h } }
        rows(:endorsements, record, record.endorse) { |h| { record: record.digest, endorsed: h } }
        spent = Array(record.transfer&.fetch("in", nil))
        rows(:spends, record, spent) { |h| { record: record.digest, output: h, account: record.account } }
        assign_generations(record) if record.heartbeat?
      end
      record
    end

    # --- reading single records -------------------------------------------------

    def known?(hash) = !db[:records].where(hash: hash).empty?

    def fetch(hash)
      row = db[:records].where(hash: hash).first
      row && hydrate(row)
    end

    def fetch_many(hashes)
      return [] if hashes.empty?

      hashes.each_slice(500).flat_map { |slice| db[:records].where(hash: slice).all }
            .map { |row| hydrate(row) }.sort_by(&:seq)
    end

    def count = db[:records].count

    # --- history ------------------------------------------------------------------

    # Every record reachable from these hashes by following acks, the hashes
    # themselves included.
    def closure(hashes)
      hashes = hashes.select { |h| Record.hash?(h) }
      return Set.new if hashes.empty?

      seeds = hashes.map { |h| "('#{h}')" }.join(",")
      sql = <<~SQL
        WITH RECURSIVE h(hash) AS (
          VALUES #{seeds}
          UNION
          SELECT acks.parent FROM acks JOIN h ON acks.child = h.hash
        )
        SELECT hash FROM h
      SQL
      db.fetch(sql).map { |row| row[:hash] }.to_set
    end

    # Every record whose history holds this one.
    def descendants(hash)
      return Set.new unless Record.hash?(hash)

      sql = <<~SQL
        WITH RECURSIVE d(hash) AS (
          SELECT child FROM acks WHERE parent = '#{hash}'
          UNION
          SELECT acks.child FROM acks JOIN d ON acks.parent = d.hash
        )
        SELECT hash FROM d
      SQL
      db.fetch(sql).map { |row| row[:hash] }.to_set
    end

    # --- the queries the rules make -----------------------------------------------

    def by_account(account, kind: nil, notice_kind: nil)
      scope = db[:records].where(account: account)
      scope = scope.where(kind: kind) if kind
      scope = scope.where(notice_kind: notice_kind) if notice_kind
      scope.order(:seq).all.map { |row| hydrate(row) }
    end

    def by_subject(subject, notice_kind:)
      db[:records].where(subject: subject, notice_kind: notice_kind).order(:seq).all.map { |row| hydrate(row) }
    end

    def endorsers(hash)
      db[:records].where(hash: db[:endorsements].where(endorsed: hash).select(:record))
                  .order(:seq).all.map { |row| hydrate(row) }
    end

    def spenders(output, account)
      db[:records].where(hash: db[:spends].where(output: output, account: account).select(:record))
                  .order(:seq).all.map { |row| hydrate(row) }
    end

    def heartbeat_authors = db[:records].where(kind: "heartbeat").distinct.select_map(:account)

    # --- what peers and apps read -------------------------------------------------

    # Records in the order this server accepted them, which puts every record
    # after everything it acknowledges. Filters narrow it without the server
    # knowing what any type means.
    def since(seq, limit:, type: nil, account: nil, target: nil)
      scope = db[:records].where { Sequel[:seq] > seq.to_i }
      if type
        escaped = type.gsub(/[\\%_]/) { |c| "\\#{c}" }
        scope = scope.where(Sequel.like(:type, "#{escaped}%", escape: "\\"))
      end
      scope = scope.where(account: account) if account
      scope = scope.where(hash: db[:targets].where(target: target).select(:record)) if target
      scope.order(:seq).limit(limit).all.map { |row| hydrate(row) }
    end

    # --- generations ------------------------------------------------------------------

    # Generations belong to an account that publishes heartbeats: its
    # generation g is every record its heartbeat g brought into its history
    # that none of its earlier heartbeats held. A record's history never
    # changes, so every server holding those heartbeats reaches the same
    # generations, and a server catching up can take them from any of them.
    #
    # Within a generation records are ordered by depth -- one past the
    # deepest of their parents in the same generation -- then by hash. That
    # puts each after everything it acknowledges, and puts them in the same
    # order on every server, so part 3 of a generation is the same records
    # wherever it is asked for.
    def assign_generations(beat)
      account = beat.account
      sql = <<~SQL
        WITH RECURSIVE h(hash) AS (
          VALUES ('#{beat.digest}')
          UNION
          SELECT acks.parent FROM acks
            JOIN h ON acks.child = h.hash
          WHERE NOT EXISTS (
            SELECT 1 FROM generations g WHERE g.account = #{db.literal(account)} AND g.record = acks.parent
          )
        )
        SELECT hash FROM h
      SQL
      fresh = db.fetch(sql).map { |row| row[:hash] }.to_set
      depth = {}
      parents = fresh.each_slice(500).flat_map { |slice| db[:acks].where(child: slice).select_map(%i[child parent]) }
                     .group_by(&:first).transform_values { |pairs| pairs.map(&:last).select { |h| fresh.include?(h) } }
      order = db[:records].where(hash: fresh.to_a).order(:seq).select_map(:hash)
      order.each { |h| depth[h] = (parents.fetch(h, []).map { |p| depth.fetch(p) }.max || -1) + 1 }
      rows = order.sort_by { |h| [depth[h], h] }.each_with_index.map do |h, i|
        { account: account, record: h, generation: beat.beat_index, position: i }
      end
      db[:generations].insert_ignore.multi_insert(rows)
    end

    def generations_assigned?(beat) = !db[:generations].where(account: beat.account, record: beat.digest).empty?

    def latest_generation(account) = db[:generations].where(account: account).max(:generation) || 0

    def generation_size(account, generation) = db[:generations].where(account: account, generation: generation).count

    def generation_part(account, generation, part, size)
      hashes = db[:generations].where(account: account, generation: generation).order(:position)
                               .limit(size, part * size).select_map(:record)
      rows = db[:records].where(hash: hashes).all.to_h { |row| [row[:hash], row] }
      hashes.map { |h| hydrate(rows.fetch(h)) }
    end

    # Accounts whose generations this server can serve, and how far.
    def generation_accounts
      db[:generations].group_and_count(:account).select_append(Sequel.function(:max, :generation).as(:latest)).all
    end

    # Records nothing on this server acknowledges yet.
    def frontier
      db[:records].exclude(hash: db[:acks].select(:parent)).order(:seq).all.map { |row| hydrate(row) }
    end

    def last_seq = db[:records].max(:seq) || 0

    # --- records waiting for what they acknowledge --------------------------------

    def hold(record, missing:, source:, at: Time.now.to_i)
      db[:pending].insert_conflict(:replace).insert(
        hash: record.digest, payload: record.payload, signature: record.signature,
        missing: JSON.generate(missing), source: source, received_at: at
      )
    end

    def pending_count = db[:pending].count

    def pending?(hash) = !db[:pending].where(hash: hash).empty?

    # Held records waiting for this one. Hashes are hex, so the pattern needs
    # no escaping.
    def waiting_for(hash) = db[:pending].where(Sequel.like(:missing, "%#{hash}%")).order(:received_at).all

    def release(hash) = db[:pending].where(hash: hash).delete

    def expire_pending(older_than) = db[:pending].where { received_at < older_than }.delete

    # --- peers and small state ----------------------------------------------------

    def peer_cursor(url) = db[:peers].where(url: url).get(:cursor) || 0

    def save_peer_cursor(url, cursor)
      db[:peers].insert_conflict(target: :url, update: { cursor: cursor.to_i }).insert(url: url, cursor: cursor.to_i)
    end

    def peer_host(url) = db[:peers].where(url: url).get(:host)

    def save_peer_host(url, host)
      db[:peers].insert_conflict(target: :url, update: { host: host }).insert(url: url, cursor: 0, host: host, added_at: 0)
    end

    def peer(url) = db[:peers].where(url: url).first

    def peers = db[:peers].order(:added_at, :url).all

    # A server to sync with: named at setup, in the settings, or learned from
    # a declaration passed along by another server. A server already known is
    # left as it is, unless it had been forgotten, which hearing of it again
    # undoes.
    def add_peer(url, source:, at:, host: nil, revive: true)
      existing = peer(url)
      if existing
        update_peer(url, forgotten: false, failures: 0, next_attempt_at: 0, added_at: at) if revive && existing[:forgotten]
        update_peer(url, host: host) if host && existing[:host].nil?
        return
      end

      db[:peers].insert(url: url, cursor: 0, host: host, source: source, added_at: at)
    end

    def update_peer(url, **values) = db[:peers].where(url: url).update(values)

    # Servers with this host account, after it contacted this one itself.
    def peer_alive(host, at:)
      db[:peers].where(host: host).update(failures: 0, next_attempt_at: 0, forgotten: false, last_success_at: at)
    end

    # Stop trying an account's addresses, all of them or all but one.
    def withdraw_peers(host, except: nil)
      scope = db[:peers].where(host: host)
      scope = scope.exclude(url: except) if except
      scope.update(forgotten: true)
    end

    # --- how reachable each server account has been ---------------------------------

    def contact(account) = db[:contacts].where(account: account).first

    def contacts = db[:contacts].order(:account).all

    def record_contact(account, success:, at:)
      db[:contacts].insert_ignore.insert(account: account, first_tried_at: at)
      row = db[:contacts].where(account: account)
      if success
        row.update(attempts: Sequel[:attempts] + 1, successes: Sequel[:successes] + 1, last_success_at: at, offline: false)
        row.where(first_success_at: nil).update(first_success_at: at)
      else
        row.update(attempts: Sequel[:attempts] + 1)
      end
    end

    # Forgotten for being unreachable, as opposed to having withdrawn its url.
    def mark_offline(account) = db[:contacts].where(account: account).update(offline: true)

    def published_rating(account) = db[:published_ratings].where(account: account).first

    def save_published_rating(account, reputation:, trust:, at:)
      db[:published_ratings].insert_conflict(:replace).insert(account: account, reputation: reputation, trust: trust, at: at)
    end

    # --- servers this one ignores -------------------------------------------------

    def ignored?(account, at:) = !db[:ignored].where(account: account).where { expires_at > at }.empty?

    def ignore(account, reason:, at:, until_at:)
      db[:ignored].insert_conflict(:replace).insert(account: account, reason: reason, at: at, expires_at: until_at)
    end

    def ignored(at:) = db[:ignored].where { expires_at > at }.order(:at).all

    def forgive(account) = db[:ignored].where(account: account).delete

    def meta(key) = db[:meta].where(key: key).get(:value)

    def save_meta(key, value) = db[:meta].insert_conflict(:replace).insert(key: key, value: value.to_s)

    private

    def rows(table, _record, values)
      values.uniq.each { |value| db[table].insert(yield(value)) }
    end

    def hydrate(row)
      record = Record.new(payload: row[:payload], signature: row[:signature])
      record.seq = row[:seq]
      record.signer = row[:signer]
      record.signer_field = row[:signer_field]
      record.subject = row[:subject]
      record.beat_index = row[:beat_index]
      record.facts = JSON.parse(row[:facts] || "{}")
      record
    end

    def migrate
      db.create_table?(:records) do
        primary_key :seq
        String :hash, null: false, unique: true
        String :payload, text: true, null: false
        String :signature, null: false
        String :type, null: false
        String :account, null: false
        String :subject, null: false
        String :kind, null: false
        String :version, null: false
        String :notice_kind
        Integer :ts, null: false
        String :signer, null: false
        String :signer_field, null: false
        Integer :beat_index
        String :facts, text: true
        Integer :received_at, null: false
        index :account
        index :subject
        index %i[kind account]
      end
      db.create_table?(:acks) do
        String :child, null: false
        String :parent, null: false
        primary_key %i[child parent]
        index :parent
      end
      db.create_table?(:targets) do
        String :record, null: false
        String :target, null: false
        primary_key %i[record target]
        index :target
      end
      db.create_table?(:endorsements) do
        String :record, null: false
        String :endorsed, null: false
        primary_key %i[record endorsed]
        index :endorsed
      end
      db.create_table?(:spends) do
        String :record, null: false
        String :output, null: false
        String :account, null: false
        primary_key %i[record output]
        index %i[output account]
      end
      db.create_table?(:pending) do
        String :hash, primary_key: true
        String :payload, text: true, null: false
        String :signature, null: false
        String :missing, text: true, null: false
        String :source
        Integer :received_at, null: false
      end
      db.create_table?(:peers) do
        String :url, primary_key: true
        Integer :cursor, null: false, default: 0
      end
      db.create_table?(:generations) do
        String :account, null: false
        String :record, null: false
        Integer :generation, null: false
        Integer :position, null: false
        primary_key %i[account record]
        index %i[account generation position]
      end
      {
        host: [String], source: [String, { null: false, default: "settings" }],
        added_at: [Integer, { null: false, default: 0 }], last_success_at: [Integer],
        failures: [Integer, { null: false, default: 0 }], next_attempt_at: [Integer, { null: false, default: 0 }],
        forgotten: [TrueClass, { null: false, default: false }]
      }.each do |column, (type, options)|
        db.alter_table(:peers) { add_column column, type, **(options || {}) } unless db[:peers].columns.include?(column)
      end
      db.create_table?(:contacts) do
        String :account, primary_key: true
        Integer :first_tried_at, null: false
        Integer :attempts, null: false, default: 0
        Integer :successes, null: false, default: 0
        Integer :first_success_at
        Integer :last_success_at
        TrueClass :offline, null: false, default: false
      end
      db.create_table?(:published_ratings) do
        String :account, primary_key: true
        String :reputation, null: false
        String :trust, null: false
        Integer :at, null: false
      end
      db.create_table?(:ignored) do
        String :account, primary_key: true
        String :reason, text: true, null: false
        Integer :at, null: false
        Integer :expires_at, null: false, default: 0
      end
      db.alter_table(:ignored) { add_column :expires_at, Integer, null: false, default: 0 } unless
        db[:ignored].columns.include?(:expires_at)
      db.create_table?(:meta) do
        String :key, primary_key: true
        String :value, text: true
      end
    end
  end
end
