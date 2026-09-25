# Glossary

One name per thing. Each entry says which file defines the term. **Retired terms** at the bottom is the single list of words that have been replaced — half the drift comes from sliding back into an older one. Field definitions live in [rules/v0.001.md](rules/v0.001.md); this page names things and says where to look.

## Records

**Record** — a payload and a signature over it. Records are generated from database rows rather than stored as files, which is only safe because canonical serialization is deterministic. [chain.md](chain.md)

**Payload** — a record's contents, as canonical JSON. The signature covers all of it.

**Record hash** — a record's identity: `SHA256(canonical payload + "\n" + signature)`, hex. What `ack`, `target` and `id` all name. Not the same as a signature, which identifies only the payload. [chain.md](chain.md)

**Identity declaration** (`reputablechat:identity:v0.001`) — a signed statement about yourself: handle, avatar and bio.

**Attestation** (`reputablechat:attestation:v0.001`) — a signed statement about everyone else: a rating and a trust multiplier per account, plus the derived cache. The counterpart to an identity declaration.

**Message** (`reputablechat:message:v0.001`) — text one account sends. The only word for it: not a comment, a post or a transaction.

**Reaction** (`reputablechat:reaction:v0.001`) — a response to one or more records, such as an emoji or "like", carried in its body. Any number per account per record.

**Notice** (`reputablechat:notice:v0.001`) — a statement to the network, of a given `kind`. The rules define `key-change` and `master-key-change`; any other kind is accepted and ignored by the network itself, and servers may use their own, such as an outage.

**Release** (`reputablechat:release:v0.002` and so on) — a published version of the client, and of the rules. Its type carries the new rules version and its body the new rules. Anyone may publish one. [chain.md](chain.md)

**Genesis** — the genesis account's first identity declaration: the only record whose `ack` is empty, and the thing every record that has seen nothing else acknowledges. Its body is the founding notice. Committed as a file because clients must agree on its hash before fetching anything. There are two: development's seed is public, production's is not.

**Genesis account** — the developer's account, which signs the genesis. The same on every server, because there is one network and one chain. Every new account starts with it as a friend, and what it publishes in its attestation is the only way it reaches anyone. By convention it signs what covers the whole network: releases and the rules. Tim by default, but the handle is only a handle.

**Host account** — a server's own account, optional. Its first identity declaration acknowledges the genesis, so it hangs off the one chain. Committed beside the genesis under `config/host/`. Where a server has one, a new account starts with it as a second friend. By convention it signs what concerns one server, such as an outage notice. Nothing enforces either convention. [chain.md](chain.md)

**Founding notice** — the first rules, `docs/project/rules/v0.001.md`, placed in the genesis record as its body. Not a record of its own: it is inside the genesis, so it sits at the bottom of the chain with it. The generator reads it straight from the file. Later rules versions are releases, not founding notices; there is one per chain. [chain.md](chain.md)

**Rules** — what every field of every record means and what makes a record valid. The first version is the genesis record's body; later versions are releases. A record follows the newest version it acknowledges. [rules/v0.001.md](rules/v0.001.md)

**Rules version** — the rules' own number, ordered as a decimal, and the third part of every record's `type`. Each version's text lives in the repository as `docs/project/rules/v<version>.md`. Versions below 1 are pre-launch; 1 is reserved for the first set that goes live.

**Guideline** — a rule that is not enforced. A record that ignores one is accepted, and clients will likely ignore the values that do not conform. [rules/v0.001.md](rules/v0.001.md)

## Accounts and keys

**Account ID** (`id`) — the record hash of an account's first identity declaration. It identifies the account for good, whatever key it signs with. Every record but that first declaration carries it. Attestations are keyed by it, and the characters shown beside a handle come from it.

**Working key** (`pubkey`) — the key an account uses day to day, as opposed to its master key. It signs the account's records unless the master key does, and the account's first identity declaration declares it.

**Master public key** (`mpubkey`) — optional; a key kept offline for changing keys and recovering from a compromised one. A record signed with the master key carries it.

**Current keys** — the working key and master public key set by an account's first identity declaration, as replaced by the latest key-change and master-key-change notices a given record acknowledges. A record is checked against the account's current keys as seen by that record, so a record signed before a key change stays valid after it.

**Fingerprint** (of an account) — the short rendering of an account ID shown next to a handle.

**Suffix** — the eight account-ID characters appended to a handle somebody else holds ahead of them. The same string as the fingerprint, shown only where a handle is contested.

## Fields every record carries

**`type`** — `reputablechat:<kind>:<rules version>`, such as `reputablechat:message:v0.001`.

**`ack`** — the record hashes of the most recent records this record's author had seen: sorted, no duplicates, at most 16, empty only on the genesis. What makes a set of signatures a chain. Chosen subjectively, and unenforceable by the server.

**`body`** — text, up to 16,000 bytes: a message's text, a reaction, a new key in a key notice, or a rules document.

