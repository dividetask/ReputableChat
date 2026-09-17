# ReputableChat

A decentralized chat application whose moderation is the reputation system
rather than a moderator. Every user is a keypair. People vouch for each other by
friending and by reacting positively to comments, and report bad actors. Those
judgements propagate through the social graph, weighted by distance, and decide
what each person sees — so "who is worth reading" is answered per viewer rather
than globally.

**Status: early.** The reputation engine, identity and crypto layers are built
and tested. The chat UI is a working skeleton.

## Running it

```bash
bundle install
bundle exec rake spec      # 57 tests
bundle exec puma           # http://localhost:9292
```

Set `ORIGIN` to the externally visible origin — it is covered by login
signatures, so a mismatch rejects every login.

```bash
ORIGIN=https://chat.example bundle exec puma
```

`bundle exec rake curve` prints the current curve, ladder weights and safety
window.

## How reputation works

Your own rating of someone is worth 0.9 of their score. The entire rest of the
network is worth the remaining 0.1, split by distance: the people you rated
contribute 0.09 between them, the people *they* rated 0.009, and so on out to
seven hops.

Everyone lands in one of three buckets at login:

| bucket | score | shown as |
|---|---|---|
| Trusted | ≥ 0.01 | normal |
| Tolerated | > 0 | greyed, marked untrusted |
| Blocked | ≤ 0 | not shown at all |

Two consequences worth knowing. Depth 2 tops out at 0.009, so **Trusted means
you rated them or someone you rated did** — nobody further out reaches it.
And the unrated sit at exactly 0, so **new accounts start invisible**: that is
the sybil defense, since keys are free to generate but worth nothing until
somebody vouches. Users who want to see the unrated can set `show_unrated`.

Full design:
[reputation](docs/project/reputation.md) ·
[identity](docs/project/identity.md) ·
[architecture](docs/project/architecture.md)

## Before you retune anything

`config/reputation.yml` is meant to be tuned, with one catch. The rule *"a
report from three hops away blocks someone you liked once, but two likes
outweigh it"* ties the vote curve to the ladder decay:

```
curve(1) < k³ < curve(2)      i.e.   A < k³ < 4A
```

So `k`, `max_hops`, `A`, `B` and `cap` are **not** independent — changing one
can silently flip a distant report from blocking someone to not.
`spec/reputation_rules_spec.rb` asserts the rule and fails if a retune breaks
it. If that test goes red after a config change, reconsider the config change.

## Security notes

- Seeds are 8+ BIP39 words (80 bits of entropy) stretched through Argon2id.
- Private keys are non-extractable WebCrypto keys in IndexedDB. The seed is
  never stored and never transmitted.
- Login and message signatures are bound to purpose, origin and room, so they
  cannot be replayed elsewhere.
- **The MVP client does not verify config signatures** (`verify_signatures:
  false`). Until that is flipped on, a malicious server can fabricate ratings.
  The verification path exists; it is one config key.
