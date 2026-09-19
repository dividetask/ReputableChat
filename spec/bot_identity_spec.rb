# frozen_string_literal: true

require_relative "spec_helper"
require "reputable_chat/bot/identity"
require "open3"
require "yaml"

# A bot signs outside the browser, so its key has to be the key the browser
# would have derived from the same phrase. If these two ever diverge, a bot
# quietly becomes a different account -- its history, its reputation and
# anything anyone rated about it all left behind, with nothing failing.
#
# This is the same guard spec/canonical_parity_spec.rb provides for the
# serializer, and it runs the browser's own identity.js rather than a copy.
class BotIdentitySpec < Minitest::Test
  Identity = ReputableChat::Bot::Identity
  Seed     = ReputableChat::Cryptography::Seed

  SCRIPT = File.expand_path("bot_identity_parity.mjs", __dir__)

  def seed_config
    @seed_config ||= YAML.safe_load_file(
      File.expand_path("../config/reputation.yml", __dir__)
    ).fetch("seed")
  end

  def test_a_bots_key_is_the_key_the_browser_would_derive
    skip "node is not installed" unless node?

    phrases = [
      "twin eyebrow luggage breeze turn key clown captain",
      Identity.generate_phrase,
      Identity.generate_phrase(words: 12)
    ]

    kdf = seed_config.fetch("kdf").merge("min_words" => seed_config.fetch("min_words"))
    input = JSON.generate("phrases" => phrases, "kdf" => kdf)

    stdout, stderr, status = Open3.capture3("node", SCRIPT, stdin_data: input)
    flunk "node failed: #{stderr}" unless status.success?

    from_browser = stdout.split("\n").map(&:strip).reject(&:empty?)
    from_ruby    = phrases.map { |p| Identity.new(phrase: p, seed_config: seed_config).pubkey }

    assert_equal from_browser, from_ruby,
                 "the bot client and the browser derive different accounts from the same seed"
  end

  def test_the_same_phrase_always_gives_the_same_account
    first  = Identity.new(phrase: "twin eyebrow luggage breeze turn key clown captain",
                          seed_config: seed_config)
    second = Identity.new(phrase: "  TWIN Eyebrow LUGGAGE breeze turn key clown captain ",
                          seed_config: seed_config)

    assert_equal first.pubkey, second.pubkey, "case and spacing changed the identity"
  end

  def test_a_generated_phrase_is_one_the_login_screen_would_accept
    10.times do
      phrase = Identity.generate_phrase

      assert Seed.valid?(phrase), "generated an unusable seed: #{phrase}"
      assert_equal Seed::MIN_WORDS, phrase.split.size
    end
  end

  def test_a_phrase_too_short_to_be_an_account_is_refused
    assert_raises(Seed::InvalidSeed) do
      Identity.new(phrase: "twin eyebrow luggage", seed_config: seed_config)
    end
  end

  def test_signatures_verify_against_the_published_key
    identity = Identity.new(phrase: Identity.generate_phrase, seed_config: seed_config)
    payload  = { "purpose" => "test", "n" => 1 }

    assert ReputableChat::Cryptography::Signature.verify(
      pubkey_b64: identity.pubkey,
      signature_b64: identity.sign(payload),
      payload: payload
    )
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)
end
