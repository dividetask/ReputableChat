# ReputableChat

Decentralized chat where the reputation system *is* the moderation. Every user
is a keypair. People vouch for each other by friending and reacting positively
to comments, and report bad actors. Those judgements propagate through the
social graph, weighted by distance, and decide what each person sees — so "who
is worth reading" is answered per viewer rather than globally.

**Status: early.** Reputation, identity and crypto are built and tested. The
chat UI is a working skeleton.

## Running it

```bash
bundle install
bundle exec rake spec      # test suite
bundle exec rake curve     # print the curve, ladder and safety window
ORIGIN=https://chat.example bundle exec puma
```

`ORIGIN` is covered by login signatures — a mismatch rejects every login.

## How reputation works

Your own rating of someone is worth 0.9 of their score. The rest of the network
is worth 0.1, split by distance: the people you rated contribute 0.09 between
them, the people *they* rated 0.009, out to seven hops.

Everyone is sorted into a bucket at login, and the scores are then discarded:

| bucket | score | shown as |
|---|---|---|
| Trusted | ≥ 0.01 | normal |
| Tolerated | > 0 | greyed, marked untrusted |
| Blocked | ≤ 0 | not shown |

Hop 2 tops out at 0.009, so **Trusted means you rated them or someone you rated
did**. The unrated sit at exactly 0, so **new accounts start invisible** — that
is the sybil defense. Set `show_unrated` to see them anyway.

Full design: [reputation](docs/project/reputation.md) ·
[identity](docs/project/identity.md) ·
[architecture](docs/project/architecture.md)

## Security

- Seeds are 8+ BIP39 words stretched through Argon2id.
- Private keys are non-extractable WebCrypto keys in IndexedDB. The seed is
  never stored or transmitted.
- Signatures are bound to purpose, origin and room, so they cannot be replayed.
- **MVP: the client does not verify config signatures** (`verify_signatures:
  false`). Until that is on, a malicious server can fabricate ratings.
