# frozen_string_literal: true

require_relative "spec_helper"
require_relative "genesis_fixture"
require "reputable_chat/cryptography/record"
require "reputable_chat/cryptography/payload"
require "reputable_chat/genesis"
require "reputable_chat/cryptography/canonical"
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

  def a_payload(body: "hello") = { "type" => "test", "body" => body }

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

  # RULE: the genesis is the one record that acknowledges nothing, and it
  # carries the rules. Everything else names something, which is what makes
  # the history walkable.
  def test_the_genesis_acknowledges_nothing_and_carries_the_rules
    genesis = GenesisFixture.build

    assert_equal [], JSON.parse(genesis.payload)["ack"]
    assert genesis.record.first_declaration?
    assert_equal GenesisFixture::RULES, genesis.declaration["rules"]
  end

  def test_the_genesis_hash_matches_its_contents
    genesis = GenesisFixture.build

    assert_equal genesis.hash,
                 Record.digest(payload: genesis.payload, signature: genesis.signature)
    assert_equal genesis.hash, genesis.account, "a first declaration's hash is its account ID"
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

      # Its hash re-derived, so only the signature is wrong.
      swapped = genesis.to_h.merge(
        "signature" => impostor.signature,
        "hash" => Record.digest(payload: genesis.payload, signature: impostor.signature)
      )
      File.write(path, JSON.generate(swapped))

      error = assert_raises(ReputableChat::Genesis::Corrupt) { ReputableChat::Genesis.load(path: path) }
      assert_match(/does not verify/, error.message)
    end
  end

  # RULE: a genesis in an older shape is refused, even though its signature
  # verifies perfectly -- the signature covers the bytes it was made from.
  # Whether a genesis is valid under the rules is the agnostic server's to say;
  # this is the chat noticing it is not one at all.
  def test_a_genesis_written_against_an_older_shape_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "genesis.json")
      signing = Ed25519::SigningKey.generate
      pubkey = ReputableChat::Cryptography::Signature.encode(signing.verify_key.to_bytes)
      old = { "purpose" => "reputablechat:identity:v1", "pubkey" => pubkey, "revision" => 1,
              "handle" => "Tim", "ack" => nil, "ts" => 1 }
      canonical = Canonical.dump(old)
      signature = ReputableChat::Cryptography::Signature.encode(signing.sign(canonical.b))
      File.write(path, JSON.generate("payload" => canonical, "signature" => signature,
                                     "hash" => Record.digest(payload: canonical, signature: signature)))

      error = assert_raises(ReputableChat::Genesis::Corrupt) { ReputableChat::Genesis.load(path: path) }
      assert_match(/not a first identity declaration/, error.message)
    end
  end

  # RULE: the committed genesis carries the founding rules, read straight from
  # their file. If the two differ, the chain and the repository disagree about
  # what the rules are.
  def test_the_development_genesis_carries_the_rules_file
    genesis = ReputableChat::Genesis.load(path: ReputableChat::Genesis.path("development"))
    rules = File.read(File.expand_path("../../docs/project/rules/v0.001.md", __dir__), encoding: "UTF-8").strip

    assert_equal rules, genesis.declaration["rules"],
                 "docs/project/rules/v0.001.md has changed since the genesis was made"
  end

  # RULE: the developer's account declares a master key as well as a working
  # key. (A server's host account is its agnostic server's, which does the same.)
  def test_the_committed_genesis_declares_a_master_key
    genesis = ReputableChat::Genesis.load(path: ReputableChat::Genesis.path("development"))

    assert genesis.mpubkey, "the genesis declares no master key"
    refute_equal genesis.pubkey, genesis.mpubkey
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

  # --- payload shapes ----------------------------------------------------

  # RULE: a field with no value is left out, not written as null, so a record
  # has one spelling; and lists the rules require sorted are sorted.
  def test_payloads_leave_out_absent_fields_and_sort_their_lists
    payload = Payload.message(id: "i", pubkey: "k", body: "b", ack: %w[b a a], ts: 1)

    refute payload.key?("target")
    refute payload.values.include?(nil)
    assert_equal %w[a b], payload["ack"]
    assert_equal "reputablechat:message:v0.001:chat", payload["type"]
  end

  # RULE: the private vault is not a record on the chain. Nobody else ever sees
  # it, so there is nothing to anchor it to and nobody to prove anything to.
  def test_the_vault_has_no_ack
    payload = Payload.vault(pubkey: "k", revision: 1, ciphertext: "c", iv: "i", issued_at: 1)

    refute payload.key?("ack")
  end
end
