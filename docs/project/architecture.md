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
  "ratings": { "<pubkey>": { "friend": true, "reported": false, "net_votes": 12 } } }
```

Actions, not scores — see the end of [reputation.md](reputation.md) for why.

**Private** (the user's own settings): reputation config overrides, UI
preferences, notes. Currently thin; the split exists in the data model from day
one so that moving things into it later is not a migration.

`version` is a monotonic counter **inside the signed payload**. Without it the
server could serve an old copy of someone's config to hide a report, and the
signature on it would still verify perfectly. Cheap now, impossible to retrofit
without invalidating every signature in the network.

Known limit: a public config accumulates an entry per person ever rated, and
grows without bound. Fine for the MVP, needs chunking later.

## Signed payloads

Three shapes, each domain-separated. `lib/reputable_chat/crypto/payload.rb` and
`public/js/identity.js` must agree exactly.

| purpose | fields |
|---|---|
| `reputablechat:login:v1` | purpose, pubkey, nonce, origin, ts |
| `reputablechat:message:v1` | purpose, author, room, seq, prev, ts, body |
| `reputablechat:config:v1` | purpose, pubkey, version, ratings, ts |

`room` in the message payload stops a message being replanted in a different
channel. `seq` and `prev` chain an author's messages so the server cannot
silently drop or reorder one without it being detectable. `ts` is the client's
clock and is attacker-controlled; the server records its own receipt time
separately and unsigned.

Edits and deletes will be new signed records referencing the original, never
mutations — a mutated record no longer matches its signature.

## Canonical serialization

The browser signs bytes and the server verifies bytes, so both must produce
byte-identical output: sorted keys, no whitespace, UTF-8, floats refused
outright (they have no single textual form across languages).

`lib/reputable_chat/crypto/canonical.rb` and `public/js/canonical.js` are the
two halves. **If they ever disagree by one character, every signature silently
stops verifying** — `spec/canonical_parity_spec.rb` runs both over shared
fixtures and compares the bytes, and is the thing that catches that.

## Layout

```
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which emotes count positive, negative, neutral
config/bip39-english.txt  wordlist; one source of truth, served at /wordlist.txt

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  config.rb               three-layer config resolution
  params.rb               input validation
  crypto/                 canonical, payload, signature, seed (reference impl)
  reputation/             curve, ladder, rating, engine
  store/                  database (Sequel), memory (tests)

public/js/
  canonical.js            must match crypto/canonical.rb byte for byte
  seed.js                 must match crypto/seed.rb
  identity.js             Argon2id, non-extractable keys, signing
  reputation.js           mirrors reputation/ in BigInt fixed-point
  app.js                  UI wiring
```

## Not built yet

- Client-side config signature verification (`session.verify_signatures`)
- WebSocket delivery — messages currently poll every 4s
- Emote UI; `config/emotes.yml` is defined and served but nothing places them
- Friend/report UI; ratings are computed and verified but not yet editable
- Private config contents beyond the placeholder
- Federation between servers. The payload domain separation is already in place
  for it, but nothing else is.
