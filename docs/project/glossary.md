# Glossary

One name per thing. Each entry says which file defines the term. **Retired
terms** at the bottom is the single list of words that have been replaced —
half the drift comes from sliding back into an older one.

## Records

**Record** — a signed payload. Records are generated from database rows rather
than stored as files, which is only safe because canonical serialization is
deterministic. [chain.md](chain.md)

**Record hash** — a record's identity: `SHA256("reputablechat:record:v1\n" +
canonical payload + "\n" + signature)`, hex. What `ack`, `prev`, `reply_to`,
`supersedes` and an emote's target all name. Not the same as a signature, which
identifies only the payload. [chain.md](chain.md)

**Identity declaration** (`reputablechat:identity:v1`) — a signed statement
about yourself: handle, bio, icon, and the key-rotation placeholders.

**Attestation** (`reputablechat:attestation:v1`) — a signed statement about
everyone else: a reputation and a trust multiplier per person, plus the derived
cache. The counterpart to an identity declaration.

**Adjustment** (`reputablechat:adjustment:v1`) — one change to an attestation
between republishes, naming the `base_revision` it amends and its `seq` in that
run. An emote record is already its own adjustment; these exist for the changes
with no other public record.

**Message** (`reputablechat:message:v1`) — text one person sends to a room.
The only word for it: not a comment, a post or a transaction.

**Emote** (`reputablechat:emote:v1`) — one person's response to one message.

**Notice** (`reputablechat:notice:v1`) — an official statement from a
publisher: an outage, a policy, a release, the founding statement. `kind` comes
from `config/notices.yml`.

**Release** (`reputablechat:release:v1`) — a manifest of `path → sha256`
pinning a version of the client. A manifest, never an archive.

**Genesis** — the genesis account's first identity declaration: the only
record whose `ack` is empty, and the thing every record that has seen nothing
else acknowledges. Its `note` carries version 0.001 of the rules.
Committed as a file because clients must agree on its hash before fetching
anything. There are two: development's seed is public, production's is not.

**Genesis account** — the developer's account, which signs the genesis. The
same on every server, because there is one network and one chain. Every new
account starts with it as a friend, and what it publishes in its attestation is
the only way it reaches anyone. By convention it signs what covers the whole
network: releases and the rules. Tim by default, but the handle is only a
handle.

**Host account** — a server's own account, optional. Its first identity
declaration acknowledges the genesis, so it hangs off the one chain. Committed
beside the genesis under `config/host/`. Where a server has one, a new account
starts with it as a second friend. By convention it signs what concerns one
server, such as an outage notice. Nothing enforces either convention.
[chain.md](chain.md)

**Rules** — what every field of every record means and what makes a record
valid. Carried in the `note` of the genesis account's identity declaration, one
revision per version, never edited. A record follows the newest version it
acknowledges. [chain.md](chain.md)

**Founding notice** — version 0.001 of the rules, kept as
`docs/project/rules/v0.001.md`, from which the genesis record's note is
generated. Versions below 1 are pre-launch; 1 is reserved for the first set
that goes live.
As a notice record it is the one kind that supersedes nothing. One per chain.

## Fields that travel on many records

**`ack`** — the record hashes of the most recent records this record's author
had seen: sorted, no duplicates, at most 16, empty only on the genesis. What
makes a set of signatures a chain. Chosen subjectively, and unenforceable
by the server.

**`note`** — free text the software never reads, for a person browsing the raw
chain. Signed, inert, bounded, null unless set.

**`revision`** — a monotonic counter for one record, climbing each time its
owner republishes. Every record has its own. Not the shape.

**Shape**, written `:v1` — which fields a payload has. Moves only when the
field list changes. Records signed under the old shape stay valid and stay on
the chain; a signature made for one shape can never be presented as another,
and the old shape has to stay understood so its records can still be checked.

**`ts`** — when the author says they signed, in whole Unix seconds. The
author's own clock, so it is a claim and nothing more: it orders nothing, and
the server records its own receipt time separately and unsigned.

**`purpose`** — the domain-separated string naming the shape, signed alongside
everything else so a signature for one kind of record cannot be presented as
another.

**`supersedes`** — the record a correction replaces. Corrections are new
records; nothing is ever edited, because a mutated record no longer matches its
signature.

**`publisher`** — who signed a notice or a release. Carried so a per-user
trusted-developer setting can arrive without re-signing anything.

## Off the chain

**Vault** — the owner's encrypted private document: settings, the voted list,
the friend order, the seen set, and the private actions every published
rating is computed from. Encrypted under a key derived from the seed under
`seed.kdf.vault_domain`, then signed over the ciphertext. No `ack`, because
nobody else ever sees it. [identity.md](identity.md)

**Seen set** — the accounts you have seen a message from that are neither
friends nor blocked, held in the vault. It records seniority, which is what
decides whose handle shows bare and whose carries a suffix.

**Suffix** — the eight key characters appended to a handle somebody else holds
ahead of them. The same string as a key fingerprint, shown only where a handle
is contested.

**Friend order** — the order friends were added, kept in the vault because a
ratings map comes back sorted by public key and cannot carry it. Distinct from
a **name claim**, which is dated from when that account took the handle it is
using now and resets when they change it.

**Sealed** — the vault's ciphertext, as the server sees it. Named apart from
"encrypted" because the server never handles a key, only a blob.


## Reputation

**Rating** — what one person gives another: a decimal from −1 to 1 in their
own attestation, moved by friending, emoting and reporting, or set by hand.
Yours is the only rating you control.

**Reputation** — what a viewer calculates for someone from their own rating of
them and the ratings others have given them, weighted by the ladder.
Subjective by construction: every viewer calculates their own, and there is no
global one. The code calls it `effective`.

**Trust multiplier** — what someone's *recommendations* are worth, as distinct
from what they are worth. Compounds along a path; a zero prunes the branch
while leaving that person visible. Clamped to −1..1.

**Derived cache** — an attestation author's own calculated reputations,
published so they can serve as the fourth term of everybody else's. Carries a parameter
fingerprint. [reputation.md](reputation.md)

**Parameter fingerprint** — a hash of the parameters a reputation was
calculated under. Advisory and incomplete: a derived reputation averages
ratings that each came from a different author's curve.

**Hop** / **depth** — distance from the viewer. The walk stops at hop 2 and
fills depth 3 from derived caches.

**Ladder** — the per-hop weights, `(1 - k) * k^d`: 0.9, 0.09, 0.009, 0.0009.

**Curve** — the vote curve turning a net emote count into a value. An
*authoring* parameter now that attestations carry ratings.

**Gate** — `gate.min_rating`, the rating a link must exceed for the walk to
continue through it.

**Buckets** — **Trusted** (≥ `trusted_at`), **Tolerated** (> 0), **Blocked**
(≤ 0). Computed at login; the reputations are then discarded.

## Identity

**Seed phrase** — 8+ BIP39 words. The account *is* the phrase; there is no
recovery. [identity.md](identity.md)

**Public key** — the identity itself. Handles are not unique and the UI shows a
key fingerprint beside every name.

**Fingerprint** (of a key) — the short rendering of a public key shown next to
a handle. Unrelated to a parameter fingerprint, which is the one collision this
vocabulary has not resolved.

**Canonical serialization** — sorted keys, no whitespace, UTF-8, floats
refused. Ruby and JavaScript must produce identical bytes.

## Retired terms

Do not reintroduce these; they each have a current name above.

| was | is |
|---|---|
| user record | identity declaration |
| vouch list | attestation |
| config / public config (`config:v1`) | identity declaration + attestation |
| private config (`private-config:v1`) | vault |
| `ladder.max_configs` | `ladder.max_accounts` |
| version (as a per-record counter) | revision |
| `tim.json` | `<environment>.json` |
| transaction | record |
| comment, post (as a noun) | message |
| reaction | emote |
| announcement | notice |
| Tim (as the general term) | genesis account |
| server's Tim, server account | host account |
| score | rating (given) or reputation (calculated) |

And one word to avoid rather than replace: **troll** is not a category this
system has an opinion about. Someone unbearable to one reader is worth reading
to another, and the design holds that disagreement open rather than resolving
it. Where the docs need to name what is actually excluded, the term is
**unvouched-for**.
