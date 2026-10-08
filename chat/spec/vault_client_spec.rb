# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "json"

# The browser half of the vault. The server can check that a blob came back
# unaltered and nothing else, so everything that makes the contents private is
# here and has no server-side guard at all.
class VaultClientSpec < Minitest::Test
  SCRIPT = File.expand_path("vault_client.mjs", __dir__)

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def result
    @result ||= begin
      stdout, stderr, status = Open3.capture3("node", SCRIPT)
      flunk "node failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end
  end

  def test_a_vault_round_trips
    assert_equal({ "display" => { "show_unrated" => true } },
                 result.fetch("round_trips").fetch("settings"))
    assert_equal %w[a b], result.fetch("round_trips").fetch("voted")
  end

  def test_the_sealed_form_is_what_the_server_will_accept
    assert result.fetch("ciphertext_is_base64url")
    assert result.fetch("iv_is_base64url")
  end

  # RULE: the vault key is separated by domain from everything else derived
  # from the same seed. A key derived under another domain must not open it,
  # or the separation is decorative.
  def test_another_domain_does_not_open_the_vault
    assert_nil result.fetch("wrong_domain")
  end

  def test_another_seed_does_not_open_the_vault
    assert_nil result.fetch("wrong_seed")
  end

  # RULE: a tampered ciphertext fails to open rather than yielding rubbish.
  # This is what makes the encryption also the integrity check, so the server
  # cannot alter a vault it cannot read.
  def test_a_tampered_vault_does_not_open
    assert_nil result.fetch("tampered")
  end

  # RULE: a fresh nonce every time. Reusing one under AES-GCM leaks the XOR of
  # the two plaintexts and breaks authentication -- and a vault is rewritten on
  # every change, so a fixed nonce would be reused constantly.
  def test_every_seal_uses_a_fresh_nonce
    refute result.fetch("nonce_reused"), "the nonce must not repeat"
    refute result.fetch("ciphertext_repeated"),
           "sealing the same contents twice must not produce the same bytes"
  end

  # RULE: a refused push means merge, not retry. Taking the server's copy drops
  # what this device did; overwriting drops what the other device did. Votes
  # union, because a vote recorded on either device is a thing that happened.
  def test_merging_unions_the_voted_list
    merged = result.fetch("merged_votes")

    assert_equal %w[remote shared local].sort, merged.fetch("voted").sort
  end

  # Settings take the local copy: this device is the one writing now.
  def test_merging_takes_the_local_settings
    assert_equal({ "a" => 1 }, result.fetch("merged_votes").fetch("settings"))
  end

  def test_merging_against_nothing_keeps_what_is_local
    assert_equal ["only"], result.fetch("merged_with_nothing").fetch("voted")
  end
end
