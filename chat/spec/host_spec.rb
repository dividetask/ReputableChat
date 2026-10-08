# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "rack/test"
require "tmpdir"
require "reputable_chat/app"
require "reputable_chat/environment"
require "reputable_chat/host"
require "reputable_chat/operator"

# The host account: every chat server has one, and it is the agnostic
# server's beside it -- one account per server, whatever it runs.
class HostSpec < Minitest::Test
  include Rack::Test::Methods

  Host     = ReputableChat::Host
  Operator = ReputableChat::Operator

  def app = ReputableChat::App.app

  def chain = ReputableChat::ChainClient.new(ChainServer.url)

  # RULE (yours): the chat and its agnostic server share an account.
  def test_the_chat_signs_as_its_agnostic_servers_host_account
    host = ChainServer.host

    assert_equal chain.host["id"], host.account
    assert_equal chain.host["pubkey"], host.pubkey
  end

  # RULE: a seed that is not the agnostic server's is refused at boot, and the
  # refusal says what to point where.
  def test_a_seed_that_is_not_the_agnostic_servers_is_refused
    error = assert_raises(Host::Mismatch) { Host.join(chain, seed_path: Operator.path_for("development")) }

    assert_match(/point host_seed at that server's host.seed/, error.message)
  end

  def test_a_missing_seed_says_where_it_comes_from
    error = assert_raises(Host::Missing) { Host.join(chain, seed_path: File.join(Dir.tmpdir, "nothing.seed")) }

    assert_match(/agnostic server writes it on its first boot/, error.message)
  end

  # RULE: the host account is served beside the genesis, so a new account can
  # start with both as friends before it has fetched anything else.
  def test_the_host_account_is_served
    ChainServer.wire
    get "/api/host"
    served = JSON.parse(last_response.body).fetch("host")

    assert_equal ChainServer.host.account, served["account"]
    assert_equal ChainServer.host.payload, served["payload"]
  end

  # RULE: every seed but development's is kept out of git, master keys'
  # as well as working keys'. Development's are public on purpose.
  def test_only_development_seeds_are_committed
    production = Operator.path_for(ReputableChat::Environment::PRODUCTION)
    development = Operator.path_for(ReputableChat::Environment::DEVELOPMENT)

    [production, production.sub(/\.seed\z/, ".master.seed")].each do |path|
      assert ignored?(path), "#{path} must be gitignored"
    end
    [development, development.sub(/\.seed\z/, ".master.seed")].each do |path|
      refute ignored?(path), "#{path} is committed on purpose"
    end
  end

  def ignored?(path)
    system("git", "check-ignore", "-q", path, chdir: File.expand_path("..", __dir__))
  end
end
