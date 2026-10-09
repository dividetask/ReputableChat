# frozen_string_literal: true

require_relative "spec_helper"
require "digest"
require "tmpdir"
require "reputable_chat/file_peers"
require "reputable_chat/store/images"

# Fetching a file this chat server lacks from the others that announced
# themselves (FilePeers). The network is faked: each address answers from a
# table, and nothing leaves the process.
class FilePeersSpec < Minitest::Test
  PNG = "\x89PNG\r\n\x1A\n".b + ("x" * 64).b
  NAME = "#{Digest::SHA256.hexdigest(PNG)}.png".freeze

  Mirror = Struct.new(:services)
  Chain = Struct.new(:ratings)
  Host = Struct.new(:account)
  Resolver = Struct.new(:table) do
    def getaddresses(name) = table.fetch(name, ["93.184.216.34"])
  end

  def setup
    @images = ReputableChat::Store::Images.new(Dir.mktmpdir)
    @services = {}
    @ratings = {}
    @answers = {}
    @asked = []
    @connected = []
    @reports = []
    @now = 1_000
  end

  def peers(allow_private: false, require_https: false, resolver: Resolver.new({}), missing_penalty: "0.25")
    ReputableChat::FilePeers.new(
      mirror: Mirror.new(@services), chain: Chain.new(@ratings), images: @images, host: Host.new("me"),
      allow_private: allow_private, require_https: require_https, clock: -> { @now }, random: Random.new(1),
      resolver: resolver,
      http: ->(url, _max, ip) { @asked << url; @connected << ip; @answers[url] },
      reporter: ->(account, outcome) { @reports << [account, outcome] }, missing_penalty: missing_penalty
    )
  end

  # A chat server at `url` that answers as `account`, holding `files`.
  def server(account, url, files: {})
    @services[account] = url
    @answers["#{url}/api/host"] = JSON.generate("host" => { "account" => account })
    files.each { |name, bytes| @answers["#{url}/images/#{name}"] = bytes }
  end

  def test_a_file_is_fetched_from_a_chat_server_that_has_it
    server("a", "https://a.example", files: { NAME => PNG })

    assert_equal NAME, peers.fetch(NAME)
    assert_equal PNG, @images.read(NAME)
  end

  # RULE: the bytes must hash to the name the record signed, so no server can
  # put another file in its place.
  def test_bytes_that_do_not_hash_to_the_name_are_refused
    server("a", "https://a.example", files: { NAME => "\x89PNG\r\n\x1A\n".b + ("y" * 64).b })

    assert_nil peers.fetch(NAME)
    assert_nil @images.read(NAME)
  end

  # RULE: a server is asked only once it answers at its address as the
  # account that announced it.
  def test_a_server_answering_as_another_account_is_not_asked
    server("a", "https://a.example", files: { NAME => PNG })
    @answers["https://a.example/api/host"] = JSON.generate("host" => { "account" => "somebody else" })

    assert_nil peers.fetch(NAME)
    refute_includes @asked, "https://a.example/images/#{NAME}"
  end

  # RULE (yours): no private, loopback or link-local address unless allowed,
  # and https in production.
  def test_private_addresses_are_refused_unless_allowed
    resolver = Resolver.new({ "inside.example" => ["10.0.0.5"], "localhost" => ["127.0.0.1"],
                              "linklocal.example" => ["169.254.169.254"] })
    %w[inside.example localhost linklocal.example].each do |name|
      refute peers(resolver: resolver).allowed?("https://#{name}"), "#{name} should be refused"
      assert peers(resolver: resolver, allow_private: true).allowed?("https://#{name}")
    end
    assert peers(resolver: resolver).allowed?("https://public.example")
  end

  def test_production_asks_only_over_https
    refute peers(require_https: true).allowed?("http://a.example")
    assert peers(require_https: true).allowed?("https://a.example")
  end

  # RULE (yours): a server the agnostic server rates below zero is skipped.
  def test_a_server_rated_below_zero_is_not_asked
    server("a", "https://a.example", files: { NAME => PNG })
    @ratings["a"] = { "reputation" => "-0.01", "trust" => "0" }

    assert_nil peers.fetch(NAME)
    refute_includes @asked, "https://a.example/images/#{NAME}"
  end

  # RULE (yours): chosen at random, more often the better rated.
  def test_better_rated_servers_are_asked_first_more_often
    server("good", "https://good.example")
    server("plain", "https://plain.example")
    @ratings["good"] = { "reputation" => "0.02", "trust" => "0" }
    firsts = Array.new(200) do |i|
      ReputableChat::FilePeers.new(
        mirror: Mirror.new(@services), chain: Chain.new(@ratings), images: @images, host: Host.new("me"),
        allow_private: false, require_https: false, random: Random.new(i), resolver: Resolver.new({}),
        http: ->(url, _max, _ip) { @answers[url] }
      ).candidates.first.first
    end

    assert_operator firsts.count("good"), :>, 120
    assert_operator firsts.count("plain"), :>, 0, "chosen at random, not always the best"
  end

  # RULE (yours): a server that fails is put off, for longer each time.
  def test_a_server_that_fails_is_put_off_and_comes_back
    server("a", "https://a.example")
    finder = peers
    other = "#{'f' * 64}.png"

    assert_nil finder.fetch(NAME)
    @now += 30
    @asked.clear
    assert_nil finder.fetch(other)
    refute_includes @asked, "https://a.example/images/#{other}", "asked again while put off"

    @now += 3_600
    @answers["https://a.example/images/#{NAME}"] = PNG
    assert_equal NAME, finder.fetch(NAME)
  end

  def test_a_file_nobody_has_is_not_asked_for_again_at_once
    server("a", "https://a.example")
    finder = peers
    finder.fetch(NAME)
    @asked.clear

    assert_nil finder.fetch(NAME)
    assert_empty @asked
  end

  def test_this_server_is_not_asked_for_its_own_files
    server("me", "https://me.example", files: { NAME => PNG })

    assert_nil peers.fetch(NAME)
    assert_empty @asked
  end

  # RULE (yours): what the chat finds goes to the agnostic server, where it
  # counts toward the account's rating.
  def test_each_success_and_failure_is_reported_to_the_agnostic_server
    server("a", "https://a.example", files: { NAME => PNG })
    peers.fetch(NAME)
    assert_equal [["a", :reached]], @reports

    @reports.clear
    server("b", "https://b.example")
    @services.delete("a")
    peers.fetch("#{'e' * 64}.png")
    assert_equal [["b", :unreached]], @reports, "a server that does not answer is a failure"
  end

  def test_a_server_failing_its_check_is_reported_and_put_off
    server("b", "https://b.example")
    @answers.delete("https://b.example/api/host")
    finder = peers
    finder.fetch(NAME)

    assert_equal [["b", :unreached]], @reports
    assert_empty finder.candidates, "put off after failing its check"
  end

  # RULE: the address checked is the address connected to, and a name with
  # any private address is refused, so it cannot pass the check with one
  # address and be reached at another.
  def test_the_address_checked_is_the_one_connected_to
    server("a", "https://a.example", files: { NAME => PNG })
    peers(resolver: Resolver.new({ "a.example" => ["93.184.216.34"] })).fetch(NAME)
    assert_equal ["93.184.216.34"], @connected.uniq

    refute peers(resolver: Resolver.new({ "a.example" => ["93.184.216.34", "10.0.0.5"] })).allowed?("https://a.example")
  end

  # RULE (yours): a server that answers without the file loses less than one
  # that does not answer: it is reported as missing, and put off for
  # missing_penalty of the time a failure would cost.
  def test_a_server_without_the_file_is_put_off_for_less_than_a_failure
    server("a", "https://a.example")
    @answers["https://a.example/images/#{NAME}"] = :missing
    finder = peers(missing_penalty: "0.25")

    assert_nil finder.fetch(NAME)
    assert_equal [["a", :missing]], @reports

    @now += 10
    assert_empty finder.candidates, "put off for a quarter of the first failure's 60 seconds"
    @now += 10
    assert_equal ["a"], finder.candidates.map(&:first), "and no longer than that"
  end

  # RULE (yours): a miss is not a failure, so it does not make the next
  # failure's wait any longer.
  def test_a_miss_does_not_lengthen_the_wait_after_a_failure
    server("a", "https://a.example")
    @answers["https://a.example/images/#{NAME}"] = :missing
    finder = peers
    finder.fetch(NAME)
    @now += 20

    finder.fetch("#{'e' * 64}.png")
    assert_equal :unreached, @reports.last.last
    @now += 61
    refute_empty finder.candidates, "the first failure costs 60 seconds, missed files or not"
  end

  def test_the_missing_penalty_runs_from_answered_to_unanswered
    server("a", "https://a.example")
    @answers["https://a.example/images/#{NAME}"] = :missing

    free = peers(missing_penalty: "0")
    free.fetch(NAME)
    refute_empty free.candidates, "0: a miss costs nothing"

    full = peers(missing_penalty: "1")
    full.fetch(NAME)
    @now += 59
    assert_empty full.candidates, "1: a miss costs what a failure does"
  end
end
