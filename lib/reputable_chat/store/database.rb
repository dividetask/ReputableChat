# frozen_string_literal: true

require "sequel"
require "fileutils"
require "json"
require "securerandom"

module ReputableChat
  module Store
    # Persistence. Signed blobs in, signed blobs out. Of a config the server reads
    # only the pubkey and version -- enough to verify and reject a rollback.
    # Ratings are never parsed server-side.
    class Database
      IN_MEMORY       = ["sqlite:/", "sqlite::memory:"].freeze
      NONCE_TTL       = 300   # seconds a login challenge stays usable
      CLOCK_SKEW      = 120   # tolerated drift on a signed timestamp
      MAX_BODY_BYTES  = 8_192
      MAX_BATCH       = 256

      attr_reader :db

      def initialize(url)
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
        # Display name, bio and icon live in the signed config, not here, so
        # the server cannot alter them and the two cannot drift.
        @db.create_table?(:users) do
          String   :pubkey, primary_key: true
          Integer  :created_at, null: false
        end

        @db.create_table?(:configs) do
          String   :pubkey, primary_key: true
          Integer  :version, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :updated_at, null: false
        end

        @db.create_table?(:messages) do
          primary_key :id
          String   :author, null: false, index: true
          String   :room, null: false, index: true
          Integer  :seq, null: false
          String   :prev
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
          unique %i[author seq]
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

      # --- users ----------------------------------------------------------

      def user(pubkey) = @db[:users].where(pubkey: pubkey).first
      def registered?(pubkey) = !user(pubkey).nil?

      def register(pubkey)
        @db[:users].insert(pubkey: pubkey, created_at: now)
      end

      # --- configs ---------------------------------------------------------

      def config_blob(pubkey) = @db[:configs].where(pubkey: pubkey).first

      def config_blobs(pubkeys)
        @db[:configs].where(pubkey: pubkeys.first(MAX_BATCH)).all
      end

      # Rejects a stale version. Without this the server could serve an old
      # copy of someone's config to hide a report, and the signature on it
      # would still verify perfectly.
      def store_config(pubkey:, version:, payload:, signature:)
        existing = config_blob(pubkey)
        return :stale if existing && version <= existing[:version]

        row = { pubkey: pubkey, version: version, payload: payload,
                signature: signature, updated_at: now }

        if existing
          @db[:configs].where(pubkey: pubkey).update(row)
        else
          @db[:configs].insert(row)
        end
        :ok
      end

      # --- messages ---------------------------------------------------------

      def last_message_for(author)
        @db[:messages].where(author: author).order(Sequel.desc(:seq)).first
      end

      def store_message(author:, room:, seq:, prev:, payload:, signature:)
        @db[:messages].insert(
          author: author, room: room, seq: seq, prev: prev,
          payload: payload, signature: signature, received_at: now
        )
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      def room_messages(room, limit: 100)
        @db[:messages].where(room: room).order(Sequel.desc(:id)).limit(limit).reverse.all
      end

      def now = Time.now.to_i
    end
  end
end
