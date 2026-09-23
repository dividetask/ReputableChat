# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "reputable_chat/app"
require "reputable_chat/environment"
require "reputable_chat/host"
require "reputable_chat/operator"
require "json"
require "tmpdir"

# The host account: this server's own, optional, hanging off the one chain.
class HostSpec < Minitest::Test
  include Rack::Test::Methods

  Environment = ReputableChat::Environment
  Host        = ReputableChat::Host
  Genesis     = ReputableChat::Genesis
  Operator    = ReputableChat::Operator

  def setup
    @rack_env = ENV.fetch("RACK_ENV", nil)
    @genesis = GenesisFixture.build
    Host.reset!
  end

  def teardown
    ENV["RACK_ENV"] = @rack_env
    ReputableChat::App.host = nil
    Host.reset!
    Genesis.reset!
  end

  def app = ReputableChat::App.app

  # RULE: a host account acknowledges the genesis. Its declaration is the link
  # that keeps a server's own account on the network's one chain rather than
  # the bottom of a second.
  def test_a_host_account_acknowledges_the_genesis
    host = GenesisFixture.build_host(genesis: @genesis)

    assert_equal @genesis.hash, host.declaration["ack"]
  end

  def test_a_host_account_acknowledging_anything_else_is_refused
    other = GenesisFixture.build
    record = GenesisFixture.host_record(genesis: @genesis, ack: other.hash)

    error = assert_raises(Host::Corrupt) { Host.new(record, genesis: @genesis) }
    assert_match(/not the genesis/, error.message)
  end

  def test_a_host_account_acknowledging_nothing_is_refused
    record = GenesisFixture.host_record(genesis: @genesis, ack: nil)

    assert_raises(Host::Corrupt) { Host.new(record, genesis: @genesis) }
  end

  # RULE: a host account is checked like the genesis: a record edited after
  # signing is refused rather than served.
  def test_an_edited_host_account_is_refused
    record = GenesisFixture.host_record(genesis: @genesis)
    record["payload"] = record["payload"].sub("\"Host\"", "\"Hosts\"")

    assert_raises(Host::Corrupt) { Host.new(record, genesis: @genesis) }
  end

  # RULE: the genesis is the only record that acknowledges nothing.
  def test_a_genesis_that_acknowledges_something_is_refused
    record = GenesisFixture.host_record(genesis: @genesis)

    assert_raises(Genesis::Corrupt) { Genesis.new(record) }
  end

  # RULE: having a host account is a choice. A server without one runs, and
  # says so rather than failing.
  def test_a_server_without_a_host_account_serves_null
    ReputableChat::App.genesis = @genesis
    ReputableChat::App.host = nil
    get "/api/host"

    assert_equal 200, last_response.status
    assert_nil JSON.parse(last_response.body).fetch("host")
  end

  def test_a_server_with_a_host_account_serves_it
    host = GenesisFixture.build_host(genesis: @genesis)
    ReputableChat::App.genesis = @genesis
    ReputableChat::App.host = host
    get "/api/host"

    assert_equal host.hash, JSON.parse(last_response.body).fetch("host").fetch("hash")
  end

  # RULE: production refuses the development host account, compared by key,
  # for the same reason it refuses the development genesis: its seed is
  # committed, so everyone who has cloned the repository could sign as it.
  def test_production_refuses_the_development_host_account
    development = JSON.parse(File.read(Host.path(Environment::DEVELOPMENT)))
    genesis = Genesis.load(path: Genesis.path(Environment::DEVELOPMENT))
    ENV["RACK_ENV"] = Environment::PRODUCTION

    error = assert_raises(Host::WrongEnvironment) do
      Host.refuse_development_in_production(Host.new(development, genesis: genesis))
    end
    assert_match(/public/, error.message)
  end

  def test_production_accepts_a_host_account_that_is_not_developments
    ENV["RACK_ENV"] = Environment::PRODUCTION
    own = GenesisFixture.build_host(genesis: @genesis)

    assert_equal own, Host.refuse_development_in_production(own)
  end

  # RULE: the committed development host account hangs off the committed
  # development genesis. If either is regenerated without the other, the
  # server refuses to boot, and this says why first.
  def test_the_committed_development_host_account_acknowledges_the_development_genesis
    genesis = Genesis.load(path: Genesis.path(Environment::DEVELOPMENT))
    host = Host.load(path: Host.path(Environment::DEVELOPMENT), genesis: genesis)

    assert_equal genesis.hash, host.declaration["ack"]
    refute_equal genesis.pubkey, host.pubkey
  end

  # RULE: every seed but development's is kept out of git, the host account's
  # as well as the genesis account's. Development's two are public on purpose.
  def test_only_development_seeds_are_committed
    %i[genesis host].each do |account|
      production = Operator.path_for(Environment::PRODUCTION, account: account)
      development = Operator.path_for(Environment::DEVELOPMENT, account: account)

      assert ignored?(production), "#{account}'s production seed must be gitignored"
      refute ignored?(development), "#{account}'s development seed is committed on purpose"
    end
  end

  def ignored?(path)
    system("git", "check-ignore", "-q", path, chdir: File.expand_path("..", __dir__))
  end
end
