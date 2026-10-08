# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__), File.expand_path("support", __dir__)

require "minitest/autorun"
require "digest"
require "ed25519"
require "agnostic/host_account"
require "agnostic/canonical"
require "agnostic/ingest"
require "agnostic/keys"
require "agnostic/record"
require "agnostic/rules"
require "agnostic/settings"
require "agnostic/store"
require "examples"

# A chain in memory, starting from the example genesis, with a clock the test
# controls.
module ChainHelpers
  EXAMPLE_GENESIS_TS = 1_790_200_000

  def setup_chain(settings: Agnostic::Settings.new({}, env: {}))
    @now = EXAMPLE_GENESIS_TS + 10_000
    @settings = settings
    @store = Agnostic::Store.new("sqlite:/")
    @genesis = Examples.records.first
    @rules = Agnostic::Rules.new(store: @store, genesis: @genesis)
    @store.insert(@genesis.tap { |g| @rules.check(g) })
    @ingest = Agnostic::Ingest.new(store: @store, rules: @rules, settings: settings, clock: -> { @now })
  end

  # The example chain, accepted in order.
  def load_examples
    Examples.records.drop(1).each { |r| @ingest.submit(r) }
  end

  def key(name) = Examples.signing_key(name)

  def pub(name) = Agnostic::Keys.public_key(key(name))

  def tim = @genesis.digest

  def version = Agnostic::Rules::VERSION

  def sign(signer, fields, field: "pubkey")
    fields = { "body" => "", "ts" => @now }.merge(fields)
    fields[field] ||= pub(signer)
    fields["type"] ||= "reputablechat:message:#{version}"
    Agnostic::HostAccount.sign(key(signer), fields)
  end

  # A record signed over an exact payload string, for payloads that are not
  # canonical on purpose.
  def sign_raw(signer, payload)
    Agnostic::Record.new(payload: payload, signature: Agnostic::Keys.sign(key(signer), payload))
  end

  def declare(name, ack: [tim], **extra)
    record = sign(name, { "ack" => ack, "title" => name.capitalize,
                          "type" => "reputablechat:identity:#{version}" }.merge(extra.transform_keys(&:to_s)))
    accept(record)
  end

  def post(name, account, ack:, **extra)
    sign(name, { "ack" => ack.sort, "id" => account }.merge(extra.transform_keys(&:to_s)))
  end

  def accept(record)
    result = @ingest.submit(record)
    assert_equal :accepted, result.status, "expected acceptance: #{result.problems.inspect} #{result.missing.inspect}"
    record
  end

  def refuse(record, pattern)
    result = @ingest.submit(record)
    assert_equal :refused, result.status, "expected refusal matching #{pattern.inspect}"
    assert(result.problems.any? { |p| p.match?(pattern) }, "problems were #{result.problems.inspect}")
    result
  end

  def problems(record) = @rules.check(record).problems

  def example(index) = Examples.records.fetch(index)
end
