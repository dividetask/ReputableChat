# frozen_string_literal: true

require "ed25519"
require "json"
require "tmpdir"
require "reputable_chat/genesis"
require "reputable_chat/host"
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

  def build(handle: "Tim", icon: nil)
    signing = Ed25519::SigningKey.generate
    pubkey  = Crypto::Signature.encode(signing.verify_key.to_bytes)

    payload = Crypto::Payload.identity(
      pubkey: pubkey, revision: 1, handle: handle, bio: "", icon: icon,
      ack: nil, issued_at: Time.now.to_i
    )
    canonical = Crypto::Canonical.dump(payload)
    signature = Crypto::Signature.encode(signing.sign(canonical.b))

    ReputableChat::Genesis.new({
      "pubkey" => pubkey, "payload" => canonical, "signature" => signature,
      "hash" => Crypto::Record.digest(payload: canonical, signature: signature)
    })
  end

  # A host account acknowledging `genesis`, or whatever `ack` says instead.
  # `host_record` is the raw hash, for the paths that must see a check refuse it.
  def host_record(genesis:, ack: genesis.hash, handle: "Host")
    signing = Ed25519::SigningKey.generate
    pubkey  = Crypto::Signature.encode(signing.verify_key.to_bytes)

    payload = Crypto::Payload.identity(
      pubkey: pubkey, revision: 1, handle: handle, bio: "", icon: nil,
      ack: ack, issued_at: Time.now.to_i
    )
    canonical = Crypto::Canonical.dump(payload)
    signature = Crypto::Signature.encode(signing.sign(canonical.b))

    { "pubkey" => pubkey, "payload" => canonical, "signature" => signature,
      "hash" => Crypto::Record.digest(payload: canonical, signature: signature) }
  end

  def build_host(genesis:, **kwargs)
    ReputableChat::Host.new(host_record(genesis: genesis, **kwargs), genesis: genesis)
  end

  # Writes one to disk, for the paths that load rather than receive it.
  def write(dir, **kwargs)
    genesis = build(**kwargs)
    path = File.join(dir, "genesis.json")
    File.write(path, JSON.generate(genesis.to_h))
    [genesis, path]
  end
end
