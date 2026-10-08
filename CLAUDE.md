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

Two apps, each a self-contained Ruby project with its own Gemfile, Rakefile and
specs; run commands from inside the one you are working on.

- `server/` — the **agnostic server**: checks records against the rules, stores
  and serves them, heartbeats, and exchanges records with peers. It knows no
  app. See [server/README.md](server/README.md).
- `chat/` — the chat app, browser client and its server. **Paths in this file
  are inside `chat/`** unless they start with `server/` or `docs/`.
- `docs/` stays at the root: the rules belong to the chain, not to either app.

## Environment

- Ruby 3.3.6 via rbenv. `rake` and other gem binaries are at
  `/opt/rbenv/versions/3.3.6/bin`, which is **not** on `PATH` by default — use
  `bundle exec`, or export that directory first.
- Linux, vim. Node 22 is available and is used by the parity spec.

```bash
# In server/
bundle exec rake spec       # the agnostic server's suite
bundle exec rake setup      # a fresh server: handle, address, other servers
bundle exec puma            # http://localhost:9292; PEERS=url,url to sync
bundle exec rake peers      # servers it syncs with, failing, or forgotten
bundle exec rake "sweep[<url>]"   # copy the chain from a server
bundle exec rake host       # this server's host account (made on first boot)
bundle exec rake ignored    # peers ignored for a clock over 10 minutes off
bundle exec rake "forgive[<host account id>]"   # stop ignoring one

# In chat/
bundle exec rake spec       # full suite (browser tests skip without `npm install`)
npm install                 # once, for the browser tests
bundle exec rake curve      # print current curve and ladder
bundle exec rake dump       # readable dump of the database
bundle exec rake "dump[messages,emotes]"      # just those sections
bundle exec rake genesis    # development genesis (already committed)
RACK_ENV=production bundle exec rake genesis   # production genesis (once, ever)
bundle exec rake host       # development host account (already committed)
RACK_ENV=production bundle exec rake host      # a server's production host account
# Handle, bio and icon: run the script directly with --handle, --bio, --icon.
bundle exec ruby script/generate_genesis.rb --host --production --handle Ops --icon ops.png

# The genesis account from a terminal, against a running server; --host signs
# as the host account instead.
bundle exec ruby script/tim.rb status             # uses this environment's seed
bundle exec ruby script/tim.rb --host post "Planned outage 02:00-03:00 UTC on Friday"
bundle exec ruby script/tim.rb visible <pubkey>   # least rating that makes them visible
bundle exec ruby script/tim.rb friend <pubkey>
```

See [docs/project/reputation.md](docs/project/reputation.md) and
[docs/project/chain.md](docs/project/chain.md).

**One name per thing:** [docs/project/glossary.md](docs/project/glossary.md) is
the vocabulary, including the terms that have been retired. Check it before
inventing a word for something that already has one.

## Things that break silently

- **Canonical serialization.** `lib/reputable_chat/cryptography/canonical.rb` and
  `public/js/canonical.js` must produce identical bytes. If they drift, every
  signature in the system stops verifying with no obvious cause.
  `spec/canonical_parity_spec.rb` guards this — always run it after touching
  either file.
- **Signed payload shapes.** `cryptography/payload.rb` and the `*Payload` helpers in
  `public/js/identity.js` must stay in lockstep for the same reason.
- **Record hashes.** `cryptography/record.rb` and `public/js/record.js` must
  agree. If they drift, every `ack` points at a record the other side cannot
  find and no reference resolves. `spec/record_parity_spec.rb` guards it.
- **The genesis record.** `config/genesis/<environment>.json` is the bottom of
  the chain. Regenerating one orphans every record that acknowledged the old
  one, which is the whole chain. `script/generate_genesis.rb` refuses to
  overwrite either it or the seed beside it.
- **Two accounts, two environments each, and only development's are public.**
  The genesis account is the developer's; the host account
  (`config/host/`) is a server's own, optional, and must acknowledge the
  genesis. `config/genesis/development.seed` and `config/host/development.seed`
  are **committed on purpose** — those identities are public, so a fresh clone
  can sign as either without being handed a secret. Every other seed is
  gitignored, 0600, and never printed. `.gitignore` ignores every `*.seed` in
  both folders and then un-ignores development's, so a new environment's seed
  is refused by default rather than committed by omission.
  A production deployment **refuses to boot on either development account**,
  compared by key rather than by filename, because the realistic mistake is
  copying the record into place rather than misnaming it. The production
  genesis seed belongs with the developer, never on a server.
  Both hold the seed phrase rather than the derived key, so there is one secret
  to look after rather than two that must not disagree.
- **The vault key.** `public/js/vault.js` derives it from the Argon2id output
  the identity key already comes from, separated by `seed.kdf.vault_domain`
  through HKDF. Changing that domain strands every existing vault; changing how
  the identity key is derived strands every existing account, which is why the
  vault key is layered on top rather than alongside.
- **The vault itself, in two languages.** `public/js/vault.js` and
  `cryptography/vault.rb` both seal and open vaults -- the browser for everyone,
  Ruby for the genesis account driven from a terminal. A drift between them
  fails in the worst way available: each half opens its own vaults perfectly and
  cannot read the other's, so a friend list appears to vanish and come back
  depending on which one wrote last. `spec/vault_parity_spec.rb` seals in each
  and opens in the other, which is the only arrangement that can catch it.
