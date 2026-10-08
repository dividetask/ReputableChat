# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "reputable_chat/chain/service"

# A chat server announcing itself to the others (Chain::Service), on the
# chain its agnostic server holds.
class ServiceSpec < Minitest::Test
  Service = ReputableChat::Chain::Service

  def setup
    @app = ChainServer.wire
    @host = @app.host
  end

  def announce(url) = Service.announce!(chain: @app.chain, mirror: @app.mirror, host: @host, url: url)

  def current = @app.mirror.services[@host.account]

  # RULE (yours): announced only when the address changes, and on the first
  # start. These run in order on one chain, so each starts from what the last
  # left behind.
  def test_an_announcement_is_published_when_the_address_changes_and_only_then
    first = "http://chat-#{rand(1_000_000)}.test"
    assert_equal first, announce(first)
    assert_equal first, current

    assert_equal :unchanged, announce(first), "an unchanged address is not announced again"

    second = "#{first}/moved"
    assert_equal second, announce(second)
    assert_equal second, current

    assert_nil announce(nil), "an address removed is withdrawn"
    assert @app.mirror.services.key?(@host.account)
    assert_nil current
  end

  # RULE (yours): what makes an account a chat server is the service notice
  # typed for the chat, which the chat client never signs and the chat server
  # does not take from its clients.
  def test_an_announcement_is_a_chat_typed_service_notice
    announce("http://chat-#{rand(1_000_000)}.test")
    row = @app.store.records_of(@host.account, kind: "notice", limit: 1).first
    envelope = ReputableChat::Chain::Envelope.parse(row[:payload], row[:signature])

    assert envelope.service?
    assert_equal "reputablechat:notice:v0.001:chat", envelope["type"]
  end
end
