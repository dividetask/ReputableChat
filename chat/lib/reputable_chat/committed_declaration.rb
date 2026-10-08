# frozen_string_literal: true

require "json"
require_relative "environment"
require_relative "chain/envelope"
require_relative "cryptography/signature"

module ReputableChat
  # An identity declaration committed to the repository as a file, rather than
  # published through the API and kept in the database.
  #
  # There are two: the genesis account's, which is the bottom of the chain, and
  # the host account's, which is this server's own. Both are read before any
  # client has fetched anything -- a first friend you have to download from the
  # server you are deciding whether to trust is no anchor at all -- so both are
  # files, and both carry the same checks.
  #
  # An including class supplies DIRECTORY, the Missing/Corrupt/WrongEnvironment
  # errors, `self.label` for messages, and `check_ack!`.
  module CommittedDeclaration
    def self.included(base) = base.extend(ClassMethods)

    module ClassMethods
      # Named for the environment rather than for the handle, so which one is
      # loaded is obvious from the filename.
      def path(environment = Environment.name) = File.join(self::DIRECTORY, "#{environment}.json")

      # The avatar, committed beside the record. The image store lives under
      # data/, which is not in the repository, and the declaration naming the
      # image is read before any client has uploaded anything -- so the bytes
      # are committed too, and the server adopts them at boot.
      def icon_path(environment = Environment.name)
        Dir[File.join(self::DIRECTORY, "#{environment}.{png,jpg,gif,webp}")].first
      end

      def read_record(path)
        raise self::Missing, missing_message(path) unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise self::Corrupt, "#{path} is not valid JSON: #{e.message}"
      end

      # The failure this exists to prevent: a production deployment running a
      # published development identity, which everyone who has cloned the
      # repository can sign as. Compared by key rather than by filename,
      # because the realistic mistake is copying the development record into
      # place, not misnaming it.
      def refuse_development_in_production(declaration, development_path: path(Environment::DEVELOPMENT))
        return declaration unless declaration && Environment.production?
        return declaration unless File.exist?(development_path)

        payload = JSON.parse(JSON.parse(File.read(development_path))["payload"].to_s)
        development = [payload["pubkey"], payload["mpubkey"]].compact
        return declaration if (development & declaration.keys).empty?

        raise self::WrongEnvironment, development_message
      rescue JSON::ParserError
        declaration
      end
    end

    attr_reader :record, :payload, :signature, :hash

    # The working key and the master key the declaration sets.
    def pubkey = record["pubkey"]
    def mpubkey = record["mpubkey"]
    def keys = [pubkey, mpubkey].compact

    # A first declaration's record hash is its account ID.
    def account = hash

    def declaration = record.fields

    # The avatar the declaration names, the first of its files, or nil.
    def icon = record["file"]&.first

    def handle = record["title"]

    def to_h = { "account" => account, "payload" => payload, "signature" => signature, "hash" => hash }

    # Puts the committed bytes into the image store, where every other image
    # lives, so there is one serving path rather than a special case.
    #
    # The store derives the name from the bytes, so a mismatch here means the
    # committed image is not the one the declaration was signed over -- which
    # would otherwise show up as a broken avatar and nothing else.
    def install_icon(images, path: self.class.icon_path)
      return nil unless icon && path && File.exist?(path)

      stored = images.store(File.binread(path))
      unless stored == icon
        raise self.class::Corrupt,
              "#{path} stores as #{stored.inspect} but the #{self.class.label} declares #{icon.inspect}"
      end

      stored
    end

    private

    def adopt(file, path)
      @payload   = file["payload"]
      @signature = file["signature"]
      @hash      = file["hash"]

      verify!(path)
    end

    # Checked on every load rather than trusted. A record that has been edited
    # by hand, or truncated by a bad merge, would otherwise put every client on
    # a slightly different chain and show up only as signatures failing for no
    # visible reason.
    def verify!(path)
      %w[payload signature hash].each do |field|
        raise self.class::Corrupt, "#{path} is missing #{field}" if send(field).to_s.empty?
      end

      begin
        @record = Chain::Envelope.parse(payload, signature)
      rescue Chain::Envelope::Unreadable => e
        raise self.class::Corrupt, "#{path} is not a record: #{e.message}"
      end

      unless record.first_declaration? && record.kind == "identity"
        raise self.class::Corrupt, "#{path} is not a first identity declaration"
      end
      unless record.record_hash == hash
        raise self.class::Corrupt, "#{path} records hash #{hash} but its contents hash to #{record.record_hash}"
      end
      unless Cryptography::Signature.verify(pubkey_b64: record["pubkey"], signature_b64: signature, payload: record.fields)
        raise self.class::Corrupt, "the signature on #{path} does not verify against its working key"
      end

      # Whether it is valid under the rules is the agnostic server's to say;
      # the chat checks at boot that it is the genesis that server runs.
      check_ack!(path)
    end
  end
end
