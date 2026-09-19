# The chain

Every signed record in ReputableChat names the last record its author had seen
when they signed it. That one field turns a pile of independent signatures into
a single tangled history: if you can see a record, you can walk back from it
through everything its author had already seen, and everything *those* authors
had seen, until you reach the genesis.

There is no proof of work and no mining. The chain is not there to order
transactions or to stop double spends — it is there so that a record cannot be
quietly removed, back-dated, or shown to one person and not another. A server
that drops a message has to drop everything that acknowledged it, and everything
that acknowledged *those*, which is not something it can do selectively without
the gap being visible.

## Records

A record is a signed payload. Five kinds so far:

| purpose | what it is |
|---|---|
| `reputablechat:user:v1` | who someone is: keys, handle, bio, icon |
| `reputablechat:attestation:v1` | what someone thinks of everyone else |
| `reputablechat:adjustment:v1` | one change to an attestation, between republishes |
| `reputablechat:message:v1` | a comment in a room |
| `reputablechat:emote:v1` | a reaction to a comment |
| `reputablechat:release:v1` | a published version of the client |

Every one of them carries `ack`. The private vault does not, because nobody
else ever sees it — see [identity.md](identity.md).

Records are **generated, not stored as files.** The server keeps database rows
and builds the record when someone asks for it. That is only safe because the
canonical form is deterministic: the same row produces the same bytes and
therefore the same hash and the same signature, every time, on any machine. The
moment that stops being true the whole structure stops verifying, which is why
`spec/canonical_parity_spec.rb` exists and why floats are refused outright.

## Record hashes

`ack` points at a hash, and `reply_to` and an emote's `message` field now do
too, replacing the signatures they used to name. A signature identifies a
payload; a hash identifies the *record*, signature included, which is what you
want when the thing you are linking to needs to be tamper-evident as a whole.

```
record_hash = SHA256("reputablechat:record:v1\n" + canonical_payload + "\n" + signature)
```

Hex, 64 characters, the same shape as a content-addressed image name.

The two newlines are unambiguous separators rather than a convention, because
canonical JSON can never contain a raw `0x0A` — JSON escapes a newline inside a
string to the two characters `\n`, and there is no whitespace between tokens.
Base64url contains no newline either. So there is exactly one pair of strings
that produces any given hash input.

Hashing the stored `payload` **string** rather than a re-serialized object is
deliberate. The server holds the canonical bytes exactly as they arrived and
never parses them back into an object; re-serializing server-side is the one
thing guaranteed to break a signature eventually.

The domain prefix keeps this hash from colliding with the other SHA-256 in the
system, which addresses image and asset bytes directly.

## Genesis

Tim's user record is the bottom of the chain. It is the only record whose `ack`
is null; every record that has seen nothing else acknowledges Tim.

It is generated once by `script/generate_genesis.mjs` and committed to
`config/genesis/tim.json`. That file is the only record stored as a file, and it
is stored as one because every client needs to agree on the hash before it has
fetched anything — a genesis you have to download from the server is not a
genesis.

The script runs the **real** client derivation path under Node: the vendored
Argon2id build, the same Argon2id parameters out of `config/reputation.yml`,
and WebCrypto Ed25519. It is not a second implementation that could drift from
the browser's and strand the account it creates.

It writes the seed to `config/genesis/seed`, gitignored and 0600, and prints
nothing secret -- a terminal scrollback, a CI log and a screen share are all
places a seed should not turn up. The file holds the phrase rather than the
derived key, so it is the same secret a person would type into the UI.

`script/tim.rb` signs with it, which is how the genesis account posts
announcements and vouches for new arrivals without somebody sitting at a
browser. That file is the one place in this project a private key lives outside
a browser, and it is the weakest point in the system: whoever holds it is the
genesis account, and can publish a release every client would run.

The command that matters on a new network is `visible`. An unrated account sits
at exactly zero and is invisible to everyone, which is the sybil defense and
also the reason nobody can get started. One positive rating from the genesis
account lifts somebody over the line for anyone who rates the genesis account.

