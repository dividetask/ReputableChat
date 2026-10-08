# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_server"
require "rack/test"
require "tmpdir"
require "ed25519"
require "reputable_chat/app"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/canonical"

# The records the chain is made of, over the wire: what the chat takes from
# its own clients and passes to its agnostic server, and what it hands back.
# The rules themselves are the agnostic server's, and tested there.
class ChainRecordsSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Crypto  = ReputableChat::Cryptography
  Payload = Crypto::Payload
  ORIGIN  = "http://example.test"

  # An account under test: its key, and its account ID once declared.
  Account = Struct.new(:working, :id) do
    def pubkey = Sig.encode(working.verify_key.to_bytes)
  end

  def setup
    ChainServer.wire
    ReputableChat::App.images  = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origins = [ORIGIN]
    @genesis = ReputableChat::App.genesis
    @me = Account.new(Ed25519::SigningKey.generate)
  end

  def new_key = Ed25519::SigningKey.generate
  def key_of(signing) = Sig.encode(signing.verify_key.to_bytes)

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
    stored = json["messages"].find { |m| m["account"] == @me.id }
    assert_equal Crypto::Record.digest(payload: stored["payload"], signature: stored["signature"]), stored["hash"]
    assert_equal @me.id, stored["account"]
    assert_equal "valid", stored["state"]
  end

  def test_a_record_is_judged_against_the_rules
    declare_me
    payload = Payload.message(id: @me.id, pubkey: @me.pubkey, body: "hello", ack: [@me.id], ts: now)
    canonical = Crypto::Canonical.dump(payload).sub('"hello"', '"goodbye"')
    post_json "/api/record", { "payload" => canonical,
                               "signature" => Sig.encode(@me.working.sign(Crypto::Canonical.dump(payload).b)) }

    assert_refused(/signed with the session's key/)
  end

  # The chat checks its own terms and nothing the rules decide: a record that
  # meets them is passed on, and the agnostic server's refusal comes back.
  def test_the_agnostic_servers_refusal_is_passed_back
    declare_me
    send_record(Payload.message(id: @me.id, pubkey: @me.pubkey, body: "hi", ack: [@me.id], ts: now,
                                target: ["b" * 64, "a" * 64]).merge("target" => ["b" * 64, "a" * 64]))

    assert_refused(/sorted/)
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
    send_record(Payload.message(id: @me.id, pubkey: key_of(other), body: "x", ack: [@me.id], ts: now),
                key: other)

    assert_refused(/session's key/)
  end

  def test_a_client_publishes_only_for_its_own_account
    declare_me
    send_record(Payload.message(id: @genesis.hash, pubkey: @me.pubkey, body: "x", ack: [@me.id], ts: now))

    assert_refused(/not this session's account's/)
  end

  # RULE (yours): the chat takes records about the chain and its own, and
  # ignores other apps' -- which still reach it inside other records' histories.
  def test_a_client_sends_chain_records_and_chat_records_only
    declare_me
    say(app: "forum")
    assert_refused(/records about the chain and the chat's own/)

    send_record(Payload.notice(id: @me.id, pubkey: @me.pubkey, kind: "key-change", body: key_of(new_key),
                               ack: [@me.id], ts: now))
    assert_equal 200, last_response.status, "a key change is about the chain"
  end

  # RULE: integers stop where JavaScript stops reading them exactly, as they
  # do on the agnostic server.
  def test_a_client_record_holds_no_integer_javascript_cannot_read
    declare_me
    send_record(Payload.message(id: @me.id, pubkey: @me.pubkey, body: "x", ack: [@me.id], ts: now)
                       .merge("count" => 2**53))
    assert_refused(/integer beyond 9007199254740991/)
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
    assert_refused(/records about the chain and the chat's own/)

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
    assert_equal [first], JSON.parse(json["messages"].reverse.find { |m| m["account"] == @me.id }["payload"])["target"]

    get "/api/reactions"
    reaction = json["reactions"].find { |x| x["account"] == @me.id }
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
end
