# frozen_string_literal: true

require "json"
require_relative "environment"
require_relative "cryptography/payload"
require_relative "cryptography/record"
require_relative "cryptography/signature"

module ReputableChat
  # The bottom of the chain: Tim's identity declaration.
  #
  # Every record that has seen nothing else acknowledges this one, and it is the
  # only record whose own `ack` is null. It is also the only record stored as a
  # file rather than regenerated from a database row, because every client has
  # to agree on the hash before it has fetched anything -- a genesis you have to
  # download from the server is not a genesis.
  #
  # Generated once by script/generate_genesis.rb and committed.
  #
  # There are two of them, because a developer needs to be able to sign as the
  # genesis account and a production operator needs nobody else to be able to.
  # Development's seed is committed and therefore public: anyone who has cloned
  # the repository owns that identity, which is exactly what makes a fresh
  # clone useful. Production's seed is never committed.
  class Genesis
    DIRECTORY = File.expand_path("../../config/genesis", __dir__)

    class Missing < StandardError; end
    class Corrupt < StandardError; end
    class WrongEnvironment < StandardError; end

    # Named for the environment rather than for the handle, so which one is
    # loaded is obvious from the filename rather than from remembering which
    # person's name meant which deployment.
    def self.path(environment = Environment.name)
      File.join(DIRECTORY, "#{environment}.json")
    end

    PATH = path(Environment::DEVELOPMENT)

    attr_reader :pubkey, :payload, :signature, :hash

    def self.load(path: self.path)
      raise Missing, missing_message(path) unless File.exist?(path)

      new(JSON.parse(File.read(path)), path: path)
    rescue JSON::ParserError => e
      raise Corrupt, "#{path} is not valid JSON: #{e.message}"
    end

    # Memoized, since it never changes while a process is running.
    def self.current = @current ||= refuse_development_in_production(load)

    # The failure this exists to prevent: a production deployment running the
    # published development identity, where every person who has cloned the
    # repository can sign releases and announcements as the genesis account.
    #
    # Checked by comparing keys rather than by trusting the filename, because
    # the realistic mistake is copying the development record into place, not
    # misnaming it.
    def self.refuse_development_in_production(genesis)
      return genesis unless Environment.production?

      development = begin
        load(path: path(Environment::DEVELOPMENT))
      rescue Missing, Corrupt
        nil
      end
      return genesis unless development && development.pubkey == genesis.pubkey

      raise WrongEnvironment,
            "this is the development genesis, whose seed is committed to the repository and " \
            "therefore public. Generate a production one with " \
            "`RACK_ENV=production bundle exec rake genesis` and keep its seed out of git."
    end

    def self.reset! = @current = nil

    def self.missing_message(path)
      "no genesis record at #{path}. Generate one with " \
        "`#{Environment.production? ? 'RACK_ENV=production ' : ''}bundle exec rake genesis` " \
        "and commit it -- nothing can be acknowledged until it exists."
    end

    def initialize(record, path: Genesis.path)
      @pubkey    = record["pubkey"]
      @payload   = record["payload"]
      @signature = record["signature"]
      @hash      = record["hash"]

      verify!(path)
    end

    def to_h = { "pubkey" => pubkey, "payload" => payload, "signature" => signature, "hash" => hash }

    private

    # Checked on every load rather than trusted. A genesis that has been edited
    # by hand, or truncated by a bad merge, would otherwise put every client on
    # a slightly different chain and show up only as signatures failing for no
    # visible reason.
    def verify!(path)
      %w[pubkey payload signature hash].each do |field|
        raise Corrupt, "#{path} is missing #{field}" if send(field).to_s.empty?
      end

      shape!(path)

      recomputed = Cryptography::Record.digest(payload: payload, signature: signature)
      unless recomputed == hash
        raise Corrupt, "#{path} records hash #{hash} but its contents hash to #{recomputed}"
      end

      return if Cryptography::Signature.verify(
        pubkey_b64: pubkey, signature_b64: signature, payload: JSON.parse(payload)
      )

      raise Corrupt, "the signature on #{path} does not verify against #{pubkey}"
    end

    # A genesis written against an older payload shape still verifies -- its
    # signature covers the bytes it was made from, and those have not changed.
    # It is still wrong: every record signed since has a different field list,
    # and a reader looking for a field this one does not carry would find nil
    # and carry on. Caught here rather than discovered downstream.
    def shape!(path)
      record = JSON.parse(payload)

      unless record["purpose"] == Cryptography::Payload::IDENTITY
        raise Corrupt, "#{path} is not a #{Cryptography::Payload::IDENTITY} record"
      end

      expected = Cryptography::Payload.identity(
        pubkey: pubkey, revision: 1, handle: "x", bio: "", icon: nil, ack: nil, issued_at: 0
      ).keys.sort

      missing = expected - record.keys
      return if missing.empty?

      raise Corrupt, "#{path} was written against an older payload shape and is missing " \
                     "#{missing.join(', ')}. Delete it and the seed beside it, then run " \
                     "`bundle exec rake genesis` again -- nothing has been published from it yet."
    end
  end
end
