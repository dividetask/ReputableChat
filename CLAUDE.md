# CLAUDE.md — ReputableChat

## Interaction style

- **Never use the `AskUserQuestion` tool / multiple-choice prompt.** When
  clarification is needed, ask in plain prose in the chat.
- **Stop immediately after asking.** End the turn. Do not continue with tool
  calls or implementation until the user has replied.
- Ask often, especially where something is ambiguous or where the user may have
  made a mistake.
- **Never reuse labels within one response.** The user replies by label, so
  every numbered or lettered item in a response must be unique across it. Use
  letters for one list and numbers for another, or continue the numbering
  (questions start after the last numbered point), so "(3)" can only mean one
  thing.

## Do not loop on errors

- If an approach fails twice, stop. Do not retry the same strategy.
- Explain what went wrong, what was tried, and what the alternatives are — the
  user decides how to proceed.
- Analyze an error before taking any further action.

## Layout

This branch is the **agnostic server** alone. Apps live on other branches, in
their own directories beside `server/`, and merge this one; keep that
structure so they can.

- `server/` — the agnostic server: checks records against the rules, stores
  and serves them, heartbeats, and syncs with other servers. It knows no app.
  See [server/README.md](server/README.md). Run commands from inside it.
- `docs/` — the rules, their signed examples, and the design of the chain.
- `shared/` — files every app on a server reads, such as the BIP39 wordlist.
- `host/` (gitignored) — the host account the server and its apps share.

## Environment

- Ruby 3.3.6 via rbenv. `rake` and other gem binaries are at
  `/opt/rbenv/versions/3.3.6/bin`, which is **not** on `PATH` by default — use
  `bundle exec`, or export that directory first.
- Linux, vim.

```bash
# In server/
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

See [docs/project/chain.md](docs/project/chain.md).

**One name per thing:** [docs/project/glossary.md](docs/project/glossary.md) is
the vocabulary, including the terms that have been retired. Check it before
inventing a word for something that already has one.

## Things that break silently

- **Canonical serialization.** `server/lib/agnostic/canonical.rb` refuses any
  payload whose bytes it cannot reproduce exactly, so it must produce the
  bytes every client signs: keys sorted, no whitespace, UTF-8, no floats,
  integers JavaScript can read exactly. If it drifts from the clients', every
  signature stops verifying with no obvious cause.
- **Record hashes.** `server/lib/agnostic/record.rb` must be what the rules
  say: SHA-256 over the payload, a newline and the signature, with nothing in
  front. If it drifts, every `ack` points at a record no one else can find.
- **The genesis record.** `server/config/genesis/<environment>.json` is the
  bottom of the chain. Regenerating one orphans every record that
  acknowledged the old one, which is the whole chain.
  `server/script/generate_genesis.rb` refuses to overwrite it. A production
  server **refuses to boot on the development genesis**, compared by key,
  since the realistic mistake is copying the record into place. The
  development genesis account's phrase is public on purpose
  (`server/spec/fixtures/development-genesis.seed`); every other seed is
  gitignored, 0600, and never printed.
- **The rules and their examples.** `docs/project/rules/v0.001.md` is the rules
  in prose and `docs/project/rules/v0.001-examples.md` is the same rules in
  bytes. Change a rule and the examples go stale in silence: every signature
  still verifies, so nothing looks wrong. `server/spec/examples_spec.rb` runs
  the whole example chain through the server, and
  `server/spec/fixtures/examples_broken.md` holds correctly signed records
  that each break a rule, because a checker that has quietly stopped looking
  passes everything.
- **The rules and the server's checks.** `server/lib/agnostic/rules.rb` and
  `server/lib/agnostic/view.rb` are the only implementation of
  `docs/project/rules/v0.001.md`, and change with the prose: a rule edited in
  prose and not in code means the server accepts records the rules call
  invalid, or refuses valid ones, and every signature still verifies. Where
  the server reads the rules one way out of several, `server/README.md` says
  so under **Reading the rules**.
- **The genesis carries the rules file.** The rules field of
  `server/config/genesis/development.json` is `docs/project/rules/v0.001.md`
  less its trailing newline, and `server/spec/server_spec.rb` fails if they
  differ. That is deliberate: a published rules file is never edited. Before
  launch, the fix is a new development genesis, which orphans every
  development record that acknowledged the old one.
- **The host account's phrases** are generated on first boot into
  `host/<environment>/` at the repository root, outside `server/`, since
  every app on the server shares the account: `host.seed` (working) and
  `host-master.seed` (master, to be moved off the server; never read again),
  both 0600, with the master public key in `host-master.pub`. The declaration
  `host.json` is written only when the server goes live, after catching up.
  The server refuses to boot without the working phrase or when it does not
  match the declaration.
- **The seed derivation.** `server/lib/agnostic/seed.rb` derives keys the way
  a browser client does (Argon2id, domain `reputablechat:seed:v1`), and
  `server/spec/seed_spec.rb` holds it to the development genesis key. Change
  the domain or a parameter and the same phrase is a different account,
  stranding every existing one.

## Code conventions

- Numeric config values are **quoted strings** in YAML, so the parser cannot
  coerce them to binary floats before `BigDecimal` sees them.
- Decimals are `BigDecimal`, never floats, and are written in the one
  spelling the rules give them.
- Config holds numbers and enums only. Formula strings that nothing evaluates
  are worse than comments, because they look live.
- Tests name the **rule** they protect, not the method they call. A failing test
  should say what behaviour broke.
- The server reads as little of a signed blob as it can, and serves blobs back
  byte-identical.

## Vendored files

- `shared/bip39-english.txt` — canonical BIP39 English wordlist, the one copy
  every app reads, sha256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
