# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "canonical"
require_relative "keys"
require_relative "record"
require_relative "rules"
require_relative "seed"

module Agnostic
  # This server's own account, which signs its heartbeats.
  #
  # Made on first boot from two new seed phrases, each written 0600 into the
  # data directory: the working phrase, which the server keeps and signs with,
  # and the master phrase, whose key the declaration names as mpubkey and which
  # the server never reads again. The master phrase belongs off the server:
  # whoever holds it can move the account to a new working key if this
  # machine's is ever taken, and that only helps if it was not taken with it.
  #
  # Both are phrases rather than raw keys, derived the browser's way, so either
  # can be typed into a client to act as this account.
  class HostAccount
    SEED_FILE = "host.seed"
    MASTER_FILE = "host-master.seed"
    DECLARATION_FILE = "host.json"

    class MissingSeed < StandardError; end

    attr_reader :declaration, :signing_key

    def self.load_or_create(dir:, genesis:, handle:, bio:, clock: -> { Time.now.to_i })
      FileUtils.mkdir_p(dir)
      seed = File.join(dir, SEED_FILE)
      path = File.join(dir, DECLARATION_FILE)
      return new(signing_key: Seed.signing_key(read_seed(seed)), declaration: read(path)) if File.exist?(path)

      key = Seed.signing_key(write_seed(seed, Seed.generate))
      master = File.join(dir, MASTER_FILE)
      master_key = Seed.signing_key(write_seed(master, Seed.generate))
      warn "host account master phrase written to #{master}: move it off this server"
      declaration = declare(key, master_key, genesis: genesis, handle: handle, bio: bio, ts: clock.call)
      File.write(path, JSON.pretty_generate(declaration.to_wire))
      new(signing_key: key, declaration: declaration)
    end

    def self.read(path) = Record.from_wire(JSON.parse(File.read(path)))

    def self.read_seed(path)
      raise MissingSeed, "#{path} is missing, and the host account cannot sign without it" unless File.exist?(path)

      File.read(path)
    end

    # Created 0600 before anything is written to it, so a phrase is never
    # briefly readable by anyone else on the machine, and never over one that
    # is already there.
    def self.write_seed(path, phrase)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.puts(phrase) }
      phrase
    end

    def self.declare(key, master_key, genesis:, handle:, bio:, ts:)
      sign(key, {
             "ack" => [genesis.digest], "body" => bio, "mpubkey" => Keys.public_key(master_key),
             "pubkey" => Keys.public_key(key), "title" => handle, "ts" => ts,
             "type" => "reputablechat:identity:#{Rules::VERSION}"
           })
    end

    def self.sign(key, fields)
      payload = Canonical.dump(fields)
      Record.new(payload: payload, signature: Keys.sign(key, payload))
    end

    def initialize(signing_key:, declaration:)
      @signing_key = signing_key
      @declaration = declaration
      return if declaration["pubkey"] == pubkey

      raise "the host account declaration in the data directory was not made with the phrase beside it"
    end

    def id = declaration.digest

    def pubkey = Keys.public_key(signing_key)

    # A record of this account, with its id, key and type filled in.
    def sign(kind, fields)
      HostAccount.sign(signing_key, fields.merge(
                                  "id" => id, "pubkey" => pubkey, "type" => "reputablechat:#{kind}:#{Rules::VERSION}"
                                ))
    end

    def to_h = { "id" => id, "pubkey" => pubkey, "mpubkey" => declaration["mpubkey"], "declaration" => declaration.to_wire }
  end
end
