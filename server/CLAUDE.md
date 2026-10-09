# CLAUDE.md — the agnostic server

The root `CLAUDE.md` applies here too: how to talk to the user, the layout,
`shared/`, `host/`, the rules and `coordination/`. This file is the agnostic
server's. **Paths in it are inside `server/`** unless they start with `../`.

`server/`, `shared/`, `docs/project/` and the root files are the
`Agnostic-Server-V0` branch's; apps merge them from there. The server knows
no app: nothing here may depend on an app's code or name one.

## Commands

```bash
bundle exec rake spec       # the suite
bundle exec rake setup      # a fresh server: handle, address, other servers
bundle exec puma            # http://localhost:9393; listens once caught up; PEERS=url,url
bundle exec rake peers      # servers it syncs with, failing, or forgotten
bundle exec rake "sweep[<url>,<url>]"   # copy the chain from servers at once
bundle exec rake status     # stopped for a chain split? which server is on which side
bundle exec rake "choose[<url>]"  # follow that server's side and go live
bundle exec rake "forget[<url>]"  # stop syncing with a server
bundle exec rake host       # this server's host account
bundle exec rake "rate[<account>,<reputation>,<trust>]"   # a rating by hand
bundle exec rake "unrate[<account>]"                      # back to reachability
bundle exec rake ratings                                  # what it rates whom
bundle exec rake ignored    # servers ignored: a clock over 10 minutes off, or rated -1
bundle exec rake "forgive[<host account id>]"   # stop ignoring one
```

See [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md) and
[../docs/project/chain.md](../docs/project/chain.md).

## What the apps depend on

Apps run their specs against this server, so a change to any of these is one
they must follow. Note it in the commit message, under `COMPATIBILITY:`, and
in a request to each app in `../coordination/requests/<app>/`:

- the development genesis record, its phrases, and the key they derive;
- `GET /api/host`, `/api/genesis`, `/api/records`, `/api/states`,
  `/api/accounts`, `/api/keys/<pubkey>` and `/api/ratings`;
  `POST /api/records` and `/api/contacts`; the signed-upload headers;
- not listening, or answering 503, until the server is live.

## Things that break silently

- **Canonical serialization.** `lib/agnostic/canonical.rb` refuses any
  payload whose bytes it cannot reproduce exactly, so it must produce the
  bytes every client signs: keys sorted, no whitespace, UTF-8, no floats,
  integers JavaScript can read exactly. If it drifts from the clients', every
  signature stops verifying with no obvious cause.
- **Record hashes.** `lib/agnostic/record.rb` must be what the rules say:
  SHA-256 over the payload, a newline and the signature, with nothing in
  front. If it drifts, every `ack` points at a record no one else can find.
- **The genesis record.** `config/genesis/<environment>.json` is the bottom
  of the chain. Regenerating one orphans every record that acknowledged the
  old one, which is the whole chain. `script/generate_genesis.rb` refuses to
  overwrite it. A production server **refuses to boot on the development
  genesis**, compared by key, since the realistic mistake is copying the
  record into place. The development genesis account's phrase is public on
  purpose (`spec/fixtures/development-genesis.seed`); every other seed is
  gitignored, 0600, and never printed.
- **The rules and their examples.** `../docs/project/rules/v0.001.md` is the
  rules in prose and `../docs/project/rules/v0.001-examples.md` is the same
  rules in bytes. Change a rule and the examples go stale in silence: every
  signature still verifies, so nothing looks wrong. `spec/examples_spec.rb`
  runs the whole example chain through the server, and
  `spec/fixtures/examples_broken.md` holds correctly signed records that each
  break a rule, because a checker that has quietly stopped looking passes
  everything.
- **The rules and the server's checks.** `lib/agnostic/rules.rb` and
  `lib/agnostic/view.rb` are the only implementation of the rules, and change
  with the prose: a rule edited in prose and not in code means the server
  accepts records the rules call invalid, or refuses valid ones, and every
  signature still verifies. Where the server reads the rules one way out of
  several, `README.md` says so under **Reading the rules**.
- **The genesis carries the rules file.** The rules field of
  `config/genesis/development.json` is `../docs/project/rules/v0.001.md` less
  its trailing newline, and `spec/server_spec.rb` fails if they differ. That
  is deliberate: a published rules file is never edited. Before launch, the
  fix is a new development genesis, which orphans every development record
  that acknowledged the old one.
- **The host account's phrases** are generated on first boot into
  `../host/<environment>/`, outside `server/`, since every app on the server
  shares the account: `host.seed` (working) and `host-master.seed` (master,
  to be moved off the server; never read again), both 0600, with the master
  public key in `host-master.pub`. The declaration `host.json` is written
  only when the server goes live, after catching up. The server refuses to
  boot without the working phrase or when it does not match the declaration.
- **The seed derivation.** `lib/agnostic/seed.rb` derives keys the way a
  browser client does (Argon2id, domain `reputablechat:seed:v1`), and
  `spec/seed_spec.rb` holds it to the development genesis key. Change the
  domain or a parameter and the same phrase is a different account,
  stranding every existing one.
- **Signed uploads.** `lib/agnostic/upload_auth.rb` defines the bytes an
  uploader signs (`reputablechat:upload:v1`, method, path, ts, body hash).
  Every app that uploads signs the same bytes; change them and every upload
  is refused.

## Code conventions

- Numeric config values are **quoted strings** in YAML, so the parser cannot
  coerce them to binary floats before `BigDecimal` sees them.
- Decimals are `BigDecimal`, never floats, and are written in the one
  spelling the rules give them.
- Config holds numbers and enums only. Formula strings that nothing evaluates
  are worse than comments, because they look live.
- Tests name the **rule** they protect, not the method they call. A failing
  test should say what behaviour broke.
- The server reads as little of a signed blob as it can, and serves blobs
  back byte-identical.
