# Architecture

## The server does as little as possible

It never sees a seed, never holds a private key, and never computes a
reputation. What it does:

- hands out single-use login challenges
- **verifies every signature before storing anything**
- rejects revision rollbacks
- stores signed blobs and serves them back byte-identical
- validates the shape of everything arriving from a client

Signed blobs go out exactly as they came in. Re-serializing them server-side
would only create a way to break signatures.

Reputation is subjective, so it belongs on the client, which fetches signed
records and does the maths itself.

**MVP caveat:** `session.verify_signatures` is `false`, so the client currently
takes other people's attestations on trust. Until it is flipped on, a malicious
server can fabricate scores and put anyone in any bucket. The verification path
is written and tested; enabling it is one config key.

## What each account publishes, and what it keeps

Three records, split by **who needs to read it**.

**The identity declaration** — who somebody is, in their own words:

```json
{ "purpose": "reputablechat:identity:v1",
  "pubkey":  "...",
  "revision": 7,
  "ts":      1710000000,
  "handle":  "alice",
  "bio":     "hi",
  "icon":    "<sha256>.png",
  "master_pubkey": null, "previous_pubkey": null,
  "ack":     "<record hash>", "note": null }
```

**The attestation** — what they think of everybody else, as **scores**:

```json
{ "purpose": "reputablechat:attestation:v1",
  "pubkey":  "...",
  "revision": 4,
  "ts":      1710000000,
  "scores":  { "<pubkey>": { "reputation": "0.5", "trust": "1" } },
  "derived": { "hops": 3, "params": "<fingerprint>", "scores": { "<pubkey>": "0.045" } },
  "ack":     "<record hash>", "note": null }
```

Scores rather than the actions behind them: the curve runs once, in the author,
instead of in every reader. See the end of [reputation.md](reputation.md).

Decimal strings rather than numbers, because canonical serialization refuses a
float outright — it has no single textual form across languages — and the
Blocked line is `effective > 0`, which float drift flips people across.

**The vault** — everything private, sealed before it leaves the browser:

```json
{ "purpose":   "reputablechat:vault:v1",
  "pubkey":    "...",
  "revision":   3,
  "ts":        1710000000,
  "ciphertext": "<AES-256-GCM>",
  "iv":        "<96-bit nonce>" }
```

Inside it: `settings` (a sparse override tree mirroring `config/reputation.yml`
— the user layer of the three described under **Config layering** in
[reputation.md](reputation.md)), `voted` (which comments have already been
emoted on, so one-vote-per-comment survives moving to another device), `friends`
in the order they were added, the `seen` set, and `ratings` — the friending,
reporting and voting every published score was computed from.

The friend order is in there because it exists nowhere else: canonical
serialization sorts keys, so a ratings map read back from the server is in
public-key order and cannot say who was added first.

The server holds the vault so it cannot be lost, and **cannot read it**. The key
is derived from the same Argon2id output the identity key comes from, run
through HKDF under `seed.kdf.vault_domain` — one expensive derivation, two keys.
The signature covers the ciphertext, so the server cannot swap one vault for
another or alter one it cannot read. The only limit it can enforce is a byte
bound, because it cannot see the shape of what it is holding.

`public/js/vault.js` and `lib/reputable_chat/cryptography/vault.rb` are the two
halves — the browser writes a vault and, for the genesis account, so does a
terminal. `spec/vault_parity_spec.rb` seals in each language and opens in the
other, which is the only arrangement that catches a drift: each half opens its
own vaults perfectly.

The read route takes **no pubkey**: it uses the session's. Serving someone
else's vault is not expressible through the API rather than being a check that
has to stay correct.

### Two numbers, named apart

- The `:v1` at the end of `purpose` is the **shape** of the payload — which
  fields it has. It moves only when the field list changes. Records signed
  under the old shape stay valid and stay on the chain; the old shape has to
  stay understood so they can still be checked. It is part of the domain
  separation described under **Signed payloads** below.
- `revision` is a **counter for this one record**, climbing by one every time
  its owner republishes. It says nothing about the shape.

So `reputablechat:identity:v1` at `revision: 7` is the seventh copy of the first
shape. They never move together. Every record carries its own counter, so a
declaration at 7 beside a vault at 3 is two independent tallies rather than a
disagreement — one has been saved seven times and the other three.

They were both called `version` until it became clear that nobody could read
the two lines together and tell them apart.

The counter is **inside the signed payload**, which is the whole point of it.
Without it the server could serve an old copy of somebody's attestation to hide
a report, and the signature on that old copy would still verify perfectly —
because it is genuine, just stale. A counter the server cannot alter without
breaking the signature is what makes serving a stale copy detectable. Cheap
now, impossible to retrofit without invalidating every signature in the network.

