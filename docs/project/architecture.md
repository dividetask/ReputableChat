# Architecture

## The server does as little as possible

It never sees a seed, never holds a private key, and never computes a
reputation. What it does:

- hands out single-use login challenges
- **verifies every signature before storing anything**
- rejects config rollbacks by revision
- stores signed blobs and serves them back byte-identical
- validates the shape of everything arriving from a client

Signed blobs go out exactly as they came in. Re-serializing them server-side
would only create a way to break signatures.

Reputation is subjective, so it belongs on the client, which fetches signed
configs and does the maths itself.

**MVP caveat:** `session.verify_signatures` is `false`, so the client currently
takes configs on trust. Until it is flipped on, a malicious server can
fabricate ratings and put anyone in any bucket. The verification path is
written and tested; enabling it is one config key.

## Public and private config

Split by **who needs to read it**.

**Public** (signed, served to anyone):

```json
{ "purpose": "reputablechat:config:v1",
  "pubkey":  "...",
  "revision": 7,
  "ts":      1710000000,
  "profile": { "username": "alice", "message": "hi", "icon": "<sha256>.png" },
  "ratings": { "<pubkey>": { "friend": true, "reported": false, "net_votes": 12 } } }
```

**Two numbers here count different things**, and they are named apart on
purpose:

- The `:v1` at the end of `purpose` is the **shape** of the payload — which
  fields it has. It moves only when the field list changes, which invalidates
  every signature ever made under the old shape. It is part of the domain
  separation described under **Signed payloads** below.
- `revision` is a **counter for this one record**, climbing by one every time
  its owner republishes. It says nothing about the shape.

So `reputablechat:config:v1` at `revision: 7` is the seventh copy of the first
shape. They never move together. Every record carries its own counter, so a
public config at 7 sitting beside a private one at 3 is two independent tallies
rather than a disagreement — one has been saved seven times and the other
three.

They were both called `version` until it became clear that nobody could read
the two lines together and tell them apart.

The profile is signed alongside the ratings, so the server cannot alter a
display name, bio or icon. Names are not unique — the key is the identity, and
the UI shows a key fingerprint beside every name.

Actions, not scores — see the end of [reputation.md](reputation.md) for why.

**Private** (signed, served to nobody but its owner):

```json
{ "purpose":  "reputablechat:private-config:v1",
  "pubkey":   "...",
  "revision":  3,
  "ts":       1710000000,
  "settings": { "display": { "show_unrated": true } },
  "voted":    ["<message signature>", "..."] }
```

`settings` is a sparse override tree mirroring `config/reputation.yml` — the
user layer of the three described under **Config layering** in
[reputation.md](reputation.md). `voted` is which comments have already been
emoted on, so one-vote-per-comment survives moving to another device.

The server holds it so it cannot be lost, and validates only that `settings` is
a bounded structure of scalars — it never interprets the contents.

The read route takes **no pubkey**: it uses the session's. Serving someone
else's private config is not expressible through the API rather than being a
check that has to stay correct.

**Signed, not encrypted.** This is private from other users, not from the
server operator, who can read it. Making it opaque to the server means
encrypting under a key derived from the seed — worth doing, not done.

The counter is **inside the signed payload**, which is the whole point of it.
Without it the server could serve an old copy of someone's config to hide a
report, and the signature on that old copy would still verify perfectly —
because it is genuine, just stale. A counter the server cannot alter without
breaking the signature is what makes serving a stale copy detectable. Cheap
now, impossible to retrofit without invalidating every signature in the
network.

Known limit: a public config accumulates an entry per person ever rated, and
grows without bound. Fine for the MVP, needs chunking later.

## Images

Content-addressed: a file's name is the SHA-256 of its bytes plus an extension
**sniffed from those bytes**, never from a claimed content type or filename.
The server derives the name rather than trusting one, so a reader can re-hash
what they fetched to confirm it is what the author signed. Names are 64 hex
characters plus a known extension, which is also the only path check the
serving route needs.

PNG, JPEG, GIF and WebP only, 256 KB. **SVG is deliberately excluded** — it is a
script-bearing document, not an image.

## Signed payloads

Each shape is domain-separated: the `purpose` string is signed along with
everything else, so a signature made for one kind of record cannot be presented
as another, and the trailing `:v1` pins which field list was signed. Adding or
removing a field means a new suffix, because the canonical bytes change and
every old signature stops verifying against the new shape.
 `lib/reputable_chat/cryptography/payload.rb` and
`public/js/identity.js` must agree exactly.

