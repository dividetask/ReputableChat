# frozen_string_literal: true

require "json"
require_relative "operator"
require_relative "cryptography/canonical"

module ReputableChat
  # The host account: this server's own. Every chat server has one, and it is
  # the same account as the agnostic server's beside it -- one account per
  # server, whatever apps it runs. The agnostic server makes it on first boot
  # and keeps its working seed outside both apps (host/ at the root of the
  # repository); the chat reads that seed (host_seed in config/server.yml) to
  # sign as it, and refuses to run if the seed's key is
  # not the account the agnostic server names.
  #
  # A new account starts with it as a friend, beside the genesis account, and
  # it is what the chat announces itself with (Chain::Service).
  class Host
    class Missing < StandardError; end
    class Mismatch < StandardError; end

    attr_reader :account, :pubkey, :payload, :signature, :hash, :declaration

    def self.join(chain, seed_path:)
      unless File.exist?(seed_path)
        raise Missing, "no host seed at #{seed_path}. The agnostic server writes it on its first boot; " \
                       "start that first, or point host_seed (HOST_SEED) at its data directory."
      end

      keys = Operator.derive(Operator.seed_phrase(path: seed_path))
      theirs = chain.host
      unless keys["pubkey"] == theirs["pubkey"]
        raise Mismatch, "the seed at #{seed_path} derives #{keys['pubkey']}, but the agnostic server at " \
                        "#{chain.url} signs as #{theirs['pubkey']}. A chat server shares its agnostic " \
                        "server's account: point host_seed at that server's host.seed."
      end

      new(theirs, private_key: keys["private_key"])
    end

    # `wire` is the agnostic server's GET /api/host: its id, its working key,
    # and its current identity declaration.
    def initialize(wire, private_key: nil)
      @account = wire.fetch("id")
      @pubkey = wire.fetch("pubkey")
      record = wire.fetch("declaration")
      @payload = record.fetch("payload")
      @signature = record.fetch("signature")
      @hash = record.fetch("hash")
      @declaration = JSON.parse(@payload)
      @private_key = private_key
    end

    def handle = declaration["title"]
    def icon = declaration["file"]&.first

    # What a client is given: the account and its declaration, enough to show
    # it as a default friend before anything else is fetched.
    def to_h = { "account" => account, "payload" => payload, "signature" => signature, "hash" => hash }

    # A report for the agnostic server that this app did or did not reach
    # another server's account: [payload, signature]. Not a record; it never
    # leaves this machine.
    def contact_report(account, reached:, at: Time.now.to_i)
      sign({ "purpose" => "reputablechat:contact:v1", "account" => account, "reached" => reached, "ts" => at.to_i })
    end

    # Signs a payload as the host account: [canonical payload, signature].
    def sign(payload)
      raise Missing, "this host account was loaded without its seed and cannot sign" unless @private_key

      canonical = Cryptography::Canonical.dump(payload)
      [canonical, Operator.sign(@private_key, canonical)]
    end
  end
end
