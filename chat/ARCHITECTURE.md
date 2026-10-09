# The chat's architecture

The chat app: the browser client and the server behind it -- login, the vault, images, and the chat UI. It runs beside an agnostic server (`../server/`, described in the root [architecture](../docs/project/architecture.md) and [server/README.md](../server/README.md)) and leaves the chain to it. Each server runs one agnostic server, and one instance of each app it supports beside it. An app is a client of its agnostic server: it never judges a record against the rules, and holds its own users to its own terms before passing their records on.

Paths below are inside `chat/` unless they start with `../`.

## The chat server does as little as possible

It never sees a seed, never holds a private key, and never computes a reputation. The one exception is a server's host account: the agnostic server generates one on first boot and keeps its working seed phrase on the machine, 0600, because a heartbeat has to be signed by somebody and nobody sits at a browser for it. Its master phrase is written beside it once, for the operator to move off the machine. The working key signs heartbeats and nothing else, and it is the server's own account, never anybody else's. What the chat server does:

- hands out single-use login challenges
- holds its own clients to its own terms -- signed by the session's own key for the session's own account, a record the chat keeps, timestamped within an hour of its clock, no integer JavaScript cannot read exactly, within the limits in `config/server.yml` -- and passes what meets them to its agnostic server (`chain_url`), which judges it against the rules. The agnostic server's verdict is the answer the client gets. The agnostic server takes records only in uploads signed by an account on its chain, so the chat signs each upload as the host account they share (`Host#upload_headers`).
- keeps a copy of the records it shows (`chain/mirror.rb`), pulled from the agnostic server in the order that server accepted them: records about the chain itself (identity declarations, attestations, heartbeats, releases, and the notices the rules define) and the chat's own (messages and reactions typed `:chat`, and the notice kinds in `config/notices.yml`). Another app's records are not its business, though they reach it anyway inside other records' histories.
- asks the agnostic server for what needs the chain: each record's state, the account a key signs for, an account's newest declaration and attestation.
- signs as its agnostic server's host account -- one account per server -- and announces itself to other chat servers with it: a `service` notice typed `:chat` carrying the address it is reached at, published on the first boot with an address and whenever that changes. The chat client never signs one and the server refuses one from a client.
- fetches a file it lacks from the chat servers that announced themselves (`file_peers.rb`). The chain names files by hash but does not carry them; each app shares its own. A server is asked only once it answers at its address as the announcing account, never at a private, loopback or link-local address unless allowed, and only over https in production. Which is chosen at random, weighted by the agnostic server's ratings of its account and skipping any rated below zero or that failed lately. One that answers without the file is put off too, for `file_peers.missing_penalty` of what a failure costs, since it answered. Each outcome is reported to the agnostic server, signed by the host account they share, and counts toward that account's rating. An address is looked up once and the address checked is the one connected to. The bytes are kept only if they hash to the name. A request from another chat server is never passed on.
- shares one host account with its agnostic server, kept in `host/` at the root of the repository, outside both apps. The two run side by side on different ports (9292 and 9393 by default) or behind a proxy under different names, and each announces its own address, so other servers never confuse them.
- serves signed blobs back byte-identical

Signed blobs go out exactly as they came in. Re-serializing them server-side would only create a way to break signatures.

Reputation is subjective, so it belongs on the client, which fetches signed records and does the maths itself.

**MVP caveat:** `session.verify_signatures` is `false`, so the client currently takes other people's attestations on trust. Until it is flipped on, a malicious server can fabricate ratings and put anyone in any bucket. The verification path is written and tested; enabling it is one config key.

## Records

Every record on the chain is defined in [rules/v0.001.md](../docs/project/rules/v0.001.md), with signed examples in [rules/v0.001-examples.md](../docs/project/rules/v0.001-examples.md); why the chain is built the way it is lives in [chain.md](../docs/project/chain.md). The one thing an account keeps private is its vault, below, which is not a record.

## The vault

Inside it: `settings` (a sparse override tree mirroring `config/reputation.yml` — the user layer of the three described under **Configuration layering** in [reputation.md](../docs/project/reputation.md)), `voted` (which messages have already been reacted to, so one vote per message survives moving to another device), `friends` in the order they were added, the `seen` list, and `ratings` — the friending, reporting and voting every published rating was computed from.

The friend list is in there, in order, because the order exists nowhere else: canonical serialization sorts keys, so a ratings map read back from the server is in key order and cannot say who was added first.

