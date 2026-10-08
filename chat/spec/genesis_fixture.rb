# frozen_string_literal: true

require "ed25519"
require "json"
require "tmpdir"
require "reputable_chat/genesis"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/signature"
require "reputable_chat/cryptography/record"

# A throwaway genesis for the tests.
#
# Built with a plain Ed25519 key rather than through the seed derivation,
# because how the key was made is not something the record format knows or
# cares about -- and Argon2id at the real work factor in every test setup would
# be minutes of nothing.
module GenesisFixture
  Crypto = ReputableChat::Cryptography

  RULES = "ReputableChat rules, version 0.001 (a test genesis)"

  module_function

  # The genesis, and the key that signed it, for a test that signs as it.
  def build_with_key(handle: "Tim", icon: nil)
    signing = Ed25519::SigningKey.generate
    pubkey  = Crypto::Signature.encode(signing.verify_key.to_bytes)

    payload = Crypto::Payload.identity(pubkey: pubkey, handle: handle, avatar: icon, ack: [],
                                       ts: Time.now.to_i, rules: RULES)
    [ReputableChat::Genesis.new(signed(signing, payload)), signing]
  end

  def build(**kwargs) = build_with_key(**kwargs).first

  def signed(signing, payload)
    canonical = Crypto::Canonical.dump(payload)
    signature = Crypto::Signature.encode(signing.sign(canonical.b))
    # Hashed rather than parsed, so a test can build a record the checks are
    # meant to refuse.
    hash = Crypto::Record.digest(payload: canonical, signature: signature)

    { "payload" => canonical, "signature" => signature, "hash" => hash }
  end

  # Writes one to disk, for the paths that load rather than receive it.
  def write(dir, **kwargs)
    genesis = build(**kwargs)
    path = File.join(dir, "genesis.json")
    File.write(path, JSON.generate(genesis.to_h))
    [genesis, path]
  end
end
