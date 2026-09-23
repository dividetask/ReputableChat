# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/cryptography/vault"
require "open3"
require "json"

# The vault is written by a browser and, for the genesis account, by a terminal.
# If these two implementations disagree the failure is silent in the worst way:
# each one opens its own vaults perfectly and cannot read the other's, so the
# genesis account's friend list appears to vanish and come back depending on
# which one last wrote it.
#
# So the test is deliberately cross-directional. Ruby sealing and Ruby
# unsealing proves nothing about the browser.
class VaultParitySpec < Minitest::Test
  Vault  = ReputableChat::Cryptography::Vault
  SCRIPT = File.expand_path("vault_parity.mjs", __dir__)
  DOMAIN = "reputablechat:vault:v1"
  SEED   = 7

  # Nested objects, unicode, an empty list and a negative number: the shapes a
  # real vault holds, since what is sealed is JSON and JSON is where the two
  # languages can differ.
  CONTENTS = {
    "friends"  => [{ "pubkey" => "aaa", "handle" => "Tim", "at" => 1 }],
    "seen"     => [],
    "voted"    => %w[one two],
    "settings" => { "display" => { "show_unrated" => true }, "offset" => -3 },
    "note"     => "café — ünicode"
  }.freeze

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def node(input)
    stdout, stderr, status = Open3.capture3("node", SCRIPT, stdin_data: JSON.generate(input))
    flunk "node failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def raw_seed = ([SEED] * 32).pack("C*")

  def key = Vault.derive_key(raw_seed, DOMAIN)

  # RULE: both sides derive the same vault key from the same Argon2id output.
  def test_the_derived_key_is_identical_in_both_languages
    assert_equal Vault.b64url(key), node(op: "key", seed: SEED, domain: DOMAIN).fetch("key"),
                 "HKDF over the vault domain gives different keys in Ruby and JavaScript"
  end

  # RULE: what the browser seals, the terminal can open.
  def test_ruby_opens_a_vault_the_browser_sealed
    sealed = node(op: "seal", seed: SEED, domain: DOMAIN, value: CONTENTS)
    opened = Vault.unseal(key, ciphertext: sealed.fetch("ciphertext"), iv: sealed.fetch("iv"))

    assert_equal CONTENTS, opened, "Ruby cannot open a vault sealed by the browser"
  end

  # RULE: and the other way round, which is the direction the genesis CLI needs.
  def test_the_browser_opens_a_vault_ruby_sealed
    sealed = Vault.seal(key, CONTENTS)
    opened = node(op: "unseal", seed: SEED, domain: DOMAIN,
                  ciphertext: sealed.fetch("ciphertext"), iv: sealed.fetch("iv"))

    assert_equal CONTENTS, opened, "the browser cannot open a vault sealed by Ruby"
  end

  # RULE: the domain separates. A key derived under another domain must not open
  # a vault, or `vault_domain` is decorative and the identity seed is reused.
  def test_another_domain_does_not_open_it
    sealed = Vault.seal(key, CONTENTS)
    other  = Vault.derive_key(raw_seed, "reputablechat:elsewhere:v1")

    assert_nil Vault.unseal(other, ciphertext: sealed.fetch("ciphertext"), iv: sealed.fetch("iv"))
  end

  # RULE: the tag is checked. AES-GCM without an authenticated tag would let the
  # server alter a vault it cannot read.
  def test_a_tampered_vault_does_not_open
    sealed = Vault.seal(key, CONTENTS)
    broken = sealed.fetch("ciphertext")[0...-4] + "AAAA"

    assert_nil Vault.unseal(key, ciphertext: broken, iv: sealed.fetch("iv"))
  end

  # RULE: a fresh nonce per write. Reusing one under AES-GCM leaks the XOR of
  # the two plaintexts, and a vault is rewritten on every change.
  def test_sealing_twice_uses_a_fresh_nonce
    first  = Vault.seal(key, CONTENTS)
    second = Vault.seal(key, CONTENTS)

    refute_equal first.fetch("iv"), second.fetch("iv")
    refute_equal first.fetch("ciphertext"), second.fetch("ciphertext")
  end
end
