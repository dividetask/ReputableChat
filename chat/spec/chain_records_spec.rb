# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require_relative "chain_helper"
require "rack/test"
require "tmpdir"
require "reputable_chat/app"

# The records the chain is made of, over the wire: what the server takes from
# its own clients, what it takes from other servers, and what it hands back.
class ChainRecordsSpec < Minitest::Test
  include Rack::Test::Methods
  include ChainHelper

  Sig = ReputableChat::Cryptography::Signature
  ORIGIN = "http://example.test"
  PEER_TOKEN = "a peer's secret"

  def setup
    @genesis, @genesis_key = GenesisFixture.build_with_key
    ReputableChat::App.store   = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images  = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origins = [ORIGIN]
    ReputableChat::App.genesis = @genesis
    ReputableChat::App.host    = nil
    ReputableChat::App.peer_tokens = [PEER_TOKEN]
    ReputableChat::App.book = ReputableChat::Chain::Book.new(ReputableChat::App.store, genesis: @genesis.record)
    @me = Account.new(master: false)
  end

  def app = ReputableChat::App.app
  def json = JSON.parse(last_response.body)
  def now = Time.now.to_i

  def post_json(path, body, headers = {})
    post path, JSON.generate(body), { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  def log_in(account = @me)
    post_json "/api/challenge", {}
    nonce = json["nonce"]
    payload = Payload.login(pubkey: account.pubkey, nonce: nonce, origin: ORIGIN, issued_at: now)
    signature = Sig.encode(account.working.sign(Crypto::Canonical.bytes(payload)))
    post_json "/api/session", { "pubkey" => account.pubkey, "nonce" => nonce, "ts" => now, "signature" => signature }
    json
  end

  def send_record(payload, key: @me.working)
    canonical = Crypto::Canonical.dump(payload)
    post_json "/api/record", { "payload" => canonical, "signature" => Sig.encode(key.sign(canonical.b)) }
    json
  end

  def declare_me(handle: "alice", **extra)
    log_in
    result = send_record(Payload.identity(pubkey: @me.pubkey, handle: handle, ack: [@genesis.hash], ts: now, **extra))
    @me.id = result["account"]
    result
  end

  def say(body = "hello", ack: [@me.id], **extra)
    send_record(Payload.message(id: @me.id, pubkey: @me.pubkey, body: body, ack: ack, ts: now, **extra))
  end

  def assert_refused(pattern, status: 400)
    assert_equal status, last_response.status, last_response.body
    assert_match pattern, json["error"]
  end

  # --- accounts ---------------------------------------------------------------

  # RULE: an account comes into being with its first identity declaration, and
  # its record hash is the account ID from then on.
  def test_a_first_declaration_creates_the_account
    assert_equal false, log_in["registered"]

    result = declare_me
    assert_equal 200, last_response.status
    assert_equal result["hash"], result["account"]

    session = log_in
    assert session["registered"]
    assert_equal result["account"], session["account"]
    assert_equal result["hash"], session["latest"], "a client acknowledges its own newest record"
  end

  def test_the_newest_declaration_is_served
    declare_me(handle: "alice")
    send_record(Payload.identity(id: @me.id, pubkey: @me.pubkey, handle: "alice b", bio: "gardener",
                                 ack: [@me.id], ts: now))

    get "/api/identity/#{@me.id}"
    payload = JSON.parse(json["identity"]["payload"])
    assert_equal "alice b", payload["title"]
    assert_equal "gardener", payload["body"]
  end

  def test_a_session_has_one_account
    declare_me
    send_record(Payload.identity(pubkey: @me.pubkey, handle: "again", ack: [@genesis.hash], ts: now))

    assert_refused(/already has an account/)
  end

  # --- what the server checks ------------------------------------------------------

  # RULE: the hash the server serves is the hash of what it serves, so a reader
  # can re-derive it from the blob and catch a server that made one up.
  def test_the_served_hash_is_the_hash_of_the_served_record
    declare_me
    say

    get "/api/messages"
    stored = json["messages"].first
    assert_equal Record.parse(stored["payload"], stored["signature"]).record_hash, stored["hash"]
    assert_equal @me.id, stored["account"]
    assert_equal "valid", stored["state"]
  end

  def test_a_record_is_judged_against_the_rules
    declare_me
    payload = Payload.message(id: @me.id, pubkey: @me.pubkey, body: "hello", ack: [@me.id], ts: now)
    canonical = Crypto::Canonical.dump(payload).sub('"hello"', '"goodbye"')
    post_json "/api/record", { "payload" => canonical,
                               "signature" => Sig.encode(@me.working.sign(Crypto::Canonical.dump(payload).b)) }

    assert_refused(/signature verifies against no key/)
  end

  def test_an_unknown_ack_is_a_conflict_not_a_verdict
    declare_me
    say(ack: ["f" * 64])

    assert_refused(/send it first/, status: 409)
  end

  def test_the_same_record_cannot_be_stored_twice
    declare_me
    payload = Payload.message(id: @me.id, pubkey: @me.pubkey, body: "hello", ack: [@me.id], ts: now)
    send_record(payload)
    send_record(payload)

    assert_refused(/already been stored/, status: 409)
  end

  def test_publishing_requires_a_session
    send_record(Payload.message(id: "a" * 64, pubkey: @me.pubkey, body: "x", ack: [@genesis.hash], ts: now))

    assert_equal 401, last_response.status
  end

  # --- this server's terms for its own clients ------------------------------------------

  def test_a_client_signs_with_its_own_session_key
    declare_me
    other = new_key
    send_record(Payload.message(id: @me.id, pubkey: ChainHelper.key_of(other), body: "x", ack: [@me.id], ts: now),
                key: other)

    assert_refused(/session's key/)
  end

  def test_a_client_publishes_only_for_its_own_account
    declare_me
    send_record(Payload.message(id: @genesis.hash, pubkey: @me.pubkey, body: "x", ack: [@me.id], ts: now))

    assert_refused(/not this session's account's/)
  end

  # RULE (this server's): only the records the chat makes come from clients.
  def test_a_client_sends_only_chat_records
    declare_me
    say(app: "forum")
    assert_refused(/for the chat/)

    send_record(Payload.heartbeat(id: @me.id, pubkey: @me.pubkey, ack: [@me.id], ts: now))
    assert_refused(/not heartbeat/)

    say(transfer: { "out" => [{ "to" => @me.id, "value" => "1" }] })
    assert_refused(/does not take transfer/)
  end

  def test_a_client_is_held_to_the_server_limits
    declare_me
    say("x" * 4_001)
    assert_refused(/over 4000 bytes/)

    send_record(Payload.identity(id: @me.id, pubkey: @me.pubkey, handle: "a", bio: "x" * 281, ack: [@me.id], ts: now))
    assert_refused(/bio is at most 280/)
  end

  def test_a_client_sends_notices_of_the_kinds_the_chat_shows
    declare_me
    send_record(Payload.notice(id: @me.id, pubkey: @me.pubkey, kind: "outage", body: "Down Friday.",
                               ack: [@me.id], ts: now))
    assert_equal 200, last_response.status

    send_record(Payload.notice(id: @me.id, pubkey: @me.pubkey, kind: "receipt", body: "x", ack: [@me.id], ts: now))
    assert_refused(/unknown notice kind/)

    get "/api/notices/#{@me.id}"
    assert_equal ["outage"], json["notices"].map { |n| JSON.parse(n["payload"])["kind"] }
  end

  def test_a_client_avatar_is_an_image_the_server_stores
    declare_me
    send_record(Payload.identity(id: @me.id, pubkey: @me.pubkey, handle: "a", avatar: "#{'a' * 64}.avif",
                                 ack: [@me.id], ts: now))

    assert_refused(/image this server stores/)
  end

  def test_a_client_record_is_timestamped_near_the_server_clock
    declare_me
    send_record(Payload.message(id: @me.id, pubkey: @me.pubkey, body: "x", ack: [@me.id], ts: now - 7_200))

    assert_refused(/from this server's clock/)
  end

  # --- reading -------------------------------------------------------------------------

  def test_a_reply_names_its_target_and_reactions_are_served_with_theirs
    declare_me
    first = say("hello")["hash"]
    say("agreed", ack: [first], target: [first])
    send_record(Payload.reaction(id: @me.id, pubkey: @me.pubkey, body: "👍", target: [first], ack: [first], ts: now))

    get "/api/messages"
    assert_equal [first], JSON.parse(json["messages"].last["payload"])["target"]

    get "/api/reactions"
    reaction = json["reactions"].first
    assert_equal [first], reaction["target"]
    assert_equal "👍", reaction["body"]
  end

  def test_attestations_are_served_by_account_and_in_batches
    declare_me
    send_record(Payload.attestation(id: @me.id, pubkey: @me.pubkey, ack: [@me.id], ts: now,
                                    scores: { @genesis.hash => { "reputation" => "0.5", "trust" => "1" } }))
    assert_equal 200, last_response.status

    post_json "/api/attestation/batch", { "accounts" => [@me.id, @genesis.hash] }
    assert_equal [@me.id], json["attestations"].map { |a| a["account"] }
  end

  def test_a_batch_is_bounded
    post_json "/api/identity/batch", { "accounts" => Array.new(300) { |i| format("%064x", i) } }

    assert_equal 400, last_response.status
  end

  # RULE: any record resolves by its hash, for anyone. Walking back to the
  # genesis passes through records a viewer would never display.
  def test_any_record_is_served_by_hash
    declare_me
    hash = say["hash"]
    clear_cookies

    get "/api/record/#{hash}"
    assert_equal hash, json["record"]["hash"]
  end

  # --- other servers -------------------------------------------------------------------

  def peer(records, token: PEER_TOKEN)
    post_json "/api/peer/records", { "records" => records },
              token ? { "HTTP_AUTHORIZATION" => "Bearer #{token}" } : {}
    json
  end

  def wire(payload, key)
    canonical = Crypto::Canonical.dump(payload)
    { "payload" => canonical, "signature" => Sig.encode(key.sign(canonical.b)) }
  end

  # RULE (yours): another server's records are held to the rules alone, of any
  # type, and not to the limits this server sets its own clients.
  def test_a_peer_passes_on_any_valid_record
    bob = Account.new
    decl = wire(Payload.identity(pubkey: bob.pubkey, handle: "bob", ack: [@genesis.hash], ts: 1), bob.working)
    bob_id = Record.parse(decl["payload"], decl["signature"]).record_hash
    forum = wire(Payload.message(id: bob_id, pubkey: bob.pubkey, body: "x" * 10_000, ack: [bob_id], ts: 2,
                                 app: "forum"), bob.working)
    beat = wire(Payload.heartbeat(id: bob_id, pubkey: bob.pubkey, ack: [bob_id], ts: 3), bob.working)

    results = peer([decl, forum, beat])["results"]
    assert_equal [true, true, true], results.map { |r| r["stored"] }, results.inspect
  end

  def test_a_peer_record_is_still_held_to_the_rules
    bob = Account.new
    decl = wire(Payload.identity(pubkey: bob.pubkey, handle: " bob", ack: [@genesis.hash], ts: 1), bob.working)

    result = peer([decl])["results"].first
    refute result["stored"]
    assert_match(/surrounding whitespace/, result["error"])
  end

  def test_only_a_peer_may_pass_records_on
    peer([], token: "wrong")
    assert_equal 401, last_response.status

    ReputableChat::App.peer_tokens = []
    peer([])
    assert_equal 404, last_response.status, "with no tokens configured the route is closed"
  end
end
