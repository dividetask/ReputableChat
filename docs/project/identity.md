# Identity

There is no username at login and no password in the usual sense. A seed phrase derives the account's working keypair: the private half signs the account's records, and the public half, the working key, is what others check the signatures against. The account itself is identified by its account ID, which outlives any one key.

## Seed phrases

- **BIP39 English wordlist**, 2048 words, 11 bits each. Chosen because it is well tested, has vetted translations, and guarantees the first four letters identify a word — which makes type-ahead reliable and removes spelling as a failure mode.
- **Minimum 8 words.** 88 bits total: 80 entropy plus an 8-bit checksum.
- Longer seeds are accepted; each extra word adds 11 bits.
- The word count is hashed alongside the entropy, so seeds of different lengths cannot collide.

### Why 8 and not 6

Public keys are public and the derivation is public, so an attacker does not attack one account — they grind candidate seeds and check each against **every registered key at once**. The expected cost of breaking *someone* is `2^E / N`, not `2^E`.

Normally a per-user salt defeats this, but a usernameless login has nothing to salt with. The seed is the only input. That leaves entropy and KDF cost as the only levers.

At 10M users, against an attacker sustaining 10⁷ Argon2id guesses/sec:

| words | entropy after checksum | time to break someone |
|---|---|---|
| 6 | 58 | ~1 hour |
| 7 | 69 | ~81 days |
| **8** | **80** | **~457 years** |
| 9 | 91 | ~900,000 years |

The cliff is steep because each word is 11 bits. Seven words was the original target and is too thin — 81 days shrinks every year as hardware improves and the user count grows.

**Argon2id is mandatory at every length.** Without a memory-hard KDF, even 8 words falls in days. Raising the work factor cannot substitute for entropy: doubling it takes 7 words from 81 days to 162.

### Recovery

Losing the seed loses the account and all of its reputation, unless the account declared a master key and its holder still has it: see the rules on key changes. Without one there is no recovery.

## Keys

`Argon2id(seed) → 32 bytes → Ed25519 keypair`.

The private key is a **non-extractable WebCrypto key**. This is the reason for using WebCrypto over a pure-JS Ed25519 library: a non-extractable key can sign but its bytes cannot be read back out, by the page or by anything injected into it.

Two layers keep it away from other sites:

- **Origin isolation** — no other site can reach this origin's IndexedDB.
- **A strict CSP** (`lib/reputable_chat/app.rb`) — keeps injected script inside this origin from using the key while a session is live.

It is stored in IndexedDB rather than held in memory only. Memory-only dies on every page refresh, and a refresh is not a log off; IndexedDB survives refresh and is cleared on explicit logout, which matches "stays until you log off" more literally. The seed itself is never stored and never transmitted.

## The vault key

The private vault (settings, the voted list, and the friend and report lists) is meant to be opaque to the server, not merely signed.

It cannot be encrypted to the identity key. Ed25519 is a signature scheme with no encryption operation, and the usual workaround — converting to X25519 and doing ECDH — needs the private scalar, which for a non-extractable WebCrypto key can never be read back. That is not a limitation to route around; it is the property the whole key storage design is built on.

So the vault key comes from the seed independently: the same Argon2id under a second domain, `seed.kdf.vault_domain`, giving a symmetric key the vault is encrypted under. The ciphertext is then signed with the identity key, so the server can neither read it nor alter it undetected.

Versioned for the same reason `seed.kdf.domain` is: changing it strands every existing vault.

It is one Argon2id pass, not two. The vault key is taken off the same output the identity key comes from, separated by domain through HKDF. A second memory-hard pass would double the wait at every login and buy nothing a domain-separated HKDF does not already give — and re-deriving the identity key differently is off the table entirely, since that strands every account that exists.

## What the server can still do with a vault it cannot read

Two things, and only two.

It can **verify the signature** over the ciphertext, which is what proves the blob came back the way it went in. And it can **refuse an oversized blob**, which is the only limit left once shape checking is impossible: it cannot count your friends, so it counts your bytes.

What it gives up is real. The signed-but-readable record this replaced let the server check that `settings` was a bounded tree of scalars; an encrypted one cannot be checked at all, so the client has to be as careful about what it decrypts as it would be about anything else arriving over the wire.

The read route takes **no pubkey** — it uses the session's — so serving somebody else's vault is not expressible through the API rather than being a check that has to stay correct.

## Who is called what

Handles are not unique and never will be, so something has to decide which Joe is "Joe" and which is "Joe a4f2c1de". The rule is seniority, in this order:

1. **friends**, in the order of the friend list
2. **accounts you have seen**, in the order of the seen list
3. **everybody else**: accounts whose name is on screen before any of their messages has been, such as a name in a reaction. They join the seen list as soon as one of their messages is shown.

Whoever comes first holds the handle bare; everyone else carries a suffix: the first four characters of their account ID, extended up to eight where four do not tell them apart. A handle nobody is competing for is always shown bare, because there is nobody to tell apart.

The ordering is what makes this worth anything. An impersonator arrives *after* the person they are copying, so they are always the one wearing the suffix, and the person being copied never has to do anything to keep their name.

**A rename forfeits seniority, for friends as much as for sightings.** Whenever an account is first seen it is placed on the end of the **seen list** and whenever an account is added as a friend they are put at the bottom of the friend list. Whenever any account, friend or otherwise, changes their name they are moved to the bottom of their respective list. Any account whose reputation dips below 0 is automatically removed from the **seen list**. Both lists are stored in the vault and are not public.

A [suffix](#handles) appears only where a handle is contested, never beside every name. So a suffix means something when you see one, and the cost is that a stranger with an unfamiliar handle is shown bare — which is exactly when a reader knows least about them.

### The seen list

The accounts a message has been seen from that are neither friends nor blocked, held in the vault. It is initially ordered by seniority.

Friends and blocked accounts leave it: one ranks above it, the other is never shown, so a record of either is one nothing reads.

It is bounded by `seen_entries`, and over budget the last entries are dropped.

## Two devices editing one vault

A vault is a single encrypted blob, and the server keeps only the latest copy. Before pushing, the client asks the server for a fingerprint of the stored copy. If it does not match the copy this device last pushed, another device has saved since, and the client merges before pushing.

The merge is per-list, and the two lists resolve in opposite directions:

- **First-seen entries: earliest wins.** The whole point of a sighting is when it happened, so the older record of having seen somebody is the true one. Union by account ID, keep the earlier sighting.
- **Friends and blocks: latest wins.** Here the newest statement is the one the person meant. Union the entries, and where both devices touched the same person, take the later vault's version.

There are no per-entry timestamps, so "later" means the vault that was written later, not the individual change. That is a deliberate limit rather than an oversight: friending and blocking the same person from two devices inside one sync window is not a thing people do by accident, and paying for it on every entry of every vault forever is a worse trade than living with an odd result in a case that barely happens.

## Login

Challenge–response:

1. Client asks for a nonce. The server issues a single-use, 5-minute one.
2. Client signs `{purpose, pubkey, nonce, origin, ts}`.
3. Server verifies the signature, the freshness of `ts`, and claims the nonce.

The nonce is claimed **after** signature verification, so a failed signature does not burn the challenge.

Logging in is not a record and never reaches the chain, so the rules do not govern it.

## Handles

Not unique, and deliberately so. Reputation attaches to the **account ID**, never the name. That makes impersonation trivial unless the UI shows the account's identity everywhere, so a fingerprint is rendered next to every name from the first screen onward.
