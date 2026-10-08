# ReputableChat: the chat

Decentralized chat where the reputation system *is* the moderation.

Every user signs with a keypair. People vouch for each other by friending and reacting positively, and report the rest. Those judgements propagate through the social graph, weighted by distance, so **"who is worth reading" is answered per viewer rather than globally**. There is no global score, no moderator, and no list of banned people — two readers can disagree about somebody and both be right.

Every signed record names the most recent records its author had seen, which makes the history a chain: a record cannot be quietly removed, back-dated, or shown to one person and not another. Records are anchored into it only when somebody who clears a reader's own bar acknowledges them, so being unvouched for means being left out — which is also what a sybil cannot buy its way past.

The server is deliberately close to useless. It verifies signatures and the rules, stores records, and serves them back unchanged. It never sees a seed, holds no private key but its own host account's, and never computes a reputation, because reputation is subjective and belongs on the machine of the person whose opinion it is.

The chat runs beside an [agnostic server](../server/README.md), which holds the chain and checks every record against [the rules](../docs/project/rules/v0.001.md); the chat passes its users' records there and keeps a copy of the ones it shows.

**Status: early.** Reputation, identity, cryptography and the chain's record shapes are built and tested. The client is being moved onto those records a stage at a time. The chat UI is a working skeleton.

## Running it

```bash
cd server && bundle install && bundle exec puma     # the agnostic server, on 9393
cd chat && bundle install && bundle exec rake spec && bundle exec puma
```

The chat listens on 9292 and finds its agnostic server at `http://localhost:9393` (`chain_url` in `config/server.yml`, or `CHAIN_URL`), and waits for it to be live before opening its own port. On one machine they can share an address on different ports, or share a port behind a reverse proxy under different hostnames: each announces its own address, the agnostic server on its host account's identity declaration and the chat on its `service` notice, so other servers never confuse the two. They share one host account, kept in `host/` at the root, outside both. The chat's specs start agnostic servers of their own. `bundle exec rake curve` prints the current curve and ladder.

## Deploying

The chat server's settings live in `config/server.yml`, which documents itself: paths, the optional public origin, and the size limits an operator gets to choose. Every key can be overridden by the matching environment variable for deployments that inject configuration rather than edit files.

Two things that bite:

- **Behind a reverse proxy, pass the browser's address through.** No domain or IP needs configuring: the server signs logins in at whatever address it was reached at. Behind a proxy that means the proxy must forward `Host` and `X-Forwarded-Proto` -- Caddy does by default; nginx needs `proxy_set_header Host $host;` and `proxy_set_header X-Forwarded-Proto $scheme;`. Otherwise every login fails, and the error names both addresses. Setting `origin` (or `ORIGIN`) pins the accepted addresses instead, which also stops a malicious server relaying a `tim.rb` login.
- **`SESSION_SECRET` is environment-only**, because `config/server.yml` is in the repository. Without it a random secret is generated at boot, which is fine locally and signs everyone out on every restart.

The genesis account has to exist before the server will start. `bundle exec rake genesis` makes one; every client needs the same hash before it has fetched anything, so it is committed rather than downloaded.

## How it fits together

**Reputation** is a weighted opinion, not a score. Your own judgement dominates; the rest of the network contributes by distance. Everyone lands in one of three buckets — Trusted, Tolerated, Blocked — and an account nobody has vouched for sits at exactly zero, which is to say invisible. That is the sybil defense, and the reason a new account starts out trusting the genesis: somebody has to be visible first.

**Identity** is a seed phrase. It derives the keypair, and the account is identified by the hash of its first identity declaration. Without a master key there is no recovery — losing the seed loses everything. Private keys are non-extractable and never leave the browser.

**The chain** is not a blockchain in the mining sense. It has no proof of work, orders nothing, and settles nothing. It exists so that history is tamper evident and so that inclusion in it has to be earned from somebody.

Full design — and the numbers, which live in config rather than in prose: [glossary](../docs/project/glossary.md) · [reputation](../docs/project/reputation.md) · [identity](../docs/project/identity.md) · [chain](../docs/project/chain.md) · [architecture](ARCHITECTURE.md)

## Security

- Seeds are BIP39 words stretched through Argon2id, sized in `config/reputation.yml` against a documented attack.
- Private keys are non-extractable WebCrypto keys in IndexedDB. The seed is never stored or transmitted.
- The private vault is encrypted under a separate key derived from the same seed, so the server holds it without being able to read it.
- **MVP: the client does not verify other people's attestation signatures** (`session.verify_signatures`). Until that is on, a malicious server can fabricate ratings.