Known limit: an attestation accumulates an entry per person ever scored, and
grows without bound. Fine for the MVP, needs chunking later. Adjustment records
already cover the other half of that problem — a single change between
republishes, rather than re-signing the whole snapshot to move one number.

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
| `reputablechat:identity:v1` | purpose, pubkey, revision, handle, bio, icon, master_pubkey, previous_pubkey, ack, note, ts |
| `reputablechat:attestation:v1` | purpose, pubkey, revision, scores, derived, ack, note, ts |
| `reputablechat:adjustment:v1` | purpose, pubkey, base_revision, seq, target, reputation, trust, ack, note, ts |
| `reputablechat:release:v1` | purpose, publisher, revision, label, files, notes, ack, note, ts |
| `reputablechat:notice:v1` | purpose, publisher, revision, kind, title, body, supersedes, ack, note, ts |
| `reputablechat:vault:v1` | purpose, pubkey, revision, ciphertext, iv, ts |

`config:v1` and `private-config:v1` were the two shapes these replaced. They are
gone rather than deprecated — see **Retired terms** in
[glossary.md](glossary.md).

Every chain record also carries `note` — free text the software never reads,
signed for whoever browses the raw chain. See **Notes** in [chain.md](chain.md).

Everything but `login` and `vault` carries `ack`, the record hashes of the most
recent records its author had seen. That is what makes these a chain rather than
a pile — see [chain.md](chain.md). The vault has none because nobody else ever
sees it, so there is nothing to anchor it to and nobody to prove anything to.

`room` in the message payload stops a message being replanted in a different
channel. `seq` and `prev` chain an author's own messages so the server cannot
silently drop or reorder one without it being detectable; `ack` chains it to
everybody else's records. The two catch different failures and both are kept. `ts` is the client's
clock and is attacker-controlled; the server records its own receipt time
separately and unsigned.

Edits and deletes will be new signed records referencing the original, never
mutations — a mutated record no longer matches its signature.

## Emotes

An emote is its own signed record naming the message it reacts to (by that
message's signature) and the room, so it cannot be transplanted. One per person
per message, enforced by a unique constraint rather than trusted from the
client, and the emote must be one the server publishes in `config/emotes.yml` —
an arbitrary string would otherwise be stored and rendered back to everyone.

The client tallies them per message and **drops emotes from blocked
accounts**, so a pile of spam accounts cannot inflate a count. Counts are
therefore per-viewer, like everything else here.

An emote also moves its author's score for the person emoted, and the emote
record is itself the adjustment that says so — see **Adjustments** in
[chain.md](chain.md).

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
config/genesis/<env>.json the genesis identity declaration; the chain hangs off its hash
config/server.yml         origin, database and image paths, size limits (env overrides)
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which emotes count positive, negative, neutral
config/bip39-english.txt  wordlist; one source of truth, served at /wordlist.txt

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  server_config.rb        config/server.yml, with env winning
  config.rb               three-layer config resolution
  params.rb               input validation
  genesis.rb              loads and verifies the committed genesis record
  dump.rb                 readable view of the database for an operator
  operator.rb             the genesis account's seed file, and signing from a terminal
  cryptography/           canonical, payload, record, signature, seed, vault
  reputation/             curve, ladder, rating, score, engine, session, fingerprint
  store/                  database (Sequel), images (content-addressed), memory

public/js/
  canonical.js            must match cryptography/canonical.rb byte for byte
  record.js               must match cryptography/record.rb
  fingerprint.js          must match reputation/fingerprint.rb
  seed.js                 must match cryptography/seed.rb
  identity.js             Argon2id, non-extractable keys, signing
  vault.js                must match cryptography/vault.rb -- seal, unseal, merge
  reputation.js           mirrors reputation/ in BigInt fixed-point
  session.js              mirrors reputation/session.rb
  names.js                which handle is shown bare and which gets a key suffix
  app.js                  UI wiring
```

## Not built yet

- Loading a published release off the chain. Release records are published and
  verifiable; nothing executes off the chain, because every version would run
  on the same origin as the private key. See the end of [chain.md](chain.md).
- Client-side verification of *other people's* attestations
  (`session.verify_signatures`). Your own vault is already verified, since
  detecting tampering is why it is signed.
- Key rotation. `master_pubkey` and `previous_pubkey` are in the signed shape
  and must still be null; nothing implements them.
- Removing an emote; currently an emote is final
- WebSocket delivery — messages currently poll every 4s
- Chunking an attestation, which currently grows an entry per person ever scored
- Federation between servers. The payload domain separation is already in place
  for it, but nothing else is. The principle it has to keep: a person sees
  messages whatever server they came from, and is largely unaware which server
  anyone else uses. What they see is decided by their friend list, never by
  where somebody's account lives.
