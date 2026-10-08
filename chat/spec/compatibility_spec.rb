# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "reputable_chat/genesis"
require "reputable_chat/operator"

# What the chat must share with the agnostic server's branch, which owns
# ../server/: one genesis, one development genesis account, one way of turning
# a phrase into a key. A difference in any of them is two chains, or one
# phrase that is two accounts, and every signature still verifies.
class CompatibilitySpec < Minitest::Test
  SERVER = File.expand_path("../../server", __dir__)

  def server_genesis = JSON.parse(File.read(File.join(SERVER, "config/genesis/development.json")))

  # RULE: there is one chain, so the chat's genesis is the agnostic server's
  # record, byte for byte.
  def test_the_chats_development_genesis_is_the_agnostic_servers
    ours = JSON.parse(File.read(ReputableChat::Genesis.path("development")))

    %w[payload signature hash].each do |field|
      assert_equal server_genesis.fetch(field), ours.fetch(field),
                   "config/genesis/development.json differs from the agnostic server's in #{field}; " \
                   "regenerate the chat's to match ../server/config/genesis/development.json"
    end
  end

  # RULE: the development genesis account is one account, its public phrase
  # the same in both.
  def test_the_development_genesis_phrase_is_the_agnostic_servers
    ours = ReputableChat::Operator.seed_phrase(path: ReputableChat::Operator.path_for("development"))
    theirs = File.read(File.join(SERVER, "spec/fixtures/development-genesis.seed")).strip

    assert_equal theirs, ours
  end

  # RULE: a phrase is the same account in every app and in the agnostic
  # server: the chat derives from the server's phrase the key the server's
  # genesis declares.
  def test_the_chat_derives_the_key_the_agnostic_servers_genesis_declares
    phrase = File.read(File.join(SERVER, "spec/fixtures/development-genesis.seed"))
    declared = JSON.parse(server_genesis.fetch("payload")).fetch("pubkey")

    assert_equal declared, ReputableChat::Operator.derive(phrase.strip).fetch("pubkey")
  end
end
