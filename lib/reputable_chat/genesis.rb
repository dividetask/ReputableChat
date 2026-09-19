# frozen_string_literal: true

require "json"
require_relative "cryptography/record"
require_relative "cryptography/signature"

module ReputableChat
  # The bottom of the chain: Tim's user record.
  #
  # Every record that has seen nothing else acknowledges this one, and it is the
  # only record whose own `ack` is null. It is also the only record stored as a
  # file rather than regenerated from a database row, because every client has
  # to agree on the hash before it has fetched anything -- a genesis you have to
  # download from the server is not a genesis.
  #
  # Generated once by script/generate_genesis.rb and committed.
  class Genesis
    PATH = File.expand_path("../../config/genesis/tim.json", __dir__)

    class Missing < StandardError; end
    class Corrupt < StandardError; end

    attr_reader :pubkey, :payload, :signature, :hash

    def self.load(path: PATH)
      raise Missing, missing_message(path) unless File.exist?(path)

      new(JSON.parse(File.read(path)), path: path)
    rescue JSON::ParserError => e
      raise Corrupt, "#{path} is not valid JSON: #{e.message}"
    end

    # Memoized, since it never changes while a process is running.
    def self.current = @current ||= load

    def self.reset! = @current = nil

    def self.missing_message(path)
      "no genesis record at #{path}. Generate one with `bundle exec rake genesis` " \
        "and commit it -- nothing can be acknowledged until it exists."
    end

    def initialize(record, path: PATH)
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

      recomputed = Cryptography::Record.digest(payload: payload, signature: signature)
      unless recomputed == hash
        raise Corrupt, "#{path} records hash #{hash} but its contents hash to #{recomputed}"
      end

      return if Cryptography::Signature.verify(
        pubkey_b64: pubkey, signature_b64: signature, payload: JSON.parse(payload)
      )

      raise Corrupt, "the signature on #{path} does not verify against #{pubkey}"
    end
  end
end
