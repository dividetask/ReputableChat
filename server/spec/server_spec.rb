# frozen_string_literal: true

require_relative "spec_helper"
require "servers"

# Booting: the genesis, this server's host account, and the settings.
class ServerSpec < Minitest::Test
  include Servers

  GENESIS = File.expand_path("../config/genesis/development.json", __dir__)
  RULES   = File.expand_path("../../docs/project/rules/v0.001.md", __dir__)

  def committed_genesis = Agnostic::Record.from_wire(JSON.parse(File.read(GENESIS)))

  # The rules file is the source; the genesis carries it, so the two cannot
  # disagree. Editing a published rules file is what this catches.
  def test_the_development_genesis_carries_the_rules_file_exactly
    assert_equal File.read(RULES, encoding: "UTF-8").strip, committed_genesis["rules"]
  end

  def test_the_development_genesis_is_valid_under_the_rules_it_carries
    store = Agnostic::Store.new("sqlite:/")
    verdict = Agnostic::Rules.new(store: store, genesis: committed_genesis).check(committed_genesis)
    assert verdict.valid?, verdict.problems.inspect
  end

  def test_production_refuses_a_genesis_the_development_key_signed
    dir = Dir.mktmpdir
    settings = Agnostic::Settings.new({ "data_dir" => dir, "genesis" => GENESIS }, env: { "RACK_ENV" => "production" })
    error = assert_raises(Agnostic::Server::BootError) { Agnostic::Server.new(settings: settings) }
    assert_match(/development genesis account/, error.message)
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_a_server_without_a_genesis_refuses_to_boot_and_says_where_it_looked
    settings = Agnostic::Settings.new({ "genesis" => "config/genesis/nowhere.json" }, env: {})
    error = assert_raises(Agnostic::Server::BootError) { Agnostic::Server.new(settings: settings) }
    assert_match(/nowhere.json/, error.message)
  end

  def test_the_host_account_is_created_once_acknowledges_the_genesis_and_keeps_its_key_private
    server = boot("alpha")
    dir = server.settings.data_dir
    key_file = File.join(dir, "host.key")

    assert_equal 0o600, File.stat(key_file).mode & 0o777
    assert_equal [server.genesis.digest], server.host.declaration.ack
    assert_equal "alpha", server.host.declaration["title"]

    again = Agnostic::Server.new(settings: server.settings, http: network)
    assert_equal server.host.id, again.host.id
  end

  def test_a_declaration_that_does_not_match_the_key_beside_it_is_refused
    server = boot("alpha")
    File.write(File.join(server.settings.data_dir, "host.key"), "#{Agnostic::Keys.encode(Ed25519::SigningKey.generate.to_bytes)}\n")
    assert_raises(RuntimeError) { Agnostic::Server.new(settings: server.settings) }
  end

  def test_settings_fall_back_to_defaults_rather_than_zero
    settings = Agnostic::Settings.new({ "pending" => { "max_records" => "lots" }, "peers" => { "pull_interval_seconds" => "0" } }, env: {})
    assert_equal 10_000, settings.integer("pending", "max_records")
    assert_equal 60, settings.integer("peers", "pull_interval_seconds")
  end

  def test_the_environment_wins_over_the_file
    settings = Agnostic::Settings.new({ "peers" => { "urls" => ["http://file"] } },
                                      env: { "PEERS" => "http://a/, http://b", "HEARTBEAT_INTERVAL_SECONDS" => "900" })
    assert_equal ["http://a", "http://b"], settings.peers
    assert_equal 900, settings.integer("heartbeat", "interval_seconds")
  end
end
