# ReputableChat

Decentralized chat where the reputation system *is* the moderation.

Every user is a keypair. People vouch for each other by friending and reacting
positively, and report the rest. Those judgements propagate through the social
graph, weighted by distance, so **"who is worth reading" is answered per viewer
rather than globally**. There is no global score, no moderator, and no list of
banned people — two readers can disagree about somebody and both be right.

Every signed record names the last record its author had seen, which makes the
history a chain: a record cannot be quietly removed, back-dated, or shown to one
person and not another. Records are anchored into it only when somebody who
clears a reader's own bar acknowledges them, so being unvouched for means being
left out — which is also what a sybil cannot buy its way past.

The server is deliberately close to useless. It verifies signatures, stores
blobs, and serves them back unchanged. It never sees a seed, never holds a
private key, and never computes a reputation, because reputation is subjective
and belongs on the machine of the person whose opinion it is.

**Status: early.** Reputation, identity, cryptography and the chain's record
shapes are built and tested. The client is being moved onto those records a
stage at a time. The chat UI is a working skeleton.

## Running it

```bash
bundle install
bundle exec rake spec      # test suite
bundle exec puma           # http://localhost:9292
```

`bundle exec rake curve` prints the current curve, ladder and safety window.

## Deploying

Server settings live in `config/server.yml`, which documents itself: paths,
the public origin, and the size limits an operator gets to choose. Every key
can be overridden by the matching environment variable for deployments that
inject configuration rather than edit files.

Two things that bite:

- **`origin` must match the URL browsers actually reach you at.** It travels
  inside the signed login payload, so a mismatch rejects every login as a bad
  signature.
- **`SESSION_SECRET` is environment-only**, because `config/server.yml` is in
  the repository. Without it a random secret is generated at boot, which is
  fine locally and signs everyone out on every restart.

The genesis account has to exist before the server will start. `bundle exec
rake genesis` makes one; every client needs the same hash before it has fetched
anything, so it is committed rather than downloaded.

## How it fits together

**Reputation** is a weighted opinion, not a score. Your own judgement dominates;
the rest of the network contributes by distance, and the walk stops early and
fills the last of it in from what your contacts have already worked out.
Everyone lands in one of three buckets — Trusted, Tolerated, Blocked — and an
account nobody has vouched for sits at exactly zero, which is to say invisible.
That is the sybil defense, and the reason a new account starts out trusting the
genesis: somebody has to be visible first.

**Identity** is a seed phrase and nothing else. It derives the keypair, the
public half is the account, and there is no recovery — losing it loses
everything. Private keys are non-extractable and never leave the browser.

**The chain** is not a blockchain in the mining sense. It has no proof of work,
orders nothing, and settles nothing. It exists so that history is tamper
evident and so that inclusion in it has to be earned from somebody.

Full design — and the numbers, which live in config rather than in prose:
[glossary](docs/project/glossary.md) ·
[reputation](docs/project/reputation.md) ·
[identity](docs/project/identity.md) ·
[chain](docs/project/chain.md) ·
[architecture](docs/project/architecture.md)

## Security

- Seeds are BIP39 words stretched through Argon2id, sized in
  `config/reputation.yml` against a documented attack.
- Private keys are non-extractable WebCrypto keys in IndexedDB. The seed is
  never stored or transmitted.
- The private vault is encrypted under a separate key derived from the same
  seed, so the server holds it without being able to read it.
- Every signature names the kind of record it was made for (`purpose`), so a
  signature for one kind cannot be presented as another.
- **MVP: the client does not verify other people's attestation signatures**
  (`session.verify_signatures`). Until that is on, a malicious server can
  fabricate ratings.
