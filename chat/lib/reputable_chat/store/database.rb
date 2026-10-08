# frozen_string_literal: true

require "sequel"
require "fileutils"
require "json"
require "securerandom"

module ReputableChat
  module Store
    # Persistence. Signed blobs in, signed blobs out, byte-identical. Whether a
    # record is valid is the agnostic server's to say; this keeps the chat's
    # copy of what that server accepted, in the order it accepted it.
    class Database
      IN_MEMORY       = ["sqlite:/", "sqlite::memory:"].freeze
      NONCE_TTL       = 300   # seconds a login challenge stays usable
      CLOCK_SKEW      = 120   # tolerated drift on a signed timestamp

      attr_reader :db

      def initialize(url)
        @url = url
        ensure_parent_directory(url)
        @db = Sequel.connect(url)
        migrate!
      end

      # SQLite will not create a missing parent directory, and `data/` is not
      # in the repository because git does not track empty directories. Without
      # this a fresh clone fails to boot with an opaque CantOpenException.
      def ensure_parent_directory(url)
        url = url.to_s
        return unless url.start_with?("sqlite:")
        return if IN_MEMORY.include?(url)

        path = url.sub(%r{\Asqlite://?}, "")
        return if path.empty?

        FileUtils.mkdir_p(File.dirname(path))
      end

      def migrate!
        refuse_legacy_tables

        # The records the chat keeps of the chain (Chain::Mirror): those about
        # the chain itself and the chat's own, in the order the agnostic
        # server accepted them. The server holds the chain; this is a copy of
        # the part the chat shows. `kind`, `type` and `account` are copies of
        # what the payload says, kept so they can be queried without parsing;
        # the payload is stored exactly as it arrived and served back unchanged.
        @db.create_table?(:records) do
          primary_key :id
          String   :hash, null: false, unique: true
          String   :kind, null: false, index: true
          String   :type, null: false
          String   :account, null: false, index: true
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
        end

        # Opaque to the server by design. It stores the blob, rejects a
        # rollback by revision, and serves it back to nobody but its owner.
        # Not a record on the chain.
        @db.create_table?(:vaults) do
          String   :pubkey, primary_key: true
          Integer  :revision, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :updated_at, null: false
        end

        # Where the mirror has read the agnostic server up to.
        @db.create_table?(:meta) do
          String   :key, primary_key: true
          String   :value
        end

        @db.create_table?(:nonces) do
          String   :nonce, primary_key: true
          Integer  :issued_at, null: false
          Integer  :used_at
        end
      end

      # --- login challenges ----------------------------------------------

      def issue_nonce
        nonce = SecureRandom.urlsafe_base64(32)
        @db[:nonces].insert(nonce: nonce, issued_at: now)
        nonce
      end

      # Single use and time limited. Claiming is a conditional update so two
      # concurrent logins cannot both spend the same challenge.
      def claim_nonce(nonce)
        return false unless nonce.is_a?(String)

        cutoff = now - NONCE_TTL
        @db[:nonces]
          .where(nonce: nonce, used_at: nil)
          .where { issued_at > cutoff }
          .update(used_at: now) == 1
      end

      def sweep_nonces
        @db[:nonces].where { issued_at < (now - NONCE_TTL) }.delete
      end

      # --- records -------------------------------------------------------------

      def store_record(hash:, kind:, type:, account:, payload:, signature:)
        @db[:records].insert(hash: hash, kind: kind, type: type, account: account, payload: payload,
                             signature: signature, received_at: now)
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      def record(hash) = @db[:records].where(hash: hash).first

      # The latest of one kind typed for the chat, oldest first.
      def chat_records(kind, limit)
        chat = Sequel.like(:type, "reputablechat:#{kind}:%:chat") | Sequel.like(:type, "reputablechat:#{kind}:%:chat:%")
        @db[:records].where(kind: kind).where(chat).order(Sequel.desc(:id)).limit(limit).all.reverse
      end

      # Newest first.
      def records_of(account, kind:, limit:)
        @db[:records].where(account: account, kind: kind).order(Sequel.desc(:id)).limit(limit).all
      end

      def chain_cursor = @db[:meta].where(key: "chain_cursor").get(:value).to_i

      def save_chain_cursor(cursor)
        @db[:meta].insert_conflict(:replace).insert(key: "chain_cursor", value: cursor.to_s)
      end

      # --- vaults -------------------------------------------------------------
      #
      # The read path takes no pubkey -- the route uses the session's -- so
      # asking for somebody else's is not expressible rather than being a check
      # that has to stay correct.

      def vault(pubkey) = @db[:vaults].where(pubkey: pubkey).first

      def store_vault(pubkey:, revision:, payload:, signature:)
        existing = vault(pubkey)
        return :stale if existing && revision <= existing[:revision]

        row = { pubkey: pubkey, revision: revision, payload: payload,
                signature: signature, updated_at: now }

        existing ? @db[:vaults].where(pubkey: pubkey).update(row) : @db[:vaults].insert(row)
        :ok
      end

      # Tables from before records followed the rules (v0.001). Their records
      # were signed in a shape that no longer exists, under a genesis that has
      # since been regenerated, so there is nothing in them to carry forward.
      LEGACY_TABLES = %i[users identities attestations notices adjustments messages emotes].freeze

      class LegacySchema < StandardError; end

      # Refuses to open such a database rather than rebuilding it, and says
      # which file to delete and what goes with it.
      def refuse_legacy_tables
        found = LEGACY_TABLES.select { |table| @db.table_exists?(table) }
        # A records table from when the chat judged records itself, before it
        # kept a copy of its agnostic server's.
        found << :records if @db.table_exists?(:records) && !@db[:records].columns.include?(:type)
        return if found.empty?

        raise LegacySchema,
              "#{location} was written by an earlier version of ReputableChat, before " \
              "records followed rules v0.001 (it has the tables #{found.join(', ')}). " \
              "Its records cannot be carried over: they were signed in a format that no " \
              "longer exists, and they acknowledge a genesis record that has been " \
              "regenerated. Nothing has been published yet, so stop the server, delete " \
              "that file and start it again; an empty database is created in its place. " \
              "Vaults go with it, so everybody's private settings and friend lists start " \
              "over too."
      end

      def location
        url = @url.to_s
        path = url.sub(%r{\Asqlite://?}, "")
        url.start_with?("sqlite:") && !path.empty? ? "The database file #{path}" : "The database #{url}"
      end

      def now = Time.now.to_i
    end
  end
end
