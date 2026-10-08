# frozen_string_literal: true

require "ed25519"
require "fileutils"
require "json"
require_relative "canonical"
require_relative "keys"
require_relative "record"
require_relative "rules"

module Agnostic
  # This server's own account, which signs its heartbeats.
  #
  # Generated on first boot: a fresh Ed25519 key, written 0600 into the data
  # directory, and a first identity declaration acknowledging the genesis. The
  # key is random rather than derived from a seed phrase because nobody types
  # it -- it belongs to this machine, and losing it means declaring a new
  # account, not recovering this one.
  class HostAccount
    KEY_FILE = "host.key"
    DECLARATION_FILE = "host.json"

    attr_reader :declaration, :signing_key

    def self.load_or_create(dir:, genesis:, handle:, bio:, clock: -> { Time.now.to_i })
      FileUtils.mkdir_p(dir)
      key = read_or_create_key(File.join(dir, KEY_FILE))
      path = File.join(dir, DECLARATION_FILE)
      declaration = if File.exist?(path)
                      Record.from_wire(JSON.parse(File.read(path)))
                    else
                      declare(key, genesis: genesis, handle: handle, bio: bio, ts: clock.call).tap do |record|
                        File.write(path, JSON.pretty_generate(record.to_wire))
                      end
                    end
      new(signing_key: key, declaration: declaration)
    end

    def self.read_or_create_key(path)
      if File.exist?(path)
        raw = Keys.decode(File.read(path).strip, Keys::KEY_BYTES)
        raise "#{path} does not hold a 32-byte base64url key" unless raw

        return Ed25519::SigningKey.new(raw)
      end

      key = Ed25519::SigningKey.generate
      # Created 0600 before anything is written to it, so the key is never
      # briefly readable by anyone else on the machine.
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.puts(Keys.encode(key.to_bytes)) }
      key
    end

    def self.declare(key, genesis:, handle:, bio:, ts:)
      sign(key, {
             "ack" => [genesis.digest], "body" => bio, "pubkey" => Keys.public_key(key),
             "title" => handle, "ts" => ts, "type" => "reputablechat:identity:#{Rules::VERSION}"
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

      raise "the account declaration in the data directory was not made with the key beside it"
    end

    def id = declaration.digest

    def pubkey = Keys.public_key(signing_key)

    # A record of this account, with its id, key and type filled in.
    def sign(kind, fields)
      HostAccount.sign(signing_key, fields.merge(
                                  "id" => id, "pubkey" => pubkey, "type" => "reputablechat:#{kind}:#{Rules::VERSION}"
                                ))
    end

    def to_h = { "id" => id, "pubkey" => pubkey, "declaration" => declaration.to_wire }
  end
end
