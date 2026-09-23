# frozen_string_literal: true

require "json"
require_relative "environment"
require_relative "cryptography/payload"
require_relative "cryptography/record"
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

        development = JSON.parse(File.read(development_path))["pubkey"]
        return declaration unless development == declaration.pubkey

        raise self::WrongEnvironment, development_message
      rescue JSON::ParserError
        declaration
      end
    end

    attr_reader :pubkey, :payload, :signature, :hash

    def declaration = @declaration ||= JSON.parse(payload)

    # The icon filename the declaration names, or nil.
    def icon = declaration["icon"]

    def handle = declaration["handle"]

    def to_h = { "pubkey" => pubkey, "payload" => payload, "signature" => signature, "hash" => hash }

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

    def adopt(record, path)
      @pubkey    = record["pubkey"]
      @payload   = record["payload"]
      @signature = record["signature"]
      @hash      = record["hash"]

      verify!(path)
    end

    # Checked on every load rather than trusted. A record that has been edited
    # by hand, or truncated by a bad merge, would otherwise put every client on
    # a slightly different chain and show up only as signatures failing for no
    # visible reason.
    def verify!(path)
      %w[pubkey payload signature hash].each do |field|
        raise self.class::Corrupt, "#{path} is missing #{field}" if send(field).to_s.empty?
      end

      shape!(path)
      check_ack!(path)

      recomputed = Cryptography::Record.digest(payload: payload, signature: signature)
      unless recomputed == hash
        raise self.class::Corrupt, "#{path} records hash #{hash} but its contents hash to #{recomputed}"
      end

      return if Cryptography::Signature.verify(
        pubkey_b64: pubkey, signature_b64: signature, payload: JSON.parse(payload)
      )

      raise self.class::Corrupt, "the signature on #{path} does not verify against #{pubkey}"
    end

    # A record written against an older payload shape still verifies -- its
    # signature covers the bytes it was made from. It is still wrong: a reader
    # looking for a field it does not carry would find nil and carry on.
    def shape!(path)
      unless declaration["purpose"] == Cryptography::Payload::IDENTITY
        raise self.class::Corrupt, "#{path} is not a #{Cryptography::Payload::IDENTITY} record"
      end

      expected = Cryptography::Payload.identity(
        pubkey: pubkey, revision: 1, handle: "x", bio: "", icon: nil, ack: nil, issued_at: 0
      ).keys.sort

      missing = expected - declaration.keys
      return if missing.empty?

      raise self.class::Corrupt, "#{path} was written against an older payload shape and is " \
                                 "missing #{missing.join(', ')}"
    end
  end
end
