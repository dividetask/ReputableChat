# frozen_string_literal: true

require "sequel"
require "fileutils"
require "json"
require "securerandom"

module ReputableChat
  module Store
    # Persistence. Signed blobs in, signed blobs out. Of a config the server reads
    # only the pubkey and revision -- enough to verify and reject a rollback.
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
          Integer  :revision, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :updated_at, null: false
        end

        # Served only to its owner. The read path takes no pubkey at all -- it
        # uses the session's -- so asking for someone else's is not expressible.
        @db.create_table?(:private_configs) do
          String   :pubkey, primary_key: true
          Integer  :revision, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :updated_at, null: false
        end

        # `hash` is the record hash -- what everything else on the chain names
        # this message by. Unique because a repeat means the identical record
        # arrived twice, not that two records collided.
        # An identity declaration and an attestation: who somebody is, and what
        # they think of everyone else. Both replace
        # halves of the old config blob, and both are revisioned for the same
        # reason it was: without a monotonic counter inside the signature, the
        # server could serve an old copy to hide something and the signature on
        # it would still verify perfectly.
        %i[identities attestations].each do |table|
          @db.create_table?(table) do
            String   :pubkey, primary_key: true
            Integer  :revision, null: false
            String   :hash, null: false
            String   :payload, text: true, null: false
            String   :signature, null: false
            Integer  :updated_at, null: false
          end
        end

        # Notices accumulate rather than replace: a correction is a new record
        # pointing at the old one, and what was said stays on the chain to be
        # checked. Unique on publisher and revision so a number cannot be
        # reused to slip a second statement in behind the first.
        @db.create_table?(:notices) do
          primary_key :id
          String   :hash, null: false, unique: true
          String   :publisher, null: false, index: true
          Integer  :revision, null: false
          String   :kind, null: false, index: true
          String   :title, null: false
          String   :supersedes
          String   :ack, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
          unique %i[publisher revision]
        end

        # One change to an attestation between republishes. Unique on the run
        # it belongs to and its place in that run, so a replay of an earlier
        # adjustment against a later snapshot cannot take hold.
        @db.create_table?(:adjustments) do
          primary_key :id
          String   :hash, null: false, unique: true
          String   :pubkey, null: false, index: true
          Integer  :base_revision, null: false
          Integer  :seq, null: false
          String   :target, null: false
          String   :ack, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
          unique %i[pubkey base_revision seq]
        end

        @db.create_table?(:messages) do
          primary_key :id
          String   :hash, null: false, unique: true
          String   :author, null: false, index: true
          String   :room, null: false, index: true
          Integer  :seq, null: false
          String   :prev
          String   :reply_to
          String   :ack, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
          unique %i[author seq]
        end

        # One reaction per person per message, enforced here rather than
        # trusted from the client.
        @db.create_table?(:emotes) do
          primary_key :id
          String   :hash, null: false, unique: true
          String   :author, null: false
          String   :room, null: false, index: true
          String   :message, null: false, index: true
          String   :emote, null: false
          String   :ack, null: false
          String   :payload, text: true, null: false
          String   :signature, null: false
          Integer  :received_at, null: false
          unique %i[author message]
        end

        # create_table? leaves an existing table alone, so a database made
        # before a column existed needs it adding explicitly.
        add_missing(:messages, reply_to: String, ack: String, hash: String)
        add_missing(:emotes, ack: String, hash: String)

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

      # Rejects a stale revision. Without this the server could serve an old
      # copy of someone's config to hide a report, and the signature on it
      # would still verify perfectly.
      def store_config(pubkey:, revision:, payload:, signature:)
        existing = config_blob(pubkey)
        return :stale if existing && revision <= existing[:revision]

        row = { pubkey: pubkey, revision: revision, payload: payload,
                signature: signature, updated_at: now }

        if existing
          @db[:configs].where(pubkey: pubkey).update(row)
        else
          @db[:configs].insert(row)
        end
        :ok
      end

      # --- identity declarations and attestations -------------------------------
      #
      # Same shape and same rules, so one pair of methods serves both rather
      # than two copies that can drift apart.

      def identity(pubkey) = revisioned(:identities, pubkey)
      def identities(pubkeys) = revisioned_batch(:identities, pubkeys)
      def attestation(pubkey) = revisioned(:attestations, pubkey)
      def attestations(pubkeys) = revisioned_batch(:attestations, pubkeys)

      def store_identity(**row) = store_revisioned(:identities, **row)
      def store_attestation(**row) = store_revisioned(:attestations, **row)

      def revisioned(table, pubkey) = @db[table].where(pubkey: pubkey).first

      def revisioned_batch(table, pubkeys)
        @db[table].where(pubkey: pubkeys.first(MAX_BATCH)).all
      end

      # Rejects a stale revision, exactly as a config does.
      def store_revisioned(table, pubkey:, revision:, hash:, payload:, signature:)
        existing = revisioned(table, pubkey)
        return :stale if existing && revision <= existing[:revision]

        row = { pubkey: pubkey, revision: revision, hash: hash, payload: payload,
                signature: signature, updated_at: now }

        existing ? @db[table].where(pubkey: pubkey).update(row) : @db[table].insert(row)
        :ok
      end

      # --- notices --------------------------------------------------------------

      def store_notice(hash:, publisher:, revision:, kind:, title:, supersedes:, ack:,
                       payload:, signature:)
        @db[:notices].insert(
          hash: hash, publisher: publisher, revision: revision, kind: kind, title: title,
          supersedes: supersedes, ack: ack, payload: payload, signature: signature,
          received_at: now
        )
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      # Newest first: a reader wants what is current, and walks back through
      # `supersedes` from there if they want to know what it replaced.
      def notices(publisher, limit: 100)
        @db[:notices].where(publisher: publisher)
                     .order(Sequel.desc(:revision)).limit(limit).all
      end

      def notice(hash) = @db[:notices].where(hash: hash).first

      def latest_notice_revision(publisher)
        @db[:notices].where(publisher: publisher).max(:revision).to_i
      end

      # --- adjustments ---------------------------------------------------------

      def store_adjustment(hash:, pubkey:, base_revision:, seq:, target:, ack:, payload:, signature:)
        @db[:adjustments].insert(
          hash: hash, pubkey: pubkey, base_revision: base_revision, seq: seq,
          target: target, ack: ack, payload: payload, signature: signature, received_at: now
        )
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      # Only the run that amends the attestation the caller actually holds.
      # An adjustment against an older snapshot has already been superseded by
      # the republish that followed it.
      def adjustments_for(pubkey, base_revision:, limit: 1_000)
        @db[:adjustments]
          .where(pubkey: pubkey, base_revision: base_revision)
          .order(:seq).limit(limit).all
      end

      # --- emotes -------------------------------------------------------------

      def store_emote(hash:, author:, room:, message:, emote:, ack:, payload:, signature:)
        @db[:emotes].insert(
          hash: hash, author: author, room: room, message: message, emote: emote,
          ack: ack, payload: payload, signature: signature, received_at: now
        )
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      def room_emotes(room, limit: 5_000)
        @db[:emotes].where(room: room).order(:id).limit(limit)
                    .select(:author, :message, :emote).all
      end

      # --- private configs ---------------------------------------------------

      def private_config(pubkey) = @db[:private_configs].where(pubkey: pubkey).first

      def store_private_config(pubkey:, revision:, payload:, signature:)
        existing = private_config(pubkey)
        return :stale if existing && revision <= existing[:revision]

        row = { pubkey: pubkey, revision: revision, payload: payload,
                signature: signature, updated_at: now }

        if existing
          @db[:private_configs].where(pubkey: pubkey).update(row)
        else
          @db[:private_configs].insert(row)
        end
        :ok
      end

      # --- messages ---------------------------------------------------------

      def last_message_for(author)
        @db[:messages].where(author: author).order(Sequel.desc(:seq)).first
      end

      def store_message(hash:, author:, room:, seq:, prev:, ack:, payload:, signature:, reply_to: nil)
        @db[:messages].insert(
          hash: hash, author: author, room: room, seq: seq, prev: prev, ack: ack,
          reply_to: reply_to, payload: payload, signature: signature, received_at: now
        )
        :ok
      rescue Sequel::UniqueConstraintViolation
        :duplicate
      end

      def message_by_hash(hash) = @db[:messages].where(hash: hash).first

      def room_messages(room, limit: 100)
        @db[:messages].where(room: room).order(Sequel.desc(:id)).limit(limit).reverse.all
      end

      # Adds only the columns a table is actually missing, so an existing
      # database migrates forward without a separate migration framework.
      def add_missing(table, columns)
        existing = @db[table].columns
        columns.each do |name, type|
          next if existing.include?(name)

          @db.alter_table(table) { add_column name, type }
        end
      end

      def now = Time.now.to_i
    end
  end
end
