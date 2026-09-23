# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "reputable_chat/cryptography/record"
require "reputable_chat/cryptography/payload"
require "reputable_chat/params"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/reputation/fingerprint"
require "json"
require "ed25519"
require "tmpdir"
require "digest"
require "reputable_chat/store/images"

# The rules that make a pile of signatures into a chain.
class ChainSpec < Minitest::Test
  include SpecHelper

  Record      = ReputableChat::Cryptography::Record
  Payload     = ReputableChat::Cryptography::Payload
  Canonical   = ReputableChat::Cryptography::Canonical
  Fingerprint = ReputableChat::Reputation::Fingerprint

  def a_payload(body: "hello") = { "purpose" => "test", "body" => body }

  # --- record hashes ----------------------------------------------------

  # RULE: a record hash names the whole record, not just what was signed.
  # Signatures identified messages before the chain existed; a link has to
  # cover the signature too or the thing it names is only half pinned.
  def test_a_different_signature_is_a_different_record
    first  = Record.digest(payload: a_payload, signature: "AAAA")
    second = Record.digest(payload: a_payload, signature: "BBBB")

    refute_equal first, second
  end

  def test_a_different_payload_is_a_different_record
    first  = Record.digest(payload: a_payload(body: "hello"), signature: "AAAA")
    second = Record.digest(payload: a_payload(body: "hallo"), signature: "AAAA")

    refute_equal first, second
  end

  # RULE: a payload already in canonical form hashes to the same thing as the
  # object it came from. The server holds the bytes it was sent and hashes
  # those, because re-serializing a parsed payload is how signatures break.
  def test_a_canonical_string_hashes_the_same_as_the_object_it_came_from
    object = a_payload
    string = Canonical.dump(object)

    assert_equal Record.digest(payload: object, signature: "AAAA"),
                 Record.digest(payload: string, signature: "AAAA")
  end

  # RULE: the newline separators in the hash input are unambiguous, which holds
  # only because canonical JSON can never contain a raw newline. If that ever
  # stopped being true, two different records could hash to the same value.
  def test_canonical_output_never_contains_a_raw_newline
    canonical = Canonical.dump(a_payload(body: "one\ntwo\r\nthree"))

    refute_includes canonical, "\n"
    assert_includes canonical, '\n'
  end

  def test_refuses_to_hash_a_payload_containing_a_newline
    assert_raises(Record::MalformedPayload) do
      Record.digest(payload: "{\"a\":1}\n{\"b\":2}", signature: "AAAA")
    end
  end

  def test_a_record_hash_is_sixty_four_hex_characters
    assert Record.valid?(Record.digest(payload: a_payload, signature: "AAAA"))
    refute Record.valid?("not a hash")
    refute Record.valid?(("A".."F").to_a.join * 11)
  end

  # --- genesis -----------------------------------------------------------

  # RULE: the genesis is the one record that acknowledges nothing. Everything
  # else names something, which is what makes the history walkable.
  def test_the_genesis_acknowledges_nothing
    genesis = GenesisFixture.build

    assert_nil JSON.parse(genesis.payload)["ack"]
  end

  def test_the_genesis_hash_matches_its_contents
    genesis = GenesisFixture.build

    assert_equal genesis.hash,
                 Record.digest(payload: genesis.payload, signature: genesis.signature)
  end

  # RULE: a genesis is verified as it loads, not trusted. An edited or
  # truncated one would otherwise put every client on a slightly different
  # chain, and show up only as signatures failing for no visible reason.
  def test_a_genesis_whose_hash_does_not_match_its_contents_is_refused
    Dir.mktmpdir do |dir|
      genesis, path = GenesisFixture.write(dir)
      File.write(path, JSON.generate(genesis.to_h.merge("hash" => "0" * 64)))

      error = assert_raises(ReputableChat::Genesis::Corrupt) { ReputableChat::Genesis.load(path: path) }
      assert_match(/hash/, error.message)
    end
  end

  def test_a_genesis_signed_by_someone_else_is_refused
    Dir.mktmpdir do |dir|
      genesis, path = GenesisFixture.write(dir)
      impostor = GenesisFixture.build

      # Its own hash still checks out; only the key it claims is wrong.
      swapped = genesis.to_h.merge("pubkey" => impostor.pubkey)
      File.write(path, JSON.generate(swapped))

      assert_raises(ReputableChat::Genesis::Corrupt) { ReputableChat::Genesis.load(path: path) }
    end
  end

  # RULE: a genesis written against an older payload shape is refused, even
  # though its signature still verifies perfectly -- the signature covers the
  # bytes it was made from, and those have not changed. Every record signed
  # since carries a different field list, and a reader looking for a field this
  # one lacks would find nil and carry on.
  def test_a_genesis_written_against_an_older_shape_is_refused
    Dir.mktmpdir do |dir|
      genesis, path = GenesisFixture.write(dir)
      stale = JSON.parse(genesis.payload)
      stale["version"] = stale.delete("revision")

      # Re-signed, so only the shape is wrong and nothing else.
      signing = Ed25519::SigningKey.generate
      canonical = Canonical.dump(stale.merge("pubkey" => genesis.pubkey))
      signature = ReputableChat::Cryptography::Signature.encode(signing.sign(canonical.b))
      File.write(path, JSON.generate(
        "pubkey" => ReputableChat::Cryptography::Signature.encode(signing.verify_key.to_bytes),
        "payload" => canonical, "signature" => signature,
        "hash" => Record.digest(payload: canonical, signature: signature)
      ))

      error = assert_raises(ReputableChat::Genesis::Corrupt) { ReputableChat::Genesis.load(path: path) }
      assert_match(/older payload shape/, error.message)
      assert_match(/revision/, error.message)
    end
  end

  # --- the genesis avatar -------------------------------------------------

  # A one-pixel PNG, so the rules can be checked without a fixture file.
  TINY_PNG = [
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a",
    "49444154789c6360000002000100ffff03000006000557bfabd40000000049454e44ae426082"
  ].join.freeze

  def a_png = [TINY_PNG].pack("H*")

  # RULE: the genesis avatar's name is the hash of the committed bytes, like
  # every other image. It is committed rather than uploaded only because the
  # record naming it is read before any client has fetched anything, and the
  # image store is not in the repository.
  def test_installing_the_genesis_icon_yields_the_name_it_declares
    Dir.mktmpdir do |dir|
      images = ReputableChat::Store::Images.new(File.join(dir, "images"))
      name = images.store(a_png)
      path = File.join(dir, "development.png")
      File.binwrite(path, a_png)

      genesis = GenesisFixture.build(icon: name)

      assert_equal name, genesis.install_icon(images, path: path)
      assert_equal a_png, images.read(name)
    end
  end

  # RULE: a committed image that is not the one the declaration was signed over
  # is refused. Left alone it would show up as a broken avatar and nothing
  # else, which is the quietest possible way for a signed claim to be wrong.
  def test_an_icon_that_does_not_match_the_declaration_is_refused
    Dir.mktmpdir do |dir|
      images = ReputableChat::Store::Images.new(File.join(dir, "images"))
      path = File.join(dir, "development.png")
      File.binwrite(path, a_png)

      genesis = GenesisFixture.build(icon: "#{'0' * 64}.png")

      error = assert_raises(ReputableChat::Genesis::Corrupt) { genesis.install_icon(images, path: path) }
      assert_match(/declares/, error.message)
    end
  end

  def test_a_genesis_without_an_icon_installs_nothing
    Dir.mktmpdir do |dir|
      images = ReputableChat::Store::Images.new(File.join(dir, "images"))

      assert_nil GenesisFixture.build.install_icon(images, path: nil)
    end
  end

  # RULE: the committed avatar is found by environment, the same way the record
  # and the seed are.
  def test_the_committed_development_icon_matches_its_declaration
    path = ReputableChat::Genesis.icon_path("development")
    skip "no development icon committed" unless path

    genesis = ReputableChat::Genesis.load(path: ReputableChat::Genesis.path("development"))
    expected = "#{Digest::SHA256.hexdigest(File.binread(path))}#{File.extname(path)}"

    assert_equal expected, genesis.icon
  end

  def test_a_missing_genesis_says_how_to_make_one
    Dir.mktmpdir do |dir|
      error = assert_raises(ReputableChat::Genesis::Missing) do
        ReputableChat::Genesis.load(path: File.join(dir, "nothing.json"))
      end

      assert_match(/rake genesis/, error.message)
    end
  end

  # --- parameter fingerprints --------------------------------------------

  # RULE: an attestation's published scores carry the parameters they were
  # computed under. Reputation is subjective and configuration is per-user, so
  # a reader has to be able to tell whether the numbers mean anything to them
  # rather than silently adopting a stranger's settings.
  def test_retuning_the_curve_changes_the_fingerprint
    refute_equal Fingerprint.of(config),
                 Fingerprint.of(config("vote_curve" => { "a" => "0.0005" }))
  end

  def test_the_same_parameters_fingerprint_the_same
    assert_equal Fingerprint.of(config), Fingerprint.of(config)
  end

  # RULE: only what can move a number is in the fingerprint. Including
  # everything would expire every published cache on an unrelated change.
  def test_a_setting_that_cannot_move_a_score_does_not_change_the_fingerprint
    assert_equal Fingerprint.of(config),
                 Fingerprint.of(config("session" => { "verify_signatures" => true }))
  end

  # --- payload shapes ----------------------------------------------------

  # RULE: every shared record carries `ack`. A shape that quietly omitted it
  # would be a record nothing else could anchor to.
  def test_every_shared_record_shape_carries_an_ack
    shapes = {
      "identity" => Payload.identity(pubkey: "k", revision: 1, handle: "t", bio: "", icon: nil,
                             ack: "a", issued_at: 1),
      "attestation" => Payload.attestation(pubkey: "k", revision: 1, scores: {}, derived: {},
                                           ack: "a", issued_at: 1),
      "adjustment" => Payload.adjustment(pubkey: "k", base_revision: 1, seq: 1, target: "t",
                                         reputation: "0.5", trust: "1", ack: "a", issued_at: 1),
      "message" => Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                                   ack: "a", issued_at: 1),
      "emote" => Payload.emote(author: "k", room: "r", message: "m", emote: "+",
                               ack: "a", issued_at: 1),
      "release" => Payload.release(publisher: "k", revision: 1, label: "0.1.0", files: {},
                                   notes: "", ack: "a", issued_at: 1)
    }

    shapes.each { |name, payload| assert_equal "a", payload["ack"], "#{name} lost its ack" }
  end

  # RULE: every shared record can carry a note, and it is null unless set.
  # The slot exists from the start because adding a field later changes the
  # canonical bytes of every record and invalidates every signature ever made.
  def test_every_shared_record_shape_carries_a_note_slot
    shapes.each do |name, payload|
      assert payload.key?("note"), "#{name} has no note slot"
      assert_nil payload["note"], "#{name} defaults its note to something other than null"
    end
  end

  # RULE: an absent note and an empty one are the same record. Otherwise two
  # records a reader would call identical would carry different signatures.
  def test_an_empty_note_is_the_same_record_as_no_note
    absent = Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                             ack: "a", issued_at: 1)
    empty = Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                            ack: "a", issued_at: 1, note: ReputableChat::Params.note("   "))

    assert_equal Canonical.dump(absent), Canonical.dump(empty)
  end

  # RULE: the note is inside the signed payload, so it cannot be attached to
  # somebody else's record or edited after the fact.
  def test_a_note_changes_the_record
    without = Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                              ack: "a", issued_at: 1)
    with = Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                           ack: "a", issued_at: 1, note: "for whoever reads this")

    refute_equal Record.digest(payload: without, signature: "AAAA"),
                 Record.digest(payload: with, signature: "AAAA")
  end

  # RULE: a note is bounded. It rides inside every record it is set on and is
  # signed there permanently, so it cannot be a place to park a document.
  def test_an_oversized_note_is_refused
    assert_nil ReputableChat::Params.note("x" * (ReputableChat::Params::MAX_NOTE + 1))
    assert ReputableChat::Params.note("x" * ReputableChat::Params::MAX_NOTE)
  end

  # Newlines and tabs are allowed -- a note is prose for a person. Everything
  # else in the control range is not.
  def test_a_note_may_span_lines_but_carries_no_control_characters
    assert ReputableChat::Params.note("first line\nsecond line\twith a tab")
    assert_nil ReputableChat::Params.note("sneaky\x00null")
  end

  def shapes
    {
      "identity" => Payload.identity(pubkey: "k", revision: 1, handle: "t", bio: "", icon: nil,
                             ack: "a", issued_at: 1),
      "attestation" => Payload.attestation(pubkey: "k", revision: 1, scores: {}, derived: {},
                                           ack: "a", issued_at: 1),
      "adjustment" => Payload.adjustment(pubkey: "k", base_revision: 1, seq: 1, target: "t",
                                         reputation: "0.5", trust: "1", ack: "a", issued_at: 1),
      "message" => Payload.message(author: "k", room: "r", seq: 1, prev: nil, body: "b",
                                   ack: "a", issued_at: 1),
      "emote" => Payload.emote(author: "k", room: "r", message: "m", emote: "+",
                               ack: "a", issued_at: 1),
      "release" => Payload.release(publisher: "k", revision: 1, label: "0.1.0", files: {},
                                   notes: "", ack: "a", issued_at: 1)
    }
  end

  # RULE: the private vault has no ack. Nobody else ever sees it, so there is
  # nothing to anchor it to and nobody to prove anything to.
  def test_the_vault_has_no_ack
    payload = Payload.vault(pubkey: "k", revision: 1, ciphertext: "c", iv: "i", issued_at: 1)

    refute payload.key?("ack")
  end

  # RULE: the key rotation placeholders are in the signed shape from the start.
  # Adding a field later changes the canonical bytes of every record, which
  # invalidates every signature ever made.
  def test_the_key_rotation_placeholders_are_present_and_null
    payload = Payload.identity(pubkey: "k", revision: 1, handle: "t", bio: "", icon: nil,
                           ack: nil, issued_at: 1)

    assert payload.key?("master_pubkey")
    assert payload.key?("previous_pubkey")
    assert_nil payload["master_pubkey"]
    assert_nil payload["previous_pubkey"]
  end
end
