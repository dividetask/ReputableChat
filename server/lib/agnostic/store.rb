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
      db[:peers].insert_conflict(target: :url, update: { host: host }).insert(url: url, cursor: 0, host: host)
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
      db.alter_table(:peers) { add_column :host, String } unless db[:peers].columns.include?(:host)
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
