# frozen_string_literal: true

require_relative "spec_helper"
require_relative "chain_helper"
require "digest"

# What makes a record valid on its own (docs/project/rules/v0.001.md, sections
# 1 to 7 and 9 to 11, the parts that need no history), as Chain::Record checks
# it. Each test names the rule it protects.
class RecordSpec < Minitest::Test
  include ChainHelper

  def setup
    @key = new_key
    @pubkey = ChainHelper.key_of(@key)
    @id = "a" * 64
  end

  def msg(**fields)
    Payload.message(id: @id, pubkey: @pubkey, body: "hi", ack: ["b" * 64], ts: 1, **fields)
  end

  def refuses(pattern, payload)
    error = assert_raises(Invalid) { signed(payload, @key) }
    assert_match pattern, error.message
  end

  def accepts(payload) = assert(signed(payload, @key))

  def raw(canonical, key: @key) = Record.parse(canonical, Crypto::Signature.encode(key.sign(canonical.b)))

  # --- section 1 ----------------------------------------------------------------

  def test_the_record_hash_is_the_payload_a_newline_and_the_signature
    record = signed(msg, @key)
    expected = Digest::SHA256.hexdigest("#{record.payload}\n#{record.signature}")

    assert_equal expected, record.record_hash
  end

  def test_a_payload_must_be_in_canonical_form
    error = assert_raises(Invalid) { raw('{"type":"x", "ack":[]}') }
    assert_match(/canonical/, error.message)
  end

  def test_a_payload_holds_no_floating_point_numbers
    error = assert_raises(Invalid) { raw(Crypto::Canonical.dump(msg).sub('"ts":1', '"ts":1.5')) }
    assert_match(/floating-point/, error.message)
  end

  def test_the_signature_verifies_against_a_carried_key
    canonical = Crypto::Canonical.dump(msg)
    error = assert_raises(Invalid) { raw(canonical, key: new_key) }
    assert_match(/verifies against no key/, error.message)
  end

  def test_text_has_no_surrounding_whitespace
    refuses(/surrounding whitespace/, msg(body: " hi"))
    refuses(/surrounding whitespace/, msg(body: "hi\n"))
    accepts(msg(body: "two\nlines"))
  end

  def test_text_has_no_control_characters_but_tab_newline_and_return
    refuses(/control character/, msg(body: "bell\u0007"))
    accepts(msg(body: "a\tb\r\nc"))
  end

  def test_a_decimal_has_exactly_one_spelling
    score = ->(value) { Payload.attestation(id: @id, pubkey: @pubkey, ack: ["b" * 64], ts: 1,
                                            scores: { @id => { "reputation" => value, "trust" => "1" } }) }

    %w[0.5 -0.5 0 1 -1 0.123456789012345678].each { |good| accepts(score.call(good)) }
    %w[.5 0.50 -0 00.5 +0.5 1.0 0.1234567890123456789].each do |bad|
      refuses(/decimal from -1 to \+1/, score.call(bad))
    end
    refuses(/decimal from -1 to \+1/, score.call("1.5"))
  end

  def test_a_signing_key_has_one_spelling
    refuses(/pubkey is not a signing key/, msg.merge("pubkey" => "#{@pubkey}="))
  end

  # --- section 2 ------------------------------------------------------------------

  def test_the_type_names_the_rules_version_and_a_known_record_type
    refuses(/fewer than three parts/, msg.merge("type" => "reputablechat:message"))
    refuses(/not a record type/, msg.merge("type" => "reputablechat:emote:v0.001"))
    refuses(/lowercase/, msg.merge("type" => "reputablechat:message:V0.001"))
    accepts(msg.merge("type" => "reputablechat:message:v0.001:chat:extra"))
  end

  def test_every_record_but_a_first_declaration_carries_an_account_id
    refuses(/id is required/, msg.except("id"))
  end

  def test_body_is_required_and_may_be_empty
    refuses(/body is required/, msg.except("body"))
    accepts(msg(body: ""))
  end

  def test_ack_is_sorted_without_duplicates_and_at_most_sixteen
    refuses(/not sorted/, msg.merge("ack" => ["b" * 64, "a" * 64]))
    refuses(/repeats/, msg.merge("ack" => ["a" * 64, "a" * 64]))
    refuses(/limit is 16/, msg.merge("ack" => (0..16).map { |i| format("%064x", i) }))
  end

  def test_ack_is_empty_in_the_genesis_and_nowhere_else
    refuses(/genesis record and nowhere else/, msg.merge("ack" => []))
    genesis = Payload.identity(pubkey: @pubkey, handle: "Tim", ack: [], ts: 1)
    refuses(/genesis record and nowhere else/, genesis)
    accepts(genesis.merge("rules" => "the rules"))
  end

  def test_rules_are_carried_by_the_genesis_and_releases_only
    refuses(/genesis record and releases only/, msg.merge("rules" => "more rules"))
  end

  def test_a_field_the_rules_do_not_define_is_refused
    refuses(/does not carry note/, msg.merge("note" => "hello"))
    refuses(/does not carry scores/, msg.merge("scores" => {}))
  end

  def test_a_record_carries_a_key_and_a_first_declaration_carries_the_working_key
    refuses(/carries pubkey, mpubkey or both/, msg.except("pubkey"))
    first = Payload.identity(pubkey: @pubkey, handle: "A", ack: ["b" * 64], ts: 1)
    first["mpubkey"] = first.delete("pubkey")
    refuses(/requires pubkey/, first)
  end

  def test_files_are_a_hash_and_an_extension
    refuses(/not a file/, msg(file: ["avatar.png"]))
    refuses(/not a file/, msg(file: ["#{'a' * 64}.PNG"]))
    accepts(msg(file: ["#{'a' * 64}.avif"]))
  end

  def test_a_url_holds_no_whitespace
    refuses(/url holds whitespace/, msg(url: "https://example.com/a b"))
  end

  def test_a_transfer_issues_spends_or_destroys
    issue = { "out" => [{ "to" => @id, "value" => "1" }] }
    accepts(msg(transfer: issue))
    refuses(/omitted only when issuing/, msg(transfer: issue.merge("currency" => @id)))
    refuses(/names its currency/, msg(transfer: { "in" => ["c" * 64] }))
    refuses(/greater than zero/, msg(transfer: { "out" => [{ "to" => @id, "value" => "0" }] }))
    accepts(msg(transfer: { "currency" => @id, "in" => ["c" * 64] }))
  end

  # --- sections 3 to 10 -------------------------------------------------------------

  def test_an_identity_declaration_requires_a_handle_of_at_most_64_bytes
    refuses(/the handle is not 1 to 64 bytes/, Payload.identity(pubkey: @pubkey, handle: "x" * 65, ack: ["b" * 64], ts: 1))
  end

  def test_an_attestation_requires_scores_and_entries_hold_reputation_and_trust
    refuses(/requires scores/, Payload.attestation(id: @id, pubkey: @pubkey, scores: nil, ack: ["b" * 64], ts: 1))
    refuses(/keyed by/, Payload.attestation(id: @id, pubkey: @pubkey, scores: { @pubkey => { "reputation" => "1", "trust" => "1" } },
                                            ack: ["b" * 64], ts: 1))
    refuses(/holds reputation and trust/, Payload.attestation(id: @id, pubkey: @pubkey, scores: { @id => { "reputation" => "1" } },
                                                              ack: ["b" * 64], ts: 1))
  end

  def test_a_reaction_requires_a_target
    refuses(/requires target/, Payload.reaction(id: @id, pubkey: @pubkey, body: "+1", target: nil, ack: ["b" * 64], ts: 1))
  end

  def test_a_key_change_carries_the_new_key_and_nothing_else
    change = ->(body) { Payload.notice(id: @id, pubkey: @pubkey, kind: "key-change", body: body, ack: ["b" * 64], ts: 1) }
    refuses(/new key and nothing else/, change.call("#{@pubkey} please"))
    accepts(change.call(ChainHelper.key_of(new_key)))
  end

  def test_a_quorum_names_exactly_one_record
    quorum = Payload.notice(id: @id, pubkey: @pubkey, kind: "quorum", body: "", target: ["c" * 64, "d" * 64],
                            ack: ["b" * 64], ts: 1)
    refuses(/exactly one record/, quorum)
  end

  def test_a_heartbeat_has_an_empty_body
    refuses(/body is empty/, Payload.heartbeat(id: @id, pubkey: @pubkey, ack: ["b" * 64], ts: 1).merge("body" => "x"))
  end

  def test_a_heartbeat_may_ack_up_to_a_mebibyte_of_hashes
    many = (0...1_000).map { |i| format("%064x", i) }
    accepts(Payload.heartbeat(id: @id, pubkey: @pubkey, ack: many, ts: 1))
  end
end
