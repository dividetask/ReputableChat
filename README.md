# ReputableChat

Decentralized chat where the reputation system *is* the moderation. Every user
is a keypair. People vouch for each other by friending and reacting positively
to comments, and report bad actors. Those judgements propagate through the
social graph, weighted by distance, and decide what each person sees — so "who
is worth reading" is answered per viewer rather than globally.

Every signed record names the last record its author had seen, and only records
from people that author rates are worth naming — so the history is a chain the
reputable part of the network builds for itself, and being unvouched for means
being left out of it.

**Status: early.** 

## Running it

```bash
bundle install
bundle exec rake spec      # test suite
bundle exec puma           # http://localhost:9292
```

`bundle exec rake curve` prints the curve, ladder weights and safety window.

### Deploying

Server settings live in `config/server.yml`:

```yaml
origin: "https://chat.example"
database_url: "sqlite://data/reputablechat.db"
image_root: "data/images"
```

`origin` is the public URL the server is reached at. It travels inside the
signed login payload, so if it does not match the origin the browser signs,
every login is rejected as a bad signature.

Each key can be overridden by the matching environment variable (`ORIGIN`,
`DATABASE_URL`, `IMAGE_ROOT`) for deployments that inject configuration rather
than edit files.

`SESSION_SECRET` is environment-only, since `config/server.yml` is in the
repository. Without it a random secret is generated at boot — fine locally, but
it signs everyone out on every restart.

## How reputation works

Your own rating of someone is worth 0.9 of their score. The rest of the network
is worth 0.1, split by distance: the people you rated contribute 0.09 between
them, the people *they* rated 0.009, out to seven hops. **These rules are the 
default rules and each user can adjust this behavior in their config file.**

Everyone is sorted into a bucket at login, and the scores are then discarded:

| bucket | score | shown as |
|---|---|---|
| Trusted | ≥ 0.01 | normal |
| Tolerated | > 0 | greyed, marked untrusted |
| Blocked | ≤ 0 | not shown |

Hop 2 tops out at 0.009, so **Trusted means you rated them or someone you rated
did**. The unrated sit at exactly 0, so **new accounts start invisible** — that
is the sybil defense. Set `show_unrated` to see them anyway. **Exact values
subject to change**.

## The chain

No proof of work and no mining. The chain exists so a record cannot be quietly
removed, back-dated, or shown to one person and not another: dropping a message
means dropping everything that acknowledged it, and everything that
acknowledged those.

A record is acknowledged only if its author clears the acknowledger's own
reputation bar, which is subjective. New and low-reputation accounts 
therefore go unacknowledged and unanchored — that is the point of it, not a 
gap in it.

Tim's user record is the genesis. Generate it once with `bundle exec rake
genesis` and commit it; every client needs the same hash before it has fetched
anything, so it cannot be downloaded. Later version's will allow each server
to change the default friend's name from Tim to another name.

Full design: [reputation](docs/project/reputation.md) ·
[identity](docs/project/identity.md) ·
[chain](docs/project/chain.md) ·
[architecture](docs/project/architecture.md)

## Security

- Seeds are 8+ BIP39 words stretched through Argon2id.
- Private keys are non-extractable WebCrypto keys in IndexedDB. The seed is
  never stored or transmitted.
- Signatures are bound to purpose, origin and room, so they cannot be replayed.
- **MVP: the client does not verify config signatures** (`verify_signatures:
  false`). Until that is on, a malicious server can fabricate ratings.