| purpose | fields |
|---|---|
| `reputablechat:login:v1` | purpose, pubkey, nonce, origin, ts |
| `reputablechat:message:v1` | purpose, author, room, seq, prev, reply_to, ack, note, ts, body |
| `reputablechat:emote:v1` | purpose, author, room, message, emote, ack, note, ts |
| `reputablechat:user:v1` | purpose, pubkey, revision, handle, bio, icon, master_pubkey, previous_pubkey, ack, note, ts |
| `reputablechat:attestation:v1` | purpose, pubkey, revision, scores, derived, ack, note, ts |
| `reputablechat:adjustment:v1` | purpose, pubkey, base_revision, seq, target, reputation, trust, ack, note, ts |
| `reputablechat:release:v1` | purpose, publisher, revision, label, files, notes, ack, note, ts |
| `reputablechat:notice:v1` | purpose, publisher, revision, kind, title, body, supersedes, ack, note, ts |
| `reputablechat:config:v1` | superseded by `user` + `attestation` |
| `reputablechat:private-config:v1` | purpose, pubkey, revision, settings, voted, ts |

Every chain record also carries `note` — free text the software never reads,
signed for whoever browses the raw chain. See **Notes** in [chain.md](chain.md).

Everything but `login` and `private-config` carries `ack`, the hash of the last
record its author had seen. That is what makes these a chain rather than a pile
— see [chain.md](chain.md). `private-config` has none because nobody else ever
sees it, so there is nothing to anchor it to.

`room` in the message payload stops a message being replanted in a different
channel. `seq` and `prev` chain an author's own messages so the server cannot
silently drop or reorder one without it being detectable; `ack` chains it to
everybody else's records. The two catch different failures and both are kept. `ts` is the client's
clock and is attacker-controlled; the server records its own receipt time
separately and unsigned.

Edits and deletes will be new signed records referencing the original, never
mutations — a mutated record no longer matches its signature.

## Reactions

A reaction is its own signed record naming the message it reacts to (by that
message's signature) and the room, so it cannot be transplanted. One per person
per message, enforced by a unique constraint rather than trusted from the
client, and the emote must be one the server publishes in `config/emotes.yml` —
an arbitrary string would otherwise be stored and rendered back to everyone.

The client tallies them per message and **drops reactions from blocked
accounts**, so a pile of spam accounts cannot inflate a count. Counts are
therefore per-viewer, like everything else here.

Reactions are also folded into the reacting user's public config as
`net_votes`, which is what reputation reads. The records are the display form;
the aggregate is the reputation form. They can in principle disagree, since
nothing forces a client to publish both.

## Record hashes

`ack`, `prev`, `reply_to` and an emote's target all name a record by its hash:

```
SHA256("reputablechat:record:v1\n" + canonical_payload + "\n" + signature)
```

They used to name signatures. A signature identifies a payload; a record hash
identifies the record, signature included, which is what a link has to cover to
be tamper-evident as a whole. `cryptography/record.rb` and `public/js/record.js`
are the two halves and `spec/record_parity_spec.rb` checks they agree.

## Canonical serialization

The browser signs bytes and the server verifies bytes, so both must produce
byte-identical output: sorted keys, no whitespace, UTF-8, floats refused
outright (they have no single textual form across languages).

`lib/reputable_chat/cryptography/canonical.rb` and `public/js/canonical.js` are the
two halves. **If they ever disagree by one character, every signature silently
stops verifying** — `spec/canonical_parity_spec.rb` runs both over shared
fixtures and compares the bytes, and is the thing that catches that.

## Layout

```
config/genesis/tim.json   the genesis user record; the chain hangs off its hash
config/server.yml         origin, database and image paths (env overrides)
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which emotes count positive, negative, neutral
config/bip39-english.txt  wordlist; one source of truth, served at /wordlist.txt

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  server_config.rb        config/server.yml, with env winning
  config.rb               three-layer config resolution
  params.rb               input validation
  genesis.rb              loads and verifies the committed genesis record
  cryptography/           canonical, payload, record, signature, seed
  reputation/             curve, ladder, rating, engine, session
  store/                  database (Sequel), images (content-addressed), memory

public/js/
  canonical.js            must match cryptography/canonical.rb byte for byte
  record.js               must match cryptography/record.rb
  fingerprint.js          must match reputation/fingerprint.rb
  seed.js                 must match cryptography/seed.rb
  identity.js             Argon2id, non-extractable keys, signing
  reputation.js           mirrors reputation/ in BigInt fixed-point
  session.js              mirrors reputation/session.rb
  app.js                  UI wiring
```

## Not built yet

- Loading a published release off the chain. Release records are published and
  verifiable; nothing executes off the chain, because every version would run
  on the same origin as the private key. See the end of [chain.md](chain.md).
- Encrypting the private vault under a seed-derived key (`seed.kdf.vault_domain`
  is reserved for it)
- Client-side verification of *other people's* configs
  (`session.verify_signatures`). Your own private config is already verified,
  since detecting tampering is why it is signed.
- Encrypting the private config so the server cannot read it
- Removing a reaction; currently a reaction is final
- WebSocket delivery — messages currently poll every 4s
- Private config contents beyond the placeholder
- Federation between servers. The payload domain separation is already in place
  for it, but nothing else is.