## What gets acknowledged

You acknowledge the most recent record you have seen **whose author you rate
above `chain.min_reputation_to_acknowledge`**. Not the most recent record, full
stop.

That threshold is your own, it uses your own attestation and your own config,
and so the rule is subjective in exactly the way everything else here is. Two
people looking at the same room will disagree about which references were
legitimate, and there is no view from nowhere that settles it.

This has a consequence worth stating plainly rather than discovering later:
**records from new and low-reputation accounts are never acknowledged by
anyone, so they never get anchored.** A troll's messages sit off to the side of
the history, referenced by nothing, and disappear the moment the server stops
serving them. That is not a gap in the design, it is the point of it — the
chain is a structure the reputable part of the network builds for itself, and
exclusion from it is the cost of being unvouched for.

The server does not check any of this. It cannot: it never computes a
reputation, so it has no opinion about whether an `ack` was well chosen. It
stores what it is given and serves it back. Verification is the reader's, and
only a reader running the author's own parameters can even attempt it.

## Attestations

The old public config carried `{friend, reported, net_votes}` per person and
let every reader run the curve themselves. An attestation carries **scores**:

```json
{ "purpose": "reputablechat:attestation:v1",
  "pubkey":  "...",
  "revision": 4,
  "ack":     "<64 hex>",
  "ts":      1710000000,
  "scores":  { "<pubkey>": { "reputation": "0.5", "trust": "1" } },
  "derived": { "hops": 3, "params": "<64 hex>",
               "scores": { "<pubkey>": "0.0123" } } }
```

`reputation` is what the author thinks of that person. Most people never set it
by hand — friending and emoting move it, and the curve that used to run in
every reader now runs once in the author. Advanced users can set it directly.

`trust` is the multiplier on everything that person recommends. It defaults to
1 for anyone positive and 0 for anyone blocked, so it only needs storing when
somebody has overridden it. It exists for the case where a friend is worth
reading but has terrible taste in who *else* to vouch for: set them to 0 and
their posts stay visible while their recommendations stop carrying spam in.

**Multipliers compound along the path.** A 0.5 at hop one and a 0.5 at hop two
means everything past the second is worth a quarter. A 0 prunes the branch
there — the traversal stops rather than carrying a zero through the remaining
hops, which is both correct and cheaper. A negative inverts, which is what
"I trust this person to be reliably wrong" means, and it compounds like any
other factor, so two negatives in a chain do multiply back to positive.

The friend and report lists that used to be public are not here. They moved
into the private vault. What the network sees is the score that resulted, never
the act that caused it.

### The derived cache

`derived` is the author's own calculated scores, out to `attestation.published_hops`
(3 by default). It is not a convenience: it is the **fourth term** of everyone
else's score, because the walk stops at hop 2 and depth 3 is filled in from
these summaries rather than reached. See **Why the walk stops at two** in
[reputation.md](reputation.md).

It is still never an input to a reader's own opinion at depths 0 to 2, which
are read from direct scores. It carries 0.0009 of the total, cannot make anyone
Trusted on its own, and exists mainly to lift a well-regarded stranger from
Blocked to Tolerated.

It carries `params`, a hash of the reputation parameters it was computed under,
because without that it would be worse than useless. Reputation is subjective
and configuration is per-user: the author may have a different `k`, a different
curve, `show_unrated` on. A reader whose parameters hash differently has to
recompute and the cache saves them nothing. A reader who took the numbers
anyway would silently adopt a stranger's settings.

This is the one place the project publishes a computed score, and
[reputation.md](reputation.md) argues against exactly that — a published score
goes stale the moment the curve is retuned. The `params` hash is what contains
the damage: stale numbers are *detectably* stale rather than quietly wrong.

## Adjustments

Re-signing and re-uploading a whole attestation every time someone emotes a
comment would be absurd — the file grows with every person you have ever rated,
and an emote changes one number in it.

So between republishes, each change is its own small record:

```json
{ "purpose": "reputablechat:adjustment:v1",
  "pubkey":  "...",
  "base_revision": 4,
  "seq":     7,
  "target":  "<pubkey>",
  "reputation": "0.5032",
  "trust":   "1",
  "ack":     "<64 hex>",
  "ts":      1710000000 }
```

`base_revision` names the attestation it amends and `seq` orders it within that
run, so a reader takes the snapshot and replays the adjustments on top in a
fixed order. Both are inside the signature, so the server cannot reorder them.

An **emote record is already its own adjustment** — it names the author, the
message and the reaction, and the author's score for that person follows from
it. Adjustments exist for the changes that have no other public record:
friending, reporting, and a hand-set score or multiplier. Those acts stay
private; only their arithmetic result is published.

A full attestation is republished after `attestation.resubmit_after_changes`
changes or `attestation.resubmit_after_seconds`, whichever comes first, and
supersedes every adjustment against the previous revision. Only score-changing
events count toward the tally. Posting a comment is not one — it cannot move a
number in the file, so counting it would republish for a reason that could not
have changed anything.

## Releases

A release record pins a version of the client:

```json
{ "purpose":   "reputablechat:release:v1",
  "publisher": "<Tim's pubkey>",
  "revision":  12,
  "label":     "0.4.0",
  "files":     { "index.html": "<64 hex>", "js/app.js": "<64 hex>" },
  "notes":     "...",
  "ack":       "<64 hex>",
  "ts":        1710000000 }
```

It is a **manifest**, not an archive. A zip would have been the obvious thing
and is the wrong thing: entry order, timestamps and compression level all land
in the bytes, so the same source tree hashes differently on two machines, and a
hash that depends on who built it cannot prove anything. A manifest of
`path → sha256` is reproducible from a clean checkout by anyone. Files live in
the content-addressed asset store, so an unchanged file costs nothing across
releases — the 29 KB Argon2 build is stored once, forever.

Publishing every release to the chain means the operator cannot serve one
person different JavaScript from everyone else without it being visible. That
is the whole point; the version history is a pleasant side effect.

Releases are cut when one is published, not per commit. The chain is not the
repository.

**Tim is the only publisher for now.** The record carries `publisher` so that a
per-user trusted-developer setting can arrive later without re-signing
anything, but nothing today consults it.

### Not built: actually loading one

The client still loads its UI from the server the ordinary way. A release
record is published and verifiable, and nothing executes off the chain yet.

That last step is deliberately not taken, because it is not the small step it
looks like. The private key lives in this origin's IndexedDB, and anything
served from this origin can use it. An old release loaded at the same address
would have full use of the current key, so pinning a version that shipped a
signing bug hands that bug back — and "load this old version, it was better" is
an easy thing to talk somebody into.

The options, when it comes to it:

- **Revocation and a floor.** A publisher-signed record makes known-bad
  versions unloadable. Cheap, covers the realistic case, and leaves the
  publisher deciding what you may run — which dents the point.
- **One origin per version** (`v12.chat.example`). Genuine isolation: the old
  version has no key at all and must ask the main origin to sign, which can
  show the user what it is signing. Needs wildcard DNS and TLS and a postMessage
  bridge.
- **No rail.** Pin whatever you like behind a warning.

Serving each version as ordinary static files from a content-addressed path
keeps `script-src 'self'` intact either way. Evaluating a bundle out of a JSON
blob would need `unsafe-eval`, and that CSP line is precisely what keeps
injected script from reaching the private key — so that approach is closed
whatever else is decided.

## What the server does with all this

The same as it did before, which is as little as possible. It verifies a
signature, rejects a rollback by revision, stores a row, and serves the bytes
back unchanged. It does not validate an `ack`, does not know what a reputation
is, and cannot tell a well-chosen reference from a bad one.

Storing rows rather than files is the balance this project wants: a record is
cheap to regenerate and expensive to store a million times over, and the
determinism that makes regeneration safe is already load-bearing for other
reasons.
