# Architecture

## The server does as little as possible

It never sees a seed, never holds a private key, and never computes a
reputation. What it does:

- hands out single-use login challenges
- **verifies every signature before storing anything**
- rejects config rollbacks by version
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
  "version": 7,
  "ts":      1710000000,
  "profile": { "username": "alice", "message": "hi", "icon": "<sha256>.png" },
  "ratings": { "<pubkey>": { "friend": true, "reported": false, "net_votes": 12 } } }
```

The profile is signed alongside the ratings, so the server cannot alter a
display name, bio or icon. Names are not unique — the key is the identity, and
the UI shows a key fingerprint beside every name.

Actions, not scores — see the end of [reputation.md](reputation.md) for why.

**Private** (signed, served to nobody but its owner):

```json
{ "purpose":  "reputablechat:private-config:v1",
  "pubkey":   "...",
  "version":  3,
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

`version` is a monotonic counter **inside the signed payload**. Without it the
server could serve an old copy of someone's config to hide a report, and the
signature on it would still verify perfectly. Cheap now, impossible to retrofit
without invalidating every signature in the network.

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

Three shapes, each domain-separated. `lib/reputable_chat/cryptography/payload.rb` and
`public/js/identity.js` must agree exactly.

| purpose | fields |
|---|---|
| `reputablechat:login:v1` | purpose, pubkey, nonce, origin, ts |
| `reputablechat:message:v1` | purpose, author, room, seq, prev, ts, body |
| `reputablechat:config:v1` | purpose, pubkey, version, profile, ratings, ts |
| `reputablechat:private-config:v1` | purpose, pubkey, version, settings, voted, ts |
| `reputablechat:emote:v1` | purpose, author, room, message, emote, ts |

`room` in the message payload stops a message being replanted in a different
channel. `seq` and `prev` chain an author's messages so the server cannot
silently drop or reorder one without it being detectable. `ts` is the client's
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
config/server.yml         origin, database and image paths (env overrides)
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which emotes count positive, negative, neutral
config/bip39-english.txt  wordlist; one source of truth, served at /wordlist.txt

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  server_config.rb        config/server.yml, with env winning
  config.rb               three-layer config resolution
  params.rb               input validation
  cryptography/           canonical, payload, signature, seed (reference impl)
  reputation/             curve, ladder, rating, engine, session
  store/                  database (Sequel), images (content-addressed), memory

public/js/
  canonical.js            must match cryptography/canonical.rb byte for byte
  seed.js                 must match cryptography/seed.rb
  identity.js             Argon2id, non-extractable keys, signing
  reputation.js           mirrors reputation/ in BigInt fixed-point
  session.js              mirrors reputation/session.rb
  app.js                  UI wiring
```

## Not built yet

- Client-side verification of *other people's* configs
  (`session.verify_signatures`). Your own private config is already verified,
  since detecting tampering is why it is signed.
- Encrypting the private config so the server cannot read it
- Removing a reaction; currently a reaction is final
- WebSocket delivery — messages currently poll every 4s
- Private config contents beyond the placeholder
- Federation between servers. The payload domain separation is already in place
  for it, but nothing else is.
