# CLAUDE.md — the chat

The root `CLAUDE.md` applies here too: how to talk to the user, the agnostic
server, the rules. This file is the chat's. **Paths in it are inside `chat/`**
unless they start with `../`.

`chat/` is this branch's. `server/`, `shared/`, `docs/project/rules/` and
the root files come from the agnostic server's branch,
`Agnostic-Server-V0`, which this one merges from time to time. Change those
there, not here, and keep the chat compatible with them. Exceptions, kept on
this branch: `docs/project/apps/`, and the chat's lines in the root
`.gitignore`. **Merging that branch:** `git merge --no-commit`, then put back
anything of ours it would delete (`git checkout HEAD -- chat docs/project/apps`)
before committing.

## Commands

The chat runs beside an agnostic server at `chain_url`
(http://localhost:9393), and waits for it to be live before it opens its port.

```bash
# In chat/, beside an agnostic server at chain_url (http://localhost:9393):
#   cd server && bundle exec puma
bundle exec rake spec       # full suite; starts its own agnostic server
                            # (browser tests skip without `npm install`)
npm install                 # once, for the browser tests
bundle exec rake curve      # print current curve and ladder
bundle exec rake dump       # readable dump of the database
bundle exec rake "dump[messages,reactions]"   # just those sections
bundle exec rake genesis    # development genesis (already committed)
RACK_ENV=production bundle exec rake genesis   # production genesis (once, ever)
# Handle, bio and icon: run the script directly with --handle, --bio, --icon.
bundle exec ruby script/generate_genesis.rb --host --production --handle Ops --icon ops.png

# The genesis account from a terminal, against a running server; --host signs
# as the host account instead.
bundle exec ruby script/tim.rb status             # uses this environment's seed
bundle exec ruby script/tim.rb --host post "Planned outage 02:00-03:00 UTC on Friday"
bundle exec ruby script/tim.rb visible <account>  # least rating that makes them visible
bundle exec ruby script/tim.rb friend <account>   # by account ID
```

See [ARCHITECTURE.md](ARCHITECTURE.md), [../docs/project/reputation.md](../docs/project/reputation.md)
and [../docs/project/chain.md](../docs/project/chain.md).

## Things that break silently

- **Canonical serialization.** `lib/reputable_chat/cryptography/canonical.rb` and
  `public/js/canonical.js` must produce identical bytes. If they drift, every
  signature in the system stops verifying with no obvious cause.
  `spec/canonical_parity_spec.rb` guards this — always run it after touching
  either file.
- **Signed payload shapes.** `cryptography/payload.rb` and the `*Payload` helpers in
  `public/js/identity.js` must stay in lockstep for the same reason.
- **Record hashes.** `cryptography/record.rb` and `public/js/record.js` must
  agree, and both must be what the rules say: SHA-256 over the payload, a
  newline and the signature, with nothing in front. If they drift, every `ack` points at a record the other side cannot
  find and no reference resolves. `spec/record_parity_spec.rb` guards it.
- **The genesis record.** `config/genesis/<environment>.json` is the bottom of
  the chain. Regenerating one orphans every record that acknowledged the old
  one, which is the whole chain. `script/generate_genesis.rb` refuses to
  overwrite either it or the seed beside it.
- **Two accounts.** The genesis account is the developer's.
  `config/genesis/development.seed` and the `.master.seed` beside it are
  **committed on purpose** — that identity is public, so a fresh clone can
  sign as it without being handed a secret. It has a working key and a master
  key, from two separate seed phrases. Every other seed is gitignored, 0600,
  and never printed. `.gitignore` ignores every `*.seed` and then un-ignores
  development's, so a new environment's seed is refused by default rather than
  committed by omission.
  The host account is a server's own, and **every chat server has one: its
  agnostic server's.** The chat reads that server's working seed (`host_seed`,
  `HOST_SEED`, by default `../host/<env>/host.seed`) and refuses to
  boot if it is not the account the agnostic server names. One account per
  server, whatever apps it runs. The chat announces itself with it: a notice
  of kind `service` typed `:chat` carrying `url`, on the first boot with an
  address and whenever the address changes (`chain/service.rb`); other chat
  servers fetch files from it (`file_peers.rb`; `spec/file_sharing_spec.rb`
  runs two chat servers, each beside its own agnostic server).
  A production deployment **refuses to boot on the development genesis**,
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
  example of. `spec/fixtures/examples_broken.md` (and the agnostic server's copy) holds three correctly signed
  records that each break a rule, because a checker that has quietly stopped
  looking passes everything. `server/spec/examples_spec.rb` runs both files
  through the agnostic server, which is what decides what is accepted.
- **The genesis carries the rules file.** The development genesis's `rules`
  field is `docs/project/rules/v0.001.md`, stripped of surrounding whitespace.
  Edit that file and `spec/chain_spec.rb` fails until the genesis is
  regenerated, which orphans everything that acknowledged it.
- **One chain, two copies of its genesis.** `config/genesis/development.json`
  must be the same record as `../server/config/genesis/development.json`, and
  `config/genesis/development.seed` the same phrase as the agnostic server's
  `../server/spec/fixtures/development-genesis.seed`: two genesis records are
  two chains, and the chat would refuse to boot against its own agnostic
  server. `spec/compatibility_spec.rb` fails when they differ. The agnostic
  server's copies are the other branch's; when they change, regenerate this
  one to match.
- **The host account** is the agnostic server's, made on its first boot into
  `../host/<environment>/`. The chat reads the working phrase, `host.seed`,
  and nothing else there.
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
- **The seed derivation, in three places.** `seed.kdf` in
  `config/reputation.yml`, `public/js/identity.js` and the agnostic server's
  `../server/lib/agnostic/seed.rb` must derive the same key from the same
  phrase, or one phrase is a different account in each.
  `spec/compatibility_spec.rb` derives the server's development phrase in the
  chat and expects the key the server's genesis declares.

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
- The BIP39 wordlist is the root's `shared/bip39-english.txt`.
