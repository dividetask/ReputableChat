# Architecture

## The server does as little as possible

It never sees a seed, never holds a private key, and never computes a reputation. What it does:

- hands out single-use login challenges
- **verifies every signature before storing anything**
- stores signed blobs and serves them back byte-identical
- validates everything arriving from a client against the rules

Signed blobs go out exactly as they came in. Re-serializing them server-side would only create a way to break signatures.

Reputation is subjective, so it belongs on the client, which fetches signed records and does the maths itself.

**MVP caveat:** `session.verify_signatures` is `false`, so the client currently takes other people's attestations on trust. Until it is flipped on, a malicious server can fabricate ratings and put anyone in any bucket. The verification path is written and tested; enabling it is one config key.

## Records

Every record on the chain is defined in [rules/v0.001.md](rules/v0.001.md), with signed examples in [rules/v0.001-examples.md](rules/v0.001-examples.md). The rules are the reference; this page does not repeat them. Why the chain is built the way it is lives in [chain.md](chain.md).

What each account publishes, and what it keeps private, is split by **who needs to read it**:

- **The identity declaration** — who somebody is, in their own words: handle, avatar, bio, and keys (working and master).
- **The attestation** — what they think of everybody else, as ratings and trust multipliers keyed by account ID. Ratings rather than the actions behind them: the curve runs once, in the author, instead of in every reader. See the end of [reputation.md](reputation.md).
- **The vault** — everything private, sealed before it leaves the browser. The server holds it but keeps it private; it is not a record on the chain, and the rules do not govern it.

Decimals are strings rather than numbers, because canonical serialization refuses a float outright — it has no single textual form across languages — and the Blocked line is `effective > 0`, which float drift flips people across.

The third part of every record's `type` is the rules version it conforms to. A record's identity is its record hash, which covers the payload and the signature; an account's identity is its account ID, the record hash of its first identity declaration.

## The vault

Inside it: `settings` (a sparse override tree mirroring `config/reputation.yml` — the user layer of the three described under **Configuration layering** in [reputation.md](reputation.md)), `voted` (which messages have already been reacted to, so one vote per message survives moving to another device), `friends` in the order they were added, the `seen` set, and `ratings` — the friending, reporting and voting every published rating was computed from.

The friend order is in there because it exists nowhere else: canonical serialization sorts keys, so a ratings map read back from the server is in key order and cannot say who was added first.

The server holds the vault so it cannot be lost, and **cannot read it**. The key is derived from the same Argon2id output the identity key comes from, run through HKDF under `seed.kdf.vault_domain` — one expensive derivation, two keys. The signature covers the ciphertext, so the server cannot swap one vault for another or alter one it cannot read. It carries a `revision`, outside the ciphertext, so the server can refuse a rollback, and the only other limit it can enforce is a byte bound, because it cannot see the shape of what it is holding.

`public/js/vault.js` and `lib/reputable_chat/cryptography/vault.rb` are the two halves — the browser writes a vault and, for the genesis account, so does a terminal. `spec/vault_parity_spec.rb` seals in each language and opens in the other, which is the only arrangement that catches a drift: each half opens its own vaults perfectly.

The read route takes **no pubkey**: it uses the session's. Serving someone else's vault is not expressible through the API rather than being a check that has to stay correct.

Known limit: an attestation accumulates an entry per person ever rated, and grows without bound. Fine for the MVP, needs chunking later.

## Images

Content-addressed: a file's name is the SHA-256 of its bytes plus an extension **sniffed from those bytes**, never from a claimed content type or filename. The server derives the name rather than trusting one, so a reader can re-hash what they fetched to confirm it is what the author signed. Names are 64 hex characters plus a known extension, which is also the only path check the serving route needs.

This server stores PNG, JPEG, GIF and WebP only, up to 256 KB. **SVG is deliberately excluded** — it is a script-bearing document, not an image. The rules accept any avatar name; this is what this server is willing to store and serve.

## Login

Logging in signs a challenge from the server. It is not a record and never reaches the chain; see **Login** in [identity.md](identity.md).

## Reactions

A reaction is its own signed record naming the records it reacts to in `target`, with the reaction itself — an emoji, a word — in its body. An account may react to the same record any number of times, and each client decides which reactions count as positive, negative or neutral.

The client tallies them per message and **drops reactions from blocked accounts**, so a pile of spam accounts cannot inflate a count. Counts are therefore per-viewer, like everything else here.

A reaction also moves its author's rating of the person reacted to. That rating is private until their next attestation carries the number it came to.

## Record hashes

`ack` and `target` name records by their hash:

```
SHA256(canonical_payload + "\n" + signature)
```

A signature identifies a payload; a record hash identifies the record, signature included, which is what a link has to cover to be tamper-evident as a whole. `cryptography/record.rb` and `public/js/record.js` are the two halves, and `spec/record_parity_spec.rb` checks they agree.

Edits and deletes will be new signed records targeting the original, never mutations — a mutated record no longer matches its signature.

## Canonical serialization

The browser signs bytes and the server verifies bytes, so both must produce byte-identical output: sorted keys, no whitespace, UTF-8, floats refused outright (they have no single textual form across languages).

`lib/reputable_chat/cryptography/canonical.rb` and `public/js/canonical.js` are the two halves. **If they ever disagree by one character, every signature silently stops verifying** — `spec/canonical_parity_spec.rb` runs both over shared fixtures and compares the bytes, and is the thing that catches that.

## Layout

```
config/genesis/<env>.json the genesis identity declaration; the chain hangs off its hash
config/host/<env>.json    this server's host account, acknowledging the genesis (optional)
config/server.yml         origin, database and image paths, size limits (env overrides)
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which reactions count positive, negative, neutral
config/bip39-english.txt  wordlist; one source of truth, served at /wordlist.txt

docs/project/rules/       the rules, one file per version, and signed examples

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  server_config.rb        config/server.yml, with env winning
  config.rb               three-layer config resolution
  params.rb               input validation
  committed_declaration.rb  what the genesis and host records share: loading, checks, icon
  genesis.rb              loads and verifies the committed genesis record
  host.rb                 loads and verifies the host account, which must ack the genesis
  dump.rb                 readable view of the database for an operator
  operator.rb             the genesis and host accounts' seed files, and signing from a terminal
  cryptography/           canonical, payload, record, signature, seed, vault
  reputation/             curve, ladder, rating, score, decimals, engine, session
  store/                  database (Sequel), images (content-addressed), memory

public/js/
  canonical.js            must match cryptography/canonical.rb byte for byte
  record.js               must match cryptography/record.rb
  seed.js                 must match cryptography/seed.rb
  identity.js             Argon2id, non-extractable keys, signing
  vault.js                must match cryptography/vault.rb -- seal, unseal, merge
  reputation.js           mirrors reputation/ in BigInt fixed-point
  session.js              mirrors reputation/session.rb
  names.js                which handle is shown bare and which gets a suffix
  app.js                  UI wiring
```

## Not built yet

- The code still signs the shapes that came before the rules — see **Not built** under **Rules** in [chain.md](chain.md).
- Loading the client from a release. See the end of [chain.md](chain.md).
- Client-side verification of *other people's* attestations (`session.verify_signatures`). Your own vault is already verified, since detecting tampering is why it is signed.
- Master keys and key-change notices. The rules define them; nothing implements them.
- WebSocket delivery — messages currently poll every 4s
- Chunking an attestation, which currently grows an entry per person ever rated
- Federation between servers. The principle it has to keep: a person sees messages whatever server they came from, and is largely unaware which server anyone else uses. What they see is decided by their friend list, never by where somebody's account lives.
