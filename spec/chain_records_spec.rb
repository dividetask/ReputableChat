# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "ed25519"
require "tmpdir"
require "digest"
require "reputable_chat/app"
require "reputable_chat/cryptography/record"

# The records the chain is made of, over the wire. What the server will and
# will not accept, and what it hands back.
class ChainRecordsSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical
  Record  = ReputableChat::Cryptography::Record

  ORIGIN = "http://example.test"

  def setup
    ReputableChat::App.store   = ReputableChat::Store::Database.new("sqlite:/")
    ReputableChat::App.images  = ReputableChat::Store::Images.new(Dir.mktmpdir)
    ReputableChat::App.origin  = ORIGIN
    ReputableChat::App.genesis = GenesisFixture.build
    @signing = Ed25519::SigningKey.generate
    @pubkey  = Sig.encode(@signing.verify_key.to_bytes)
    log_in
  end

  def app = ReputableChat::App.app
  def sign(payload) = Sig.encode(@signing.sign(Canon.bytes(payload)))
  def json = JSON.parse(last_response.body)
  def ack = ReputableChat::App.genesis.hash
  def somebody = Sig.encode(Ed25519::SigningKey.generate.verify_key.to_bytes)

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def put_json(path, body)
    put path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
  end

  def log_in
    post_json "/api/challenge", {}
    nonce = JSON.parse(last_response.body)["nonce"]
    ts = Time.now.to_i
    payload = Payload.login(pubkey: @pubkey, nonce: nonce, origin: ORIGIN, issued_at: ts)
    post_json "/api/session",
              { "pubkey" => @pubkey, "nonce" => nonce, "ts" => ts, "signature" => sign(payload) }
    post_json "/api/register", {}
  end

  # --- identity declarations -------------------------------------------------------

  def identity_body(revision: 1, handle: "alice", bio: "", icon: nil, extra: {})
    ts = Time.now.to_i
    payload = Payload.identity(pubkey: @pubkey, revision: revision, handle: handle, bio: bio,
                           icon: icon, ack: ack, issued_at: ts)
    { "revision" => revision, "handle" => handle, "bio" => bio, "icon" => icon,
      "ack" => ack, "ts" => ts, "signature" => sign(payload) }.merge(extra)
  end

  def test_stores_an_identity_declaration_and_serves_it_back
    put_json "/api/identity", identity_body(handle: "alice", bio: "hello")
    assert_equal 200, last_response.status

    get "/api/identity/#{@pubkey}"
    record = json["identity"]
    payload = JSON.parse(record["payload"])

    assert_equal "alice", payload["handle"]
    assert_equal "hello", payload["bio"]
  end

  # RULE: the hash the server serves is the hash of what it serves, so a reader
  # re-deriving it from the blob catches a server that invented one.
  def test_the_served_hash_matches_the_served_record
    put_json "/api/identity", identity_body
    get "/api/identity/#{@pubkey}"
    record = json["identity"]

    assert_equal Record.digest(payload: record["payload"], signature: record["signature"]),
                 record["hash"]
  end

  # RULE: a revision must climb. Without it the server could serve an old copy
  # to hide something and the signature on it would still verify perfectly.
  def test_refuses_a_rolled_back_identity_declaration
    put_json "/api/identity", identity_body(revision: 2)
    assert_equal 200, last_response.status

    put_json "/api/identity", identity_body(revision: 1)
    assert_equal 409, last_response.status
  end

  # RULE: the key rotation fields are placeholders. Accepting a value for
  # something nothing implements would let a client publish a claim the network
  # would later have to honour or explain away.
  def test_refuses_an_identity_declaration_claiming_key_rotation
    put_json "/api/identity", identity_body(extra: { "master_pubkey" => somebody })

    assert_equal 400, last_response.status
  end

  def test_refuses_an_identity_declaration_with_no_ack
    body = identity_body
    body.delete("ack")
    put_json "/api/identity", body

    assert_equal 400, last_response.status
  end

  # RULE: everything in the record is signed, so nothing can be swapped in
  # transit -- not the handle, and not the ack.
  def test_refuses_an_identity_declaration_whose_handle_was_altered
    put_json "/api/identity", identity_body(handle: "alice").merge("handle" => "mallory")

    assert_equal 400, last_response.status
  end

  # --- attestations -------------------------------------------------------

  def attestation_body(revision: 1, scores: nil, derived: nil)
    scores ||= { somebody => { "reputation" => "0.5", "trust" => "1" } }
    derived ||= { "hops" => 3, "params" => Digest::SHA256.hexdigest("params"), "scores" => {} }
    ts = Time.now.to_i
    payload = Payload.attestation(pubkey: @pubkey, revision: revision, scores: scores,
                                  derived: derived, ack: ack, issued_at: ts)
    { "revision" => revision, "scores" => scores, "derived" => derived,
      "ack" => ack, "ts" => ts, "signature" => sign(payload) }
  end

  def test_stores_an_attestation_and_serves_it_back
    target = somebody
    put_json "/api/attestation",
             attestation_body(scores: { target => { "reputation" => "0.5", "trust" => "0" } })
    assert_equal 200, last_response.status

    get "/api/attestation/#{@pubkey}"
    payload = JSON.parse(json["attestation"]["payload"])

    assert_equal "0.5", payload["scores"][target]["reputation"]
    assert_equal "0", payload["scores"][target]["trust"]
  end

  # RULE: scores are decimal strings. The Blocked line is `effective > 0`, and
  # binary floating point cannot be trusted to land on it.
  #
  # A float cannot even be signed -- Canonical refuses one outright, since it
  # has no single textual form across languages -- so this arrives as a body
  # that was signed correctly and then had a float put in it, which is the only
  # way the server can be offered one.
  def test_refuses_a_score_sent_as_a_number
    target = somebody
    body = attestation_body(scores: { target => { "reputation" => "0.5", "trust" => "1" } })
    body["scores"] = { target => { "reputation" => 0.5, "trust" => 1 } }

    put_json "/api/attestation", body

    assert_equal 400, last_response.status
  end

  # The same rule from the other side: signing a float is refused before it can
  # reach the wire at all.
  def test_a_float_cannot_be_signed_in_the_first_place
    assert_raises(ArgumentError) do
      Canon.bytes(Payload.attestation(pubkey: @pubkey, revision: 1,
                                      scores: { somebody => { "reputation" => 0.5, "trust" => 1 } },
                                      derived: {}, ack: ack, issued_at: 1))
    end
  end

  def test_refuses_a_score_outside_minus_one_to_one
    put_json "/api/attestation",
             attestation_body(scores: { somebody => { "reputation" => "1.5", "trust" => "1" } })

    assert_equal 400, last_response.status
  end

  # RULE: a trust multiplier above 1 would amplify a branch past the weight the
  # ladder gave it, and the weights summing to (just under) 1 is what keeps an
  # effective score inside -1..1 without clamping.
  def test_refuses_a_trust_multiplier_above_one
    put_json "/api/attestation",
             attestation_body(scores: { somebody => { "reputation" => "0.5", "trust" => "2" } })

    assert_equal 400, last_response.status
  end

  def test_accepts_a_negative_trust_multiplier
    target = somebody
    put_json "/api/attestation",
             attestation_body(scores: { target => { "reputation" => "0.5", "trust" => "-1" } })

    assert_equal 200, last_response.status
  end

  # RULE: published estimates carry the parameters they were computed under.
  # Without that a reader cannot tell whether the numbers mean anything to
  # them, and taking them anyway means adopting a stranger's settings.
  def test_refuses_derived_scores_with_no_parameter_fingerprint
    put_json "/api/attestation", attestation_body(derived: { "hops" => 3, "scores" => {} })

    assert_equal 400, last_response.status
  end

  def test_refuses_a_rolled_back_attestation
    put_json "/api/attestation", attestation_body(revision: 3)
    put_json "/api/attestation", attestation_body(revision: 2)

    assert_equal 409, last_response.status
  end

  def test_batch_fetches_attestations
    put_json "/api/attestation", attestation_body
    post_json "/api/attestation/batch", { "pubkeys" => [@pubkey] }

    assert_equal 200, last_response.status
    assert_equal 1, json["attestations"].size
  end

  # --- adjustments --------------------------------------------------------

  def adjustment_body(base_revision: 1, seq: 1, target: nil, reputation: "0.5032", trust: "1")
    target ||= somebody
    ts = Time.now.to_i
    payload = Payload.adjustment(pubkey: @pubkey, base_revision: base_revision, seq: seq,
                                 target: target, reputation: reputation, trust: trust,
                                 ack: ack, issued_at: ts)
    { "base_revision" => base_revision, "seq" => seq, "target" => target,
      "reputation" => reputation, "trust" => trust, "ack" => ack, "ts" => ts,
      "signature" => sign(payload) }
  end

  def test_stores_an_adjustment_and_serves_the_run_back
    target = somebody
    post_json "/api/adjustment", adjustment_body(seq: 1, target: target)
    assert_equal 200, last_response.status
    post_json "/api/adjustment", adjustment_body(seq: 2, target: somebody)

    get "/api/adjustment/#{@pubkey}?base_revision=1"
    run = json["adjustments"]

    assert_equal [1, 2], run.map { |a| a["seq"] }
    assert_equal target, run.first["target"]
  end

  # RULE: an adjustment names the snapshot it amends. One against an older
  # snapshot was superseded by the republish that followed it, so it must not
  # surface in a later run.
  def test_an_adjustment_belongs_only_to_the_snapshot_it_amends
    post_json "/api/adjustment", adjustment_body(base_revision: 1, seq: 1)
    post_json "/api/adjustment", adjustment_body(base_revision: 2, seq: 1)

    get "/api/adjustment/#{@pubkey}?base_revision=2"

    assert_equal 1, json["adjustments"].size
    assert_equal 2, JSON.parse(json["adjustments"].first["payload"])["base_revision"]
  end

  def test_the_same_place_in_a_run_cannot_be_used_twice
    body = adjustment_body(seq: 1)
    post_json "/api/adjustment", body
    assert_equal 200, last_response.status

    post_json "/api/adjustment", body
    assert_equal 409, last_response.status
  end

  # RULE: nobody adjusts their own standing. Self-rating is excluded from the
  # maths everywhere else, and letting it into the records invites a client to
  # act on it.
  def test_refuses_an_adjustment_about_its_own_author
    post_json "/api/adjustment", adjustment_body(target: @pubkey)

    assert_equal 400, last_response.status
  end

  def test_refuses_an_adjustment_whose_score_was_altered
    post_json "/api/adjustment", adjustment_body(reputation: "0.5").merge("reputation" => "1")

    assert_equal 400, last_response.status
  end

  # --- notes --------------------------------------------------------------

  # RULE: a note is signed with everything else, so the server cannot add one,
  # strip one, or swap one out.
  def test_refuses_an_identity_declaration_whose_note_was_altered
    put_json "/api/identity", identity_body.merge("note" => "not what was signed")

    assert_equal 400, last_response.status
  end

  def test_stores_a_note_and_serves_it_back
    ts = Time.now.to_i
    note = "posted from a terminal, for whoever reads the raw chain"
    payload = Payload.identity(pubkey: @pubkey, revision: 1, handle: "alice", bio: "",
                           icon: nil, ack: ack, issued_at: ts, note: note)

    put_json "/api/identity",
             { "revision" => 1, "handle" => "alice", "bio" => "", "icon" => nil,
               "ack" => ack, "note" => note, "ts" => ts, "signature" => sign(payload) }
    assert_equal 200, last_response.status

    get "/api/identity/#{@pubkey}"

    assert_equal note, JSON.parse(json["identity"]["payload"])["note"]
  end

  # RULE: a malformed note is a rejection, not something to quietly drop. A
  # dropped one would store a record whose signature covers text the server
  # never saw, so nothing would verify afterwards.
  def test_refuses_an_oversized_note
    ts = Time.now.to_i
    note = "x" * (ReputableChat::Params::MAX_NOTE + 1)
    payload = Payload.identity(pubkey: @pubkey, revision: 1, handle: "alice", bio: "",
                           icon: nil, ack: ack, issued_at: ts, note: note)

    put_json "/api/identity",
             { "revision" => 1, "handle" => "alice", "bio" => "", "icon" => nil,
               "ack" => ack, "note" => note, "ts" => ts, "signature" => sign(payload) }

    assert_equal 400, last_response.status
  end

  # --- authorization ------------------------------------------------------

  # RULE: a record is published by its author and nobody else. The routes take
  # no pubkey -- they use the session's -- so publishing as somebody else is
  # not expressible rather than being a check that has to stay correct.
  def test_publishing_requires_a_session
    clear_cookies
    put_json "/api/identity", identity_body

    assert_equal 401, last_response.status
  end
end
