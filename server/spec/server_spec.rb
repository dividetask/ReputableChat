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

  # RULE: one network, one development genesis. The chat and this server
  # each commit it, and two different records would be two chains.
  def test_the_development_genesis_is_the_chats
    chat = JSON.parse(File.read(File.expand_path("../../chat/config/genesis/development.json", __dir__)))
    ours = JSON.parse(File.read(GENESIS))
    assert_equal [chat["payload"], chat["signature"]], [ours["payload"], ours["signature"]]
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

  def test_the_host_account_is_made_once_from_two_phrases_kept_private
    server = boot("alpha")
    dir = server.settings.data_dir
    working = File.read(File.join(dir, "host.seed"))
    master = File.read(File.join(dir, "host-master.seed"))

    %w[host.seed host-master.seed].each { |f| assert_equal 0o600, File.stat(File.join(dir, f)).mode & 0o777 }
    refute_equal working, master
    assert_equal Agnostic::Keys.public_key(Agnostic::Seed.signing_key(working)), server.host.pubkey
    assert_equal Agnostic::Keys.public_key(Agnostic::Seed.signing_key(master)), server.host.declaration["mpubkey"]
    assert_equal [server.genesis.digest], server.host.declaration.ack
    assert_equal "alpha", server.host.declaration["title"]

    again = Agnostic::Server.new(settings: server.settings, http: network)
    assert_equal server.host.id, again.host.id
  end

  # The master phrase belongs off the server, so booting must not need it.
  def test_the_server_boots_without_the_master_phrase
    server = boot("alpha")
    File.delete(File.join(server.settings.data_dir, "host-master.seed"))
    assert_equal server.host.id, Agnostic::Server.new(settings: server.settings, http: network).host.id
  end

  def test_a_declaration_that_does_not_match_the_phrase_beside_it_is_refused
    server = boot("alpha")
    path = File.join(server.settings.data_dir, "host.seed")
    File.write(path, "#{Agnostic::Seed.generate}\n")
    assert_raises(RuntimeError) { Agnostic::Server.new(settings: server.settings) }
  end

  def test_a_lost_working_phrase_stops_the_server_rather_than_making_a_new_account
    server = boot("alpha")
    File.delete(File.join(server.settings.data_dir, "host.seed"))
    assert_raises(Agnostic::HostAccount::MissingSeed) { Agnostic::Server.new(settings: server.settings) }
  end

  # A peer finds a server by its account, so the address it is reached at
  # goes into the account's identity declaration.
  def test_the_host_account_declares_the_address_it_is_reached_at
    server = boot("alpha", host: { "url" => "https://alpha.example/" })
    assert_equal "https://alpha.example", server.host.declaration["url"]
  end

  def test_a_changed_handle_bio_or_url_is_published_as_a_new_declaration
    server = boot("alpha")
    settings = Agnostic::Settings.new({ "data_dir" => server.settings.dig("data_dir"),
                                        "host" => { "handle" => "Alpha", "bio" => "Ops", "url" => "http://203.0.113.7:9292" } },
                                      env: { "RACK_ENV" => "development" })
    again = Agnostic::Server.new(settings: settings, http: network).tap(&:go_live)
    latest = again.store.by_account(again.host.id, kind: "identity").max_by(&:seq)

    assert_equal server.host.id, again.host.id
    assert_equal [server.host.id, "Alpha", "Ops", "http://203.0.113.7:9292"], latest.fields.values_at("id", "title", "body", "url")

    third = Agnostic::Server.new(settings: settings, http: network).tap(&:go_live)
    assert_equal 2, third.store.by_account(again.host.id, kind: "identity").size, "an unchanged profile was declared again"
  end

  def test_a_host_url_that_is_not_an_http_address_stops_the_boot
    error = assert_raises(Agnostic::Server::BootError) { boot("alpha", host: { "url" => "chain.example" }) }
    assert_match(/host.url/, error.message)
  end

  def test_the_seed_phrase_length_is_configurable_but_never_below_eight
    server = boot("alpha", host: { "seed_words" => "15" })
    assert_equal 15, File.read(File.join(server.settings.data_dir, "host.seed")).split.size
    assert_equal 8, Agnostic::Settings.new({ "host" => { "seed_words" => "6" } }, env: {}).integer("host", "seed_words")
  end

  def test_settings_fall_back_to_defaults_rather_than_zero
    settings = Agnostic::Settings.new({ "pending" => { "max_records" => "lots" }, "peers" => { "max_clock_skew_seconds" => "0" } }, env: {})
    assert_equal 10_000, settings.integer("pending", "max_records")
    assert_equal 600, settings.integer("peers", "max_clock_skew_seconds")
  end

  def test_the_environment_wins_over_the_file
    settings = Agnostic::Settings.new({ "peers" => { "urls" => ["http://file"] } },
                                      env: { "PEERS" => "http://a/, http://b", "HEARTBEAT_INTERVAL_SECONDS" => "900" })
    assert_equal ["http://a", "http://b"], settings.peers
    assert_equal 900, settings.integer("heartbeat", "interval_seconds")
  end
end