The server holds the vault so it cannot be lost, and **cannot read it**. The key is derived from the same Argon2id output the identity key comes from, run through HKDF under `seed.kdf.vault_domain` — one expensive derivation, two keys. The signature covers the ciphertext, so the server cannot swap one vault for another or alter one it cannot read. The server keeps only the latest copy, and the only limit it can enforce is a byte bound, because it cannot see the shape of what it is holding.

`public/js/vault.js` and `lib/reputable_chat/cryptography/vault.rb` are the two halves — the browser writes a vault and, for the genesis account, so does a terminal. `spec/vault_parity_spec.rb` seals in each language and opens in the other, which is the only arrangement that catches a drift: each half opens its own vaults perfectly.

The read route takes **no pubkey**: it uses the session's. Serving someone else's vault is not expressible through the API rather than being a check that has to stay correct.

Known limit: an attestation accumulates an entry per person ever rated, and grows without bound. Fine for the MVP, needs chunking later.

## Images

Content-addressed: a file's name is the SHA-256 of its bytes plus an extension **sniffed from those bytes**, never from a claimed content type or filename. The server derives the name rather than trusting one, so a reader can re-hash what they fetched to confirm it is what the author signed. Names are 64 hex characters plus a known extension, which is also the only path check the serving route needs.

This server stores PNG, JPEG, GIF and WebP only, up to 256 KB. **SVG is deliberately excluded** — it is a script-bearing document, not an image.

## Login

Logging in signs a challenge from the server. It is not a record and never reaches the chain; see **Login** in [identity.md](../docs/project/identity.md).

## Reactions

The client tallies them per message, counting each person's latest reaction to it, and **drops reactions from blocked accounts**, so a pile of spam accounts cannot inflate a count. Counts are therefore per-viewer, like everything else here.

A reaction also moves its author's rating of the person reacted to. That rating is private until their next attestation carries the number it came to.

## Record hashes

`cryptography/record.rb` and `public/js/record.js` are the two halves, and `spec/record_parity_spec.rb` checks they agree. Why links name records by hash is in [chain.md](../docs/project/chain.md).

Edits and deletes will be new signed records targeting the original, never mutations — a mutated record no longer matches its signature.

## Canonical serialization

The browser signs bytes and the server verifies bytes, so both must produce the canonical form the rules define, byte for byte.

`chat/lib/reputable_chat/cryptography/canonical.rb` and `chat/public/js/canonical.js` are the two halves, and `server/lib/agnostic/canonical.rb` is a third, which refuses any payload whose bytes it cannot reproduce exactly. **If they ever disagree by one character, every signature silently stops verifying** — `spec/canonical_parity_spec.rb` runs both over shared fixtures and compares the bytes, and is the thing that catches that.

## Layout

```
../docs/project/apps/     one document per app: what it shows, and what it does with the rest
config/genesis/<env>.json the genesis identity declaration; the chain hangs off its hash
config/server.yml         optional origin, database and image paths, size limits (env overrides)
config/reputation.yml     tunable reputation parameters (the defaults layer)
config/emotes.yml         which reactions count positive, negative, neutral
config/notices.yml        the notice kinds the chat shows, and takes from its clients
../shared/bip39-english.txt  wordlist, at the root for both apps; served at /wordlist.txt

lib/reputable_chat/
  app.rb                  Roda routes, CSP, sessions
  server_config.rb        config/server.yml, with env winning
  origin.rb               the origin a login is signed for: configured, or from the request
  config.rb               three-layer config resolution
  params.rb               input validation
  committed_declaration.rb  what the genesis and host records share: loading, checks, icon
  genesis.rb              loads and verifies the committed genesis record
  host.rb                 the host account, shared with the agnostic server: its seed, checked against it
  chain_client.rb         the line to the agnostic server
  file_peers.rb           fetching files from other chat servers
  dump.rb                 readable view of the database for an operator
  chain/                  envelope (a light read of a record), mirror (the records the chat keeps),
                          connection (waiting for and checking the agnostic server), service (announcing)
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

- Loading the client from a release. See the end of [chain.md](../docs/project/chain.md).
- Client-side verification of *other people's* attestations (`session.verify_signatures`). Your own vault is already verified, since detecting tampering is why it is signed.
- Key changes from the browser. The chat passes them on and the genesis and host accounts declare master keys, but the browser declares a working key only and has no way to change one.
- WebSocket delivery — messages currently poll every 4s
- Chunking an attestation, which currently grows an entry per person ever rated
- Federation's principle, which the agnostic servers' syncing has to keep: a person sees messages whatever server they came from, and is largely unaware which server anyone else uses. What they see is decided by their friend list, never by where somebody's account lives.
