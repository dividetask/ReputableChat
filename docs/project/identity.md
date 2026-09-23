# Identity

There is no username at login and no password in the usual sense. A seed phrase
*is* the account: it derives a keypair, and the public half is the identity.

## Seed phrases

- **BIP39 English wordlist**, 2048 words, 11 bits each. Chosen because it is
  well tested, has vetted translations, and guarantees the first four letters
  identify a word — which makes type-ahead reliable and removes spelling as a
  failure mode.
- **Minimum 8 words.** 88 bits total: 80 entropy plus an 8-bit checksum.
- Longer seeds are accepted; each extra word adds 11 bits.
- The word count is hashed alongside the entropy, so seeds of different lengths
  cannot collide.

### Why 8 and not 6

Public keys are public and the derivation is public, so an attacker does not
attack one account — they grind candidate seeds and check each against **every
registered key at once**. The expected cost of breaking *someone* is `2^E / N`,
not `2^E`.

Normally a per-user salt defeats this, but a usernameless login has nothing to
salt with. The seed is the only input. That leaves entropy and KDF cost as the
only levers.

At 10M users, against an attacker sustaining 10⁷ Argon2id guesses/sec:

| words | entropy after checksum | time to break someone |
|---|---|---|
| 6 | 58 | ~1 hour |
| 7 | 69 | ~81 days |
| **8** | **80** | **~457 years** |
| 9 | 91 | ~900,000 years |

The cliff is steep because each word is 11 bits. Seven words was the original
target and is too thin — 81 days shrinks every year as hardware improves and the
user count grows.

**Argon2id is mandatory at every length.** Without a memory-hard KDF, even 8
words falls in days. Raising the work factor cannot substitute for entropy:
doubling it takes 7 words from 81 days to 162.

### Checksum

8 bits, so roughly 1 typo in 256 still validates. Because a valid-but-
unregistered seed leads to account creation, a mistyped login that happens to
pass the checksum would otherwise silently make a new empty account and leave
the user thinking they had lost everything. The UI therefore warns explicitly
before creating an account and makes it a second deliberate action.

### Recovery

There is none. Losing the seed loses the account and all of its reputation,
permanently. The UI says so at generation time.

## Keys

`Argon2id(seed) → 32 bytes → Ed25519 keypair`.

The private key is a **non-extractable WebCrypto key**. This is the reason for
using WebCrypto over a pure-JS Ed25519 library: a non-extractable key can sign
but its bytes cannot be read back out, by the page or by anything injected into
it.

Two layers keep it away from other sites:

- **Origin isolation** — no other site can reach this origin's IndexedDB.
- **A strict CSP** (`lib/reputable_chat/app.rb`) — keeps injected script inside
  this origin from using the key while a session is live.

It is stored in IndexedDB rather than held in memory only. Memory-only dies on
every page refresh, and a refresh is not a log off; IndexedDB survives refresh
and is cleared on explicit logout, which matches "stays until you log off" more
literally. The seed itself is never stored and never transmitted.

## The vault key

The private vault (settings, the voted list, and the friend and report lists
that used to be public) is meant to be opaque to the server, not merely signed.

It cannot be encrypted to the identity key. Ed25519 is a signature scheme with
no encryption operation, and the usual workaround — converting to X25519 and
doing ECDH — needs the private scalar, which for a non-extractable WebCrypto
key can never be read back. That is not a limitation to route around; it is the
property the whole key storage design is built on.

So the vault key comes from the seed independently: the same Argon2id under a
second domain, `seed.kdf.vault_domain`, giving a symmetric key the vault is
encrypted under. The ciphertext is then signed with the identity key, so the
server can neither read it nor alter it undetected.

Versioned for the same reason `seed.kdf.domain` is: changing it strands every
existing vault.

It is one Argon2id pass, not two. The vault key is taken off the same output
the identity key comes from, separated by domain through HKDF. A second
memory-hard pass would double the wait at every login and buy nothing a
domain-separated HKDF does not already give — and re-deriving the identity key
differently is off the table entirely, since that strands every account that
exists.

## What the server can still do with a vault it cannot read

Three things, and only three.

It can **verify the signature** over the ciphertext, which is what proves the
blob came back the way it went in. It can **reject a rollback**, because
`revision` sits outside the ciphertext — the one number it reads from a document
it can otherwise make nothing of, leaking roughly how many times you have saved
and nothing else. And it can **refuse an oversized blob**, which is the only
limit left once shape checking is impossible: it cannot count your friends, so
it counts your bytes.

What it gives up is real. The old private config let the server check that
`settings` was a bounded tree of scalars; an encrypted one cannot be checked at
all, so the client has to be as careful about what it decrypts as it would be
about anything else arriving over the wire.

The read route takes **no pubkey** — it uses the session's — so serving somebody
else's vault is not expressible through the API rather than being a check that
has to stay correct.

## Two devices editing one vault

A vault is a single encrypted blob with a monotonic revision, so two signed-in
devices both pushing will have one of them refused. The refusal is the useful
part: it means *merge*, never *retry*. A client that reacts to a rejection by
taking the server's copy silently drops everything it did since its last push;
one that reacts by bumping the revision and overwriting silently drops what the
other device did. Both are easy to write by accident, because a conflict looks
like something to retry.

The merge is per-list, and the two lists resolve in opposite directions:

- **First-seen entries: earliest wins.** The whole point of a sighting is when
  it happened, so the older record of having seen somebody is the true one.
  Union by public key, keep the earlier sighting.
- **Friends and blocks: latest wins.** Here the newest statement is the one the
  person meant. Union the entries, and where both devices touched the same
  person, take the later vault's version.

There are no per-entry timestamps, so "later" means the vault that was written
later, not the individual change. That is a deliberate limit rather than an
oversight: friending and blocking the same person from two devices inside one
sync window is not a thing people do by accident, and paying for it on every
entry of every vault forever is a worse trade than living with an odd result in
a case that barely happens.

## Login

Challenge–response:

1. Client asks for a nonce. The server issues a single-use, 5-minute one.
2. Client signs `{purpose, pubkey, nonce, origin, ts}`.
3. Server verifies the signature, the freshness of `ts`, and claims the nonce.

The nonce is claimed **after** signature verification, so a failed signature
does not burn the challenge.

`purpose` and `origin` are in the signed payload deliberately. Without them a
signature harvested by one server could be replayed against another to
authenticate as that user — which matters enormously once this federates, and
costs nothing to get right now.

## Usernames

Not unique, and deliberately so. Reputation attaches to the **key**, never the
name. That makes impersonation trivial unless the UI shows key-derived identity
everywhere, so a fingerprint is rendered next to every name from the first
screen onward.
