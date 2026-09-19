# frozen_string_literal: true

require "ed25519"
require "json"
require "tmpdir"
require "reputable_chat/genesis"
require "reputable_chat/cryptography/canonical"
require "reputable_chat/cryptography/payload"
require "reputable_chat/cryptography/record"
require "reputable_chat/cryptography/signature"

# A throwaway genesis for the tests.
#
# Built with a plain Ed25519 key rather than through the seed derivation,
# because how the key was made is not something the record format knows or
# cares about -- and Argon2id at the real work factor in every test setup would
# be minutes of nothing.
module GenesisFixture
  Crypto = ReputableChat::Cryptography

  module_function

  def build(handle: "Tim", signing: Ed25519::SigningKey.generate)
    pubkey = Crypto::Signature.encode(signing.verify_key.to_bytes)

    payload = Crypto::Payload.user(
      pubkey: pubkey, version: 1, handle: handle, bio: "", icon: nil,
      ack: nil, issued_at: Time.now.to_i
    )
    canonical = Crypto::Canonical.dump(payload)
    signature = Crypto::Signature.encode(signing.sign(canonical.b))

    ReputableChat::Genesis.new({
      "pubkey" => pubkey, "payload" => canonical, "signature" => signature,
      "hash" => Crypto::Record.digest(payload: canonical, signature: signature)
    })
  end

  # The key as well, for tests that have to act AS the genesis account --
  # vouching for somebody, which is the only way anyone becomes visible.
  def build_with_key(**kwargs)
    signing = Ed25519::SigningKey.generate

    [build(signing: signing, **kwargs), signing]
  end

  # Writes one to disk, for the paths that load rather than receive it.
  def write(dir, **kwargs)
    genesis = build(**kwargs)
    path = File.join(dir, "genesis.json")
    File.write(path, JSON.generate(genesis.to_h))
    [genesis, path]
  end
end
