# frozen_string_literal: true

require "sequel"
require "json"
require "securerandom"

module ReputableChat
  module Store
    # Persistence.
    #
    # The server stores signed blobs and reads as little of them as it can. For
    # a config that is the pubkey and the version -- enough to verify the
    # signature and reject a rollback -- and nothing else. Ratings are never
    # parsed server-side; clients fetch the blob and do the reputation maths
    # themselves.
    class Database
      NONCE_TTL       = 300   # seconds a login challenge stays usable
      CLOCK_SKEW      = 120   # tolerated drift on a signed timestamp
      MAX_BODY_BYTES  = 8_192
      MAX_BATCH       = 256

      attr_reader :db

      def initialize(url)
        @db = Sequel.connect(url)
        migrate!
      end

      def migrate!
        @db.create_table?(:users) do
          String   :pubkey, primary_key: true
          String   :username, null: false
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

      def register(pubkey, username)
        @db[:users].insert(pubkey: pubkey, username: username, created_at: now)
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
