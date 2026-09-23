# CLAUDE.md — ReputableChat

## Interaction style

- **Never use the `AskUserQuestion` tool / multiple-choice prompt.** When
  clarification is needed, ask in plain prose in the chat.
- **Stop immediately after asking.** End the turn. Do not continue with tool
  calls or implementation until the user has replied.
- Ask often, especially where something is ambiguous or where the user may have
  made a mistake.

## Do not loop on errors

- If an approach fails twice, stop. Do not retry the same strategy.
- Explain what went wrong, what was tried, and what the alternatives are — the
  user decides how to proceed.
- Analyze an error before taking any further action.

## Environment

- Ruby 3.3.6 via rbenv. `rake` and other gem binaries are at
  `/opt/rbenv/versions/3.3.6/bin`, which is **not** on `PATH` by default — use
  `bundle exec`, or export that directory first.
- Linux, vim. Node 22 is available and is used by the parity spec.

```bash
bundle exec rake spec       # full suite (browser tests skip without `npm install`)
npm install                 # once, for the browser tests
bundle exec rake curve      # print current curve, ladder and safety window
bundle exec rake dump       # readable dump of the database
bundle exec rake "dump[messages,reactions]"   # just those sections
bundle exec rake genesis    # development genesis (already committed)
RACK_ENV=production bundle exec rake genesis   # production genesis (once, ever)

# The genesis account from a terminal, against a running server.
bundle exec ruby script/tim.rb status             # uses this environment's seed
bundle exec ruby script/tim.rb post "Planned outage 02:00-03:00 UTC on Friday"
bundle exec ruby script/tim.rb visible <pubkey>   # least rating that makes them visible
bundle exec ruby script/tim.rb friend <pubkey>

bin/vouch --count 3                          # accounts that introduce new bots
bin/bot personas/regular.yml --explain       # what a bot persona implies
bin/bot personas/regular.yml --name ana      # run one
```

See [docs/project/reputation.md](docs/project/reputation.md),
[docs/project/chain.md](docs/project/chain.md) and
[docs/project/bots.md](docs/project/bots.md).

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
- **The bots' half of the protocol.** The bot client signs the same record
  shapes the browser does, so a change to one breaks the swarm at runtime,
  hours in, with nothing failing at build time.
  `spec/bot_integration_spec.rb` drives the real runner against the real app
  in process, and is what turns that into a failing test.
  `spec/bot_identity_spec.rb` does the same for key derivation, running the
  browser's own `deriveFromSeed` under node and comparing.
- **Record hashes.** `cryptography/record.rb` and `public/js/record.js` must agree,
  and so must `reputation/fingerprint.rb` and `public/js/fingerprint.js`. If they
  drift, every `ack` points at a record the other side cannot find and no
  reference resolves. `spec/record_parity_spec.rb` guards both.
- **The genesis record.** `config/genesis/<environment>.json` is the bottom of
  the chain. Regenerating one orphans every record that acknowledged the old
  one, which is the whole chain. `script/generate_genesis.rb` refuses to
  overwrite either it or the seed beside it.
- **Two genesis accounts, and only one is secret.**
  `config/genesis/development.seed` is **committed on purpose** — that identity
  is public, so a fresh clone can sign as the genesis account without being
  handed a secret. `config/genesis/production.seed` is gitignored, 0600, and
  never printed. `.gitignore` ignores every `*.seed` and then un-ignores
  development's, so a new environment's seed is refused by default rather than
  committed by omission.
  A production deployment **refuses to boot on the development genesis**,
  compared by key rather than by filename, because the realistic mistake is
  copying the record into place rather than misnaming it.
  Both hold the seed phrase rather than the derived key, so there is one secret
  to look after rather than two that must not disagree.
- **The vault key.** `public/js/vault.js` derives it from the Argon2id output
  the identity key already comes from, separated by `seed.kdf.vault_domain`
  through HKDF. Changing that domain strands every existing vault; changing how
  the identity key is derived strands every existing account, which is why the
  vault key is layered on top rather than alongside.
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
- `config/bip39-english.txt` — canonical BIP39 English wordlist, sha256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
