# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/mock"
require "tmpdir"
require "reputable_chat/app"
require "reputable_chat/bot/persona"
require "reputable_chat/bot/runner"
require "reputable_chat/bot/state"
require "reputable_chat/bot/vouchers"

# The bot client against the real server, in process.
#
# Everything else about the bots can be tested in isolation; this is the part
# that cannot. A bot signs payloads the server verifies byte for byte, and the
# shapes it signs live in the same files the browser's do -- so a change to a
# record shape breaks the bots silently, at runtime, hours into a swarm. This
# spec is what turns that into a failing test.
class BotIntegrationSpec < Minitest::Test
  Bot    = ReputableChat::Bot
  Crypto = ReputableChat::Cryptography

  ORIGIN = "http://example.test"

  # Everything below this is sockets; everything above it is protocol. The
  # bots' own transport is Net::HTTP, and this stands in its place.
  class MockTransport
    def initialize(app) = @app = app

    def call(verb, path, headers, body)
      env = headers.to_h do |name, value|
        [name.casecmp?("content-type") ? "CONTENT_TYPE" : "HTTP_#{name.upcase.tr('-', '_')}", value]
      end

      response = Rack::MockRequest.new(@app).request(verb.to_s.upcase, path, env.merge(input: body.to_s))

      [response.status, Array(response.headers["set-cookie"]).flat_map { |c| c.split("\n") }, response.body]
    end
  end

  # Acts as the genesis account, which in real life is a person at a terminal
  # with the seed. Signs with a raw key so the tests do not pay for Argon2id.
  class Signer
    attr_reader :pubkey

    def initialize(signing)
      @signing = signing
      @pubkey  = Crypto::Signature.encode(signing.verify_key.to_bytes)
    end

    def sign(payload) = Crypto::Signature.encode(@signing.sign(Crypto::Canonical.bytes(payload)))
  end

  def setup
    @genesis, signing = GenesisFixture.build_with_key
    @tim = Signer.new(signing)

    ReputableChat::App.store   = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images  = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origin  = ORIGIN
    ReputableChat::App.genesis = @genesis
    ReputableChat::Genesis.instance_variable_set(:@current, @genesis)

    @transport = MockTransport.new(ReputableChat::App.app)
    @dir       = Dir.mktmpdir
    @logged    = []
  end

  def teardown = ReputableChat::Genesis.reset!

  def client = Bot::Client.new(base_url: ORIGIN, origin: ORIGIN, transport: @transport)

  def logger = ->(line) { @logged << line }

  def persona(overrides = {})
    Bot::Persona.new({
      "username" => "Ana", "category" => "realperson", "brain" => "scripted",
      "lines" => ["hello everyone"], "starting_friends" => 0,
      "posting" => { "visits_per_week" => 40.0, "visit_minutes" => 1.0,
                     "posts_per_week" => 300.0, "reactions_per_week" => 300.0,
                     "min_gap_seconds" => 0, "mode_gap_seconds" => 1 }
    }.merge(overrides))
  end

  def state(name) = Bot::State.load(File.join(@dir, "#{name}.json"), name: name)

  # Tim friends the vouchers once, the way `bin/vouch` has him do.
  def vouchers(count: 1)
    pool = Bot::Vouchers.load(File.join(@dir, "vouchers.json"))
    pool.grow_to(count, seed_config: seed_config)
    pool.all.each do |voucher|
      pool.establish(voucher: voucher, client: client, seed_config: seed_config)
      befriend(voucher.pubkey)
    end
    pool.save
  end

  def seed_config = @seed_config ||= client.defaults.fetch("seed")

  def befriend(pubkey)
    session = client
    session.log_in(@tim)
    session.register
    session.publish_config(
      identity: @tim, version: tim_version + 1,
      profile: { "username" => "Tim", "message" => "", "icon" => nil },
      ratings: tim_ratings.merge(
        pubkey => { "friend" => true, "reported" => false, "net_votes" => 0, "cleared" => false }
      )
    )
  end

  def tim_config
    blob = client.config(@tim.pubkey)
    blob ? JSON.parse(blob["payload"]) : nil
  end

  def tim_version = tim_config&.fetch("version").to_i
  def tim_ratings = tim_config&.fetch("ratings") || {}

  def run_bot(persona_object, name: "ana", pool: nil, visits: 1, seed: 1)
    runner = Bot::Runner.new(
      persona: persona_object, name: name, state: state(name), client: client,
      logger: logger, vouchers: pool, state_dir: @dir, random: Random.new(seed),
      speed: 100_000.0
    )
    runner.run(visits: visits, wait_first: false)
  end

  def published(pubkey)
    blob = client.config(pubkey)
    blob && JSON.parse(blob["payload"])
  end

  def messages = client.messages("general")

  # --- the tests ---------------------------------------------------------

  def test_a_bot_posts_a_message_the_server_accepts
    run_bot(persona, pool: vouchers)

    mine = messages.reject { |m| m["author"] == @tim.pubkey }

    refute_empty mine, "the bot posted nothing the server kept: #{@logged.join(' | ')}"
    assert_equal "hello everyone", JSON.parse(mine.first["payload"])["body"]
  end

  # Every record names the last one its author had seen. A bot that has seen
  # nothing acknowledges the genesis, and the server will not take a record
  # without one.
  def test_every_record_a_bot_signs_acknowledges_one_it_has_seen
    run_bot(persona, pool: vouchers)

    seen = [@genesis.hash] + messages.map { |m| m["hash"] }
    acks = messages.map { |m| JSON.parse(m["payload"])["ack"] }

    refute_empty acks
    acks.each { |ack| assert_includes seen, ack, "acknowledged a record nobody has" }
  end

  # The sybil defense applies to bots too. Without an introduction a new
  # account sits at exactly zero and nobody -- including the other bots -- can
  # see a word of it.
  def test_a_new_bot_is_invisible_until_a_voucher_introduces_it
    run_bot(persona, name: "unvouched", pool: nil)
    unvouched = state("unvouched").pubkey

    assert_equal :blocked, bucket_from_tim(unvouched), "an unintroduced bot should be invisible"

    run_bot(persona, name: "vouched", pool: vouchers)
    vouched = state("vouched").pubkey

    assert_equal :tolerated, bucket_from_tim(vouched),
                 "an introduced bot should be visible, and nowhere near trusted"
  end

  def test_a_bot_friends_the_genesis_account_when_it_is_born
    run_bot(persona, pool: vouchers)

    ratings = published(state("ana").pubkey).fetch("ratings")

    assert ratings.dig(@tim.pubkey, "friend"), "a new bot should arrive knowing the one name everybody knows"
  end

  # Reacting is only half of it: the reputation form is the rating in the
  # reacting bot's own published config, and a reaction that never lands there
  # moves nobody.
  def test_reacting_moves_the_rating_the_rest_of_the_network_reads
    pool = vouchers
    run_bot(persona("lines" => ["first"]), name: "first", pool: pool, visits: 1, seed: 2)
    run_bot(persona("lines" => ["second"], "reply_ratio" => 0.0), name: "second", pool: pool, visits: 2, seed: 3)

    ratings = published(state("second").pubkey).fetch("ratings")
    target  = state("first").pubkey

    assert_operator ratings.dig(target, "net_votes").to_i, :>, 0,
                    "reacting did not reach the reacting bot's config: #{@logged.join(' | ')}"
  end

  # A persona file is not a trusted source of links any more than a model is.
  def test_a_link_in_a_persona_never_reaches_the_server_intact
    spammer = persona("category" => "spammer",
                      "lines" => ["amazing offer http://not-a-real-site.example/claim"])
    run_bot(spammer, name: "spam", pool: vouchers)

    bodies = messages.map { |m| JSON.parse(m["payload"])["body"] }.join(" ")

    refute_includes bodies, "not-a-real-site.example", "a persona's link went out as written"
    assert_match(%r{youtube\.com|/caught\.html}, bodies, "the link should have been replaced, not just dropped")
  end

  def bucket_from_tim(pubkey)
    store = ReputableChat::Store::Memory.new
    load_graph(store, @tim.pubkey, {})

    ReputableChat::Reputation::Engine.new(
      config: ReputableChat::Config.load, store: store
    ).bucket(viewer: @tim.pubkey, target: pubkey)
  end

  # Walks the published configs the way a client would, so the buckets under
  # test are the ones a real viewer would land on.
  def load_graph(store, pubkey, seen)
    return if seen[pubkey]

    seen[pubkey] = true
    payload = published(pubkey)
    return unless payload

    (payload["ratings"] || {}).each do |target, rating|
      store.rate(pubkey, target, friend: rating["friend"], reported: rating["reported"],
                                 net_votes: rating["net_votes"].to_i, cleared: rating["cleared"])
      load_graph(store, target, seen)
    end
  end
end
