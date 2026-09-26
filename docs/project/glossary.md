# Glossary

One name per thing. **Retired terms** at the bottom is the single list of words that have been replaced — half the drift comes from sliding back into an older one.

## Defined in the rules

These are defined in [rules/v0.001.md](rules/v0.001.md), and only there, so that no second definition can drift from it:

record, payload, signature, record hash, text, decimal, record type (`type`), account ID (`id`), working key (`pubkey`), master public key (`mpubkey`), current keys, `ack`, `body`, record timestamp (`ts`), `target`, `note`, identity declaration, avatar, bio, handle, attestation, scores, derived, message, reaction, notice, key change, master key change, release, rules version, guideline.

## The chain

**Genesis** — the genesis account's first identity declaration, committed as a file because clients must agree on its hash before fetching anything. [chain.md](chain.md)

**Genesis account** — the developer's account, which signs the genesis. The same on every server, because there is one network and one chain. Every new account starts with it as a friend. By convention it signs what covers the whole network: releases and the rules. Tim by default, but the handle is only a handle. The development's seed is public on github, production's is not. 

**Host account** — a server's own account, optional. Its first identity declaration acknowledges the genesis, so it hangs off the one chain. Committed beside the genesis under `config/host/`. Where a server has one, a new account starts with it as a second friend. By convention it signs what concerns one server, such as an outage notice, as well as provides initial trust through a verification method for new users. Nothing enforces either convention. [chain.md](chain.md)

**Founding notice** — the first rules, `docs/project/rules/v0.001.md`, as the body of the genesis record. Not a record of its own. There is one per chain. [chain.md](chain.md)

**Rules** — the documents in `docs/project/rules/`, one file per version, never edited once published.

**Fingerprint** (of an account) — the short rendering of an account ID shown next to a handle.

**Suffix** — the four account-ID characters appended to a handle somebody else holds ahead of them. The same string as the fingerprint, shown only where a handle is contested. This may be extended up to eight digits when neccesary. [identity.md](identity.md)

## Off the chain

**Vault** — the owner's encrypted private document: settings, the voted list, the friend list, the seen list, and the private actions every published rating is computed from. Encrypted under a key derived from the seed under `seed.kdf.vault_domain`, then signed over the ciphertext. Not a record on the chain, and not governed by the rules. [identity.md](identity.md)

**Seen list** — the accounts you have seen a message from that are neither friends nor blocked, held in the vault. It records seniority, which is what decides whose handle shows bare and whose carries a suffix.

**Friend list** — the accounts added as friends. This is initially sorted by the order they were added but friends will be moved to the end of the list whenever they change their handle.

**Sealed** — the vault's ciphertext, as the server sees it. Named apart from "encrypted" because the server never handles a key, only a blob.

## Reputation

**Rating** — what one person gives another, in their own attestation (the field is named `reputation`), moved by friending, reacting and reporting, or set by hand. Yours is the only rating you control.

**Reputation** — what a viewer calculates for someone from their own rating of them and the ratings others have given them, weighted by the ladder. Subjective by construction: every viewer calculates their own, and there is no global one. The code calls it `effective`.

**Trust multiplier** — what someone's *recommendations* are worth, as distinct from what they are worth. Compounds along a path; a zero prunes the branch while leaving that person visible.

**Derived cache** — an attestation's `derived` field, for accounts a reader's walk did not reach. A reader reaching for it has run out of its own reach, and either takes the number or leaves it. [reputation.md](reputation.md)

**Hop** / **depth** — distance from the viewer. The walk goes out to `max_hops`, or until it has reached `max_accounts`.

**Ladder** — the per-hop weights, `(1 - k) * k^d`: 0.9, 0.09, 0.009, 0.0009.

**Curve** — the vote curve turning a net count of positive and negative reactions into a value. An *authoring* parameter now that attestations carry ratings.

**Gate** — `gate.min_rating`, the rating a link must exceed for the walk to continue through it.

**Buckets** — **Trusted** (≥ `trusted_at`), **Tolerated** (> 0), **Blocked** (≤ 0). Computed at login; the reputations are then discarded.

## Identity

**Seed phrase** — 8+ BIP39 words. It derives the account's keys; there is no recovery without it, unless a master key was kept. [identity.md](identity.md)

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
| transaction timestamp, message timestamp | record timestamp (`ts`) |
| comment, post (as a noun) | message |
| emote (as a record), `emote:v1` | reaction |
| announcement | message or notice |
| adjustment (`adjustment:v1`) | nothing on the chain; a change waits in the vault for the next attestation |
| `author`, `publisher` (as a field name) | `pubkey` |
| public key (as the account's identity) | account ID |
| public key (as the key that is not the master key) | working key |
| `reply_to`, an emote's `message` | `target` |
| `icon`, `avatar` (as a field) | `file`, which on an identity declaration is the avatar |
| `bio` (as a field) | `note` |
| `master_pubkey` | `mpubkey` |
| `note` (as free text up to 16,000 bytes) | `body` |
| `supersedes`, `seq`, `prev`, `room`, `previous_pubkey`, `derived.hops`, `derived.params` | (removed; no replacement) |
| parameter fingerprint | (removed; nothing published says what parameters it was computed under) |
| Tim (as the general term) | genesis account |
| server's Tim, server account | host account |
| score | rating (given) or reputation (calculated) |

And one word to avoid rather than replace: **troll** is not a category this system has an opinion about. Someone unbearable to one reader is worth reading to another, and the design holds that disagreement open rather than resolving it. Where the docs need to name what is actually excluded, the term is **unvouched-for**.