- **Published score text.** `reputation/decimals.rb` and `toDecimal` in
  `public/js/reputation.js` must spell the same number the same way, not merely
  parse each other's. `spec/decimal_parity_spec.rb` guards it.
- **The login origin.** The browser signs `window.location.origin` into every
  login. With no `origin` configured -- the default -- the server compares it
  with the address the request arrived at (`lib/reputable_chat/origin.rb`), so
  a reverse proxy that drops `Host` or `X-Forwarded-Proto` fails every login.
  The error names both addresses; keep it that way, since "signature did not
  verify" alone sends people looking at their seed.
- **The rules and their examples.** `docs/project/rules/v0.001.md` is the rules
  in prose and `docs/project/rules/v0.001-examples.md` is the same rules in
  bytes. Change a rule and the examples go stale in silence: every signature
  still verifies, so nothing looks wrong. `spec/examples_spec.rb` drives
  `spec/examples.mjs`, which re-derives each key from the formula the file
  states, verifies every record, and checks each against the rules it is an
  example of. `spec/fixtures/examples_broken.md` holds three correctly signed
  records that each break a rule, because a checker that has quietly stopped
  looking passes everything.
- **The rules and the server's checks.** `server/lib/agnostic/rules.rb` and
  `server/lib/agnostic/view.rb` enforce `docs/project/rules/v0.001.md`, and
  change with it: a rule edited in prose and not in code means the server
  accepts records the rules call invalid, or refuses valid ones, and every
  signature still verifies. `server/spec/examples_spec.rb` runs the whole
  example chain and the broken fixture through the server, so changing a rule
  and its examples without the code fails there. Where the server reads the
  rules one way out of several, `server/README.md` says so under **Reading
  the rules**.
- **The server's genesis carries the rules file.** The rules field of
  `server/config/genesis/development.json` is `docs/project/rules/v0.001.md`
  less its trailing newline, and `server/spec/server_spec.rb` fails if they
  differ. That is deliberate: a published rules file is never edited. Before
  launch, the fix is a new development genesis, which orphans every
  development record that acknowledged the old one.
- **The server's host account phrases** are generated on first boot into
  `server/data/<environment>/`: `host.seed` (working) and `host-master.seed`
  (master, to be moved off the server; never read again), both 0600, beside
  the declaration `host.json`. The server refuses to boot without the working
  phrase or when it does not match the declaration. `server/lib/agnostic/seed.rb`
  derives keys the browser's way, and `server/spec/seed_spec.rb` holds its KDF
  parameters equal to `seed.kdf` in `config/reputation.yml` -- change one
  without the other and the same phrase is two different accounts.
- **One home per rule.** A rule written in two places gets edited in one of
  them, and the two copies then disagree about which records are valid. That
  happened three times in one afternoon of editing, each time as a paraphrase
  rather than a copy, which is why none of them read as duplication.
  `spec/rules_text_spec.rb` holds the table of where each rule lives and fails
  when one is stated outside its section. Before editing a rule, grep for its
  distinctive words; when adding one, add it to that table.
- **The seed derivation domain.** Changing `seed.kdf.domain` in
  `config/reputation.yml` changes every derived key, which strands every
  existing account. It is versioned (`:v1`) so a future change can be handled
  deliberately rather than by accident.

## Code conventions

- Numeric config values are **quoted strings** in YAML, so the parser cannot
  coerce them to binary floats before `BigDecimal` sees them.
- Reputation arithmetic is decimal (`BigDecimal` in Ruby, BigInt fixed-point in
  JS). Never floats — the Blocked line is `effective > 0`, and float drift
  flips people across it.
- Config holds numbers and enums only. Formula strings that nothing evaluates
  are worse than comments, because they look live.
- Tests name the **rule** they protect, not the method they call. A failing test
  should say what behaviour broke.
- Reputation records carry **ratings**, not the actions behind them. `friend`,
  `reported` and `net_votes` live in the author's vault; the curve runs once,
  where it is authored. Nothing published says what parameters it was computed
  under -- a reader reaching for a derived cache either takes the number or
  leaves it, and publishing the parameters would tell everyone the settings a
  particular reader scores under.
- The server reads as little of a signed blob as it can, and serves blobs back
  byte-identical.
- Render user text with `textContent`, never `innerHTML`.

## Testing the interface

Most of the interface is asserted against `public/js/app.js` **as source**
(`spec/ui_rules_spec.rb`). That catches a rule being deleted and cannot catch a
rule being broken: it will happily confirm that `avatarFor` is called while the
argument passed to it makes the picture disappear, which is a bug that shipped.

`spec/browser_spec.rb` is the answer to that. It starts a server on a free port
with its own database and image root, drives the real page in Chromium through
`playwright-core`, and asserts on what is actually rendered. It skips rather
than fails when `node_modules` is absent, because a clone should not need
`npm install` to run `rake spec`.

`playwright-core` rather than `playwright`: it is a single package with no
dependency tree, and it uses the Chromium already on the machine instead of
downloading one. The application itself still ships no JavaScript dependencies.

## Vendored files

- `public/js/vendor-argon2.umd.min.js` — hash-wasm 4.12.0, `dist/argon2.umd.min.js`,
  from the npm registry. sha256
  `dcec617a2e1b700fa132d1583a186cb70611113395e869f2dd6cc82b415d3094`.
- `config/bip39-english.txt` and `server/config/bip39-english.txt` — canonical
  BIP39 English wordlist, the same file in both apps, sha256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
