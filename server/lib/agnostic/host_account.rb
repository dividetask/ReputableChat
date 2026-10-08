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
  # Its two seed phrases are made on first boot, each written 0600 into the
  # data directory: the working phrase, which the server keeps and signs with,
  # and the master phrase, which the server never reads again and which
  # belongs off the server -- whoever holds it can move the account to a new
  # working key if this machine's is ever taken, and that only helps if it was
  # not taken with it. The master public key is kept beside them, so the
  # declaration can name it after the phrase has gone.
  #
  # The account is not declared then. A server publishes its first identity
  # declaration only when it goes live, once it has caught up with the chain,
  # so the declaration can acknowledge where the chain is rather than where it
  # began: a declaration acknowledging nothing newer than the genesis would be
  # left behind by any server with more than 256 heartbeats.
  #
  # Both are phrases rather than raw keys, derived the browser's way, so either
  # can be typed into a client to act as this account.
  class HostAccount
    SEED_FILE = "host.seed"
    MASTER_FILE = "host-master.seed"
    MASTER_PUBLIC_FILE = "host-master.pub"
    DECLARATION_FILE = "host.json"

    class MissingSeed < StandardError; end

    attr_reader :declaration, :signing_key, :master_pubkey

    def self.load_or_create(dir:, words: Seed::WORDS)
      FileUtils.mkdir_p(dir)
      seed = File.join(dir, SEED_FILE)
      declaration = File.join(dir, DECLARATION_FILE)
      master_public = File.join(dir, MASTER_PUBLIC_FILE)
      unless File.exist?(seed) || File.exist?(declaration)
        write_seed(seed, Seed.generate(words))
        master = File.join(dir, MASTER_FILE)
        master_key = Seed.signing_key(write_seed(master, Seed.generate(words)))
        File.write(master_public, "#{Keys.public_key(master_key)}\n")
        warn "host account master phrase written to #{master}: move it off this server"
      end
      new(dir: dir, signing_key: Seed.signing_key(read_seed(seed)),
          declaration: File.exist?(declaration) ? read(declaration) : nil,
          master_pubkey: File.exist?(master_public) ? File.read(master_public).strip : nil)
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

    # The first identity declaration, made when the server goes live.
    # profile: its title (the handle), body (the bio) and url.
    def declare!(ack:, profile:, ts:)
      fields = profile.merge("ack" => ack.sort, "pubkey" => pubkey, "ts" => ts,
                             "type" => "reputablechat:identity:#{Rules::VERSION}")
      fields["mpubkey"] = master_pubkey if master_pubkey
      @declaration = HostAccount.sign(signing_key, fields)
      File.write(File.join(@dir, DECLARATION_FILE), JSON.pretty_generate(@declaration.to_wire))
      @declaration
    end

    def declared? = !declaration.nil?

    def self.sign(key, fields)
      payload = Canonical.dump(fields)
      Record.new(payload: payload, signature: Keys.sign(key, payload))
    end

    def initialize(signing_key:, declaration:, dir: nil, master_pubkey: nil)
      @dir = dir
      @signing_key = signing_key
      @declaration = declaration
      @master_pubkey = master_pubkey
      return if declaration.nil? || declaration["pubkey"] == pubkey

      raise "the host account declaration in the data directory was not made with the phrase beside it"
    end

    def id = declaration&.digest

    def pubkey = Keys.public_key(signing_key)

    # A record of this account, with its id, key and type filled in.
    def sign(kind, fields)
      HostAccount.sign(signing_key, fields.merge(
                                  "id" => id, "pubkey" => pubkey, "type" => "reputablechat:#{kind}:#{Rules::VERSION}"
                                ))
    end

    def to_h = { "id" => id, "pubkey" => pubkey, "mpubkey" => declaration&.[]("mpubkey"), "declaration" => declaration&.to_wire }
  end
end