**`ts`** — the message timestamp: when the author says they signed, in whole Unix seconds. The author's own clock, so it is a claim and nothing more: it orders nothing, and the server records its own receipt time separately and unsigned.

**`target`** — optional; the records this one replies to, comments on or reacts to, as a list of record hashes.

**`note`** — optional; a short message, up to 280 bytes. The bio on an identity declaration, and "compromised" on a key change.

## Off the chain

**Vault** — the owner's encrypted private document: settings, the voted list, the friend order, the seen set, and the private actions every published rating is computed from. Encrypted under a key derived from the seed under `seed.kdf.vault_domain`, then signed over the ciphertext. Not a record on the chain, and not governed by the rules. [identity.md](identity.md)

**`revision`** — the vault's save counter, which lets the server refuse a rollback. No record on the chain has one.

**Seen set** — the accounts you have seen a message from that are neither friends nor blocked, held in the vault. It records seniority, which is what decides whose handle shows bare and whose carries a suffix.

**Friend order** — the order friends were added, kept in the vault because a ratings map comes back sorted by key and cannot carry it. Distinct from a **name claim**, which is dated from when that account took the handle it is using now and resets when they change it.

**Sealed** — the vault's ciphertext, as the server sees it. Named apart from "encrypted" because the server never handles a key, only a blob.

## Reputation

**Rating** — what one person gives another: a decimal from −1 to 1 in their own attestation (the field is named `reputation`), moved by friending, reacting and reporting, or set by hand. Yours is the only rating you control.

**Reputation** — what a viewer calculates for someone from their own rating of them and the ratings others have given them, weighted by the ladder. Subjective by construction: every viewer calculates their own, and there is no global one. The code calls it `effective`.

**Trust multiplier** — what someone's *recommendations* are worth, as distinct from what they are worth. Compounds along a path; a zero prunes the branch while leaving that person visible. From −1 to 1.

**Derived cache** — an attestation author's own calculated reputations and trust for accounts further out, published so they can serve as the fourth term of everybody else's. A reader reaching for it has run out of its own reach, and either takes the number or leaves it. [reputation.md](reputation.md)

**Hop** / **depth** — distance from the viewer. The walk stops at hop 2 and fills depth 3 from derived caches.

**Ladder** — the per-hop weights, `(1 - k) * k^d`: 0.9, 0.09, 0.009, 0.0009.

**Curve** — the vote curve turning a net count of positive and negative reactions into a value. An *authoring* parameter now that attestations carry ratings.

**Gate** — `gate.min_rating`, the rating a link must exceed for the walk to continue through it.

**Buckets** — **Trusted** (≥ `trusted_at`), **Tolerated** (> 0), **Blocked** (≤ 0). Computed at login; the reputations are then discarded.

## Identity

**Seed phrase** — 8+ BIP39 words. It derives the account's keys; there is no recovery without it, unless a master key was kept. [identity.md](identity.md)

**Canonical serialization** — sorted keys, no whitespace, UTF-8, non-whole numbers as decimal strings. Ruby and JavaScript must produce identical bytes.

## Retired terms

Do not reintroduce these; they each have a current name above.

| was | is |
|---|---|
| user record | identity declaration |
| vouch list | attestation |
| config / public config (`config:v1`) | identity declaration + attestation |
| private config (`private-config:v1`) | vault |
| `ladder.max_configs` | `ladder.max_accounts` |
| `purpose` | `type` |
| shape, the `:v1` in a purpose string | rules version, the last part of `type` |
| version (as a per-record counter), `revision` on a chain record | (removed; order is acknowledgement) |
| `tim.json` | `<environment>.json` |
| transaction | record |
| transaction timestamp | message timestamp (`ts`) |
| comment, post (as a noun) | message |
| emote (as a record), `emote:v1` | reaction |
| announcement | message or notice |
| adjustment (`adjustment:v1`) | nothing on the chain; a change waits in the vault for the next attestation |
| `author`, `publisher` (as a field name) | `pubkey` |
| public key (as the account's identity) | account ID |
| public key (as the key that is not the master key) | working key |
| `reply_to`, an emote's `message` | `target` |
| `icon` | `avatar` |
| `bio` (as a field) | `note` |
| `master_pubkey` | `mpubkey` |
| `note` (as free text up to 16,000 bytes) | `body` |
| `supersedes`, `seq`, `prev`, `room`, `previous_pubkey`, `derived.hops`, `derived.params` | (removed; no replacement) |
| parameter fingerprint | (removed; nothing published says what parameters it was computed under) |
| Tim (as the general term) | genesis account |
| server's Tim, server account | host account |
| score | rating (given) or reputation (calculated) |

And one word to avoid rather than replace: **troll** is not a category this system has an opinion about. Someone unbearable to one reader is worth reading to another, and the design holds that disagreement open rather than resolving it. Where the docs need to name what is actually excluded, the term is **unvouched-for**.
