# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "rack/test"
require "ed25519"
require "tmpdir"
require "reputable_chat/app"

# Notices are how a chain says something official about itself. They are the
# only records meant to be read as statements rather than as data, so what can
# be said, and what cannot be unsaid, are both worth pinning down.
class NoticeSpec < Minitest::Test
  include Rack::Test::Methods

  Sig     = ReputableChat::Cryptography::Signature
  Payload = ReputableChat::Cryptography::Payload
  Canon   = ReputableChat::Cryptography::Canonical

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

  def post_json(path, body)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json"
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

  def notice_body(revision: 1, kind: "policy", title: "A title", body: "A body.",
                  supersedes: nil)
    ts = Time.now.to_i
    payload = Payload.notice(pubkey: @pubkey, revision: revision, kind: kind,
                             title: title, body: body, ack: ack, issued_at: ts,
                             supersedes: supersedes)
    { "revision" => revision, "kind" => kind, "title" => title, "body" => body,
      "supersedes" => supersedes, "ack" => ack, "ts" => ts, "signature" => sign(payload) }
  end

  def publish(**kwargs)
    post_json "/api/notice", notice_body(**kwargs)
    json
  end

  def test_publishes_a_notice_and_serves_it_back
    publish(kind: "outage", title: "Planned outage", body: "02:00-03:00 UTC Friday.")
    assert_equal 200, last_response.status

    get "/api/notice/#{@pubkey}"
    notice = json["notices"].first

    assert_equal "outage", notice["kind"]
    assert_equal "Planned outage", notice["title"]
    assert_equal "02:00-03:00 UTC Friday.", JSON.parse(notice["payload"])["body"]
  end

  # RULE: a kind must be one the server publishes. An arbitrary string would be
  # stored and then rendered back to everyone, and a client cannot present
  # something it has never heard of.
  def test_refuses_an_unknown_kind
    post_json "/api/notice", notice_body(kind: "whatever")

    assert_equal 400, last_response.status
  end

  def test_the_published_kinds_are_served
    get "/api/notice-kinds"

    assert_equal 200, last_response.status
    assert_includes json["kinds"], "founding"
  end

  # RULE: a correction is a new record pointing at the old one, never an edit.
  # A mutated record no longer matches its signature, and the point of a notice
  # is that what was said stays there to be checked.
  def test_a_correction_is_a_new_record_and_the_old_one_survives
    first = publish(revision: 1, title: "02:00 UTC")["hash"]
    publish(revision: 2, title: "03:00 UTC, corrected", supersedes: first)
    assert_equal 200, last_response.status

    get "/api/notice/#{@pubkey}"
    notices = json["notices"]

    assert_equal 2, notices.size, "the superseded notice must survive"
    assert_equal first, notices.first["supersedes"]
    assert_equal [2, 1], notices.map { |n| n["revision"] }, "newest first"
  end

  # RULE: the founding notice is the one that replaces nothing. Anything else
  # claiming to be one would give a chain two bottoms.
  def test_a_founding_notice_cannot_supersede_anything
    first = publish(revision: 1, kind: "policy")["hash"]

    post_json "/api/notice", notice_body(revision: 2, kind: "founding", supersedes: first)

    assert_equal 400, last_response.status
  end

  def test_a_founding_notice_that_supersedes_nothing_is_fine
    post_json "/api/notice", notice_body(kind: "founding", title: "What this is")

    assert_equal 200, last_response.status
  end

  # RULE: a revision cannot be reused. Reusing one would let a second statement
  # slip in behind the first at the same number.
  def test_a_revision_cannot_be_reused
    body = notice_body(revision: 1)
    post_json "/api/notice", body
    assert_equal 200, last_response.status

    post_json "/api/notice", body
    assert_equal 409, last_response.status
  end

  # RULE: everything is signed, so nothing can be swapped in transit -- not the
  # title, not the body, and not what it claims to supersede.
  def test_refuses_a_notice_whose_body_was_altered
    post_json "/api/notice", notice_body(body: "the real body").merge("body" => "something else")

    assert_equal 400, last_response.status
  end

  def test_refuses_a_notice_whose_supersedes_was_altered
    first = publish(revision: 1)["hash"]

    post_json "/api/notice",
              notice_body(revision: 2, supersedes: first).merge("supersedes" => "0" * 64)

    assert_equal 400, last_response.status
  end

  # RULE: a notice is bounded. The founding one is a document, so the limit is
  # generous, but every record is stored, served and signed forever.
  def test_refuses_an_oversized_body
    post_json "/api/notice", notice_body(body: "x" * (ReputableChat::Params::MAX_NOTICE + 1))

    assert_equal 400, last_response.status
  end

  def test_publishing_requires_a_session
    clear_cookies
    post_json "/api/notice", notice_body

    assert_equal 401, last_response.status
  end
end
