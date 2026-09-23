# Glossary

One name per thing. Where a term has a home, this says which file defines it;
where it has a history, this says what it used to be called, because half the
drift comes from sliding back into an older word.

## Records

**Record** — a signed payload. Records are generated from database rows rather
than stored as files, which is only safe because canonical serialization is
deterministic. [chain.md](chain.md)

**Record hash** — a record's identity: `SHA256("reputablechat:record:v1\n" +
canonical payload + "\n" + signature)`, hex. What `ack`, `prev`, `reply_to`,
`supersedes` and an emote's target all name. Not the same as a signature, which
identifies only the payload. [chain.md](chain.md)

**Identity declaration** (`reputablechat:identity:v1`) — a signed statement
about yourself: handle, bio, icon, and the key-rotation placeholders. Was
called a *user record*.

**Attestation** (`reputablechat:attestation:v1`) — a signed statement about
everyone else: a reputation and a trust multiplier per person, plus the derived
cache. The counterpart to an identity declaration. Was called a *vouch list*.

**Adjustment** (`reputablechat:adjustment:v1`) — one change to an attestation
between republishes, naming the `base_revision` it amends and its `seq` in that
run. An emote record is already its own adjustment; these exist for the changes
with no other public record.

**Message** (`reputablechat:message:v1`) — a comment in a room.

**Emote** (`reputablechat:emote:v1`) — one person's reaction to one message.

**Notice** (`reputablechat:notice:v1`) — an official statement from a
publisher: an outage, a policy, a release, the founding statement. `kind` comes
from `config/notices.yml`.

**Release** (`reputablechat:release:v1`) — a manifest of `path → sha256`
pinning a version of the client. A manifest, never an archive.

**Genesis** — the first identity declaration, the only record whose `ack` is
null, and the thing every record that has seen nothing else acknowledges.
Committed as a file because clients must agree on its hash before fetching
anything. There are two: development's seed is public, production's is not.

**Founding notice** — the notice that supersedes nothing. One per chain.

## Fields that travel on many records

**`ack`** — the record hash of the last record this record's author had seen.
What makes a set of signatures a chain. Chosen subjectively, and unenforceable
by the server.

**`note`** — free text the software never reads, for a person browsing the raw
chain. Signed, inert, bounded, null unless set.

**`revision`** — a monotonic counter for one record, climbing each time its
owner republishes. Every record has its own. Not the shape.

**Shape**, written `:v1` — which fields a payload has. Moves only when the
field list changes, which invalidates every signature made under the old one.

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
and the friend and report lists. Encrypted under a key derived from the seed
under `seed.kdf.vault_domain`, then signed. No `ack`, because nobody else ever
sees it. [identity.md](identity.md)

**Private config** (`reputablechat:private-config:v1`) — the vault's
predecessor, signed but not encrypted. Being replaced.

**Sealed** — the vault's ciphertext, as the server sees it. Named apart from
"encrypted" because the server never handles a key, only a blob.

**Config** (`reputablechat:config:v1`) — retired. Split into an identity
declaration and an attestation.

## Reputation

**Reputation** — what one person thinks another is worth, as a decimal string
in their attestation. Subjective by construction; there is no global score.

**Trust multiplier** — what someone's *recommendations* are worth, as distinct
from what they are worth. Compounds along a path; a zero prunes the branch
while leaving that person visible. Clamped to −1..1.

**Derived cache** — an attestation author's own calculated scores, published so
they can serve as the fourth term of everybody else's. Carries a parameter
fingerprint. [reputation.md](reputation.md)

**Parameter fingerprint** — a hash of the parameters a score was computed
under. Advisory and incomplete: a multi-hop estimate averages scores that each
came from a different author's curve.

**Hop** / **depth** — distance from the viewer. The walk stops at hop 2 and
fills depth 3 from derived caches.

**Ladder** — the per-hop weights, `(1 - k) * k^d`: 0.9, 0.09, 0.009, 0.0009.

**Curve** — the vote curve turning a net emote count into a value. An
*authoring* parameter now that attestations carry scores.

**Gate** — `gate.min_rating`, the rating a link must exceed for the walk to
continue through it.

**Buckets** — **Trusted** (≥ `trusted_at`), **Tolerated** (> 0), **Blocked**
(≤ 0). Computed at login; the scores are then discarded.

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
| config / public config | identity declaration + attestation |
| version (as a per-record counter) | revision |
| `tim.json` | `<environment>.json` |

And one word to avoid rather than replace: **troll** is not a category this
system has an opinion about. Someone unbearable to one reader is worth reading
to another, and the design holds that disagreement open rather than resolving
it. Where the docs need to name what is actually excluded, the term is
**unvouched-for**.
