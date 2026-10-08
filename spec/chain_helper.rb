# frozen_string_literal: true

require "ed25519"
require "reputable_chat/chain/ledger"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/signature"

# Accounts and records for the specs that build a chain by hand.
module ChainHelper
  Crypto  = ReputableChat::Cryptography
  Payload = Crypto::Payload
  Record  = ReputableChat::Chain::Record
  Invalid = ReputableChat::Chain::Invalid

  # An account under test: its keys, and its account ID once declared.
  class Account
    attr_accessor :id, :working, :master

    def initialize(master: true)
      @working = Ed25519::SigningKey.generate
      @master = master ? Ed25519::SigningKey.generate : nil
    end

    def pubkey = ChainHelper.key_of(working)
    def mpubkey = master && ChainHelper.key_of(master)
  end

  module_function

  def key_of(signing) = Crypto::Signature.encode(signing.verify_key.to_bytes)
  def new_key = Ed25519::SigningKey.generate

  # Signs a payload with `key` and parses it, as a server receiving it would.
  def signed(payload, key)
    canonical = Crypto::Canonical.dump(payload)
    Record.parse(canonical, Crypto::Signature.encode(key.sign(canonical.b)))
  end

  # A genesis record and its account, for a ledger built in memory.
  def genesis_account
    tim = Account.new
    record = signed(Payload.identity(pubkey: tim.pubkey, mpubkey: tim.mpubkey, handle: "Tim", ack: [],
                                     ts: 1_000, rules: "rules"), tim.working)
    tim.id = record.record_hash
    [tim, record]
  end

  # Declares `account`, acknowledging `ack`, and returns the declaration.
  def declare(ledger, account, ack:, handle: "someone", ts: 1_100, **extra)
    record = signed(Payload.identity(pubkey: account.pubkey, mpubkey: account.mpubkey, handle: handle,
                                     ack: ack, ts: ts, **extra), account.working)
    ledger.add(record)
    account.id = record.record_hash
    record
  end

  # Adds a record signed by `account`, with its working key unless `key` says.
  def publish(ledger, payload, key)
    record = signed(payload, key)
    ledger.add(record)
    record
  end
end
