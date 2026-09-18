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
bundle exec rake spec     # full suite
bundle exec rake curve    # print current curve, ladder and safety window
bundle exec rake genesis  # generate the genesis user record (once, ever)
```

See [docs/project/reputation.md](docs/project/reputation.md) and
[docs/project/chain.md](docs/project/chain.md).

## Things that break silently

- **Canonical serialization.** `lib/reputable_chat/cryptography/canonical.rb` and
  `public/js/canonical.js` must produce identical bytes. If they drift, every
  signature in the system stops verifying with no obvious cause.
  `spec/canonical_parity_spec.rb` guards this — always run it after touching
  either file.
- **Signed payload shapes.** `cryptography/payload.rb` and the `*Payload` helpers in
  `public/js/identity.js` must stay in lockstep for the same reason.
- **Record hashes.** `cryptography/record.rb` and `public/js/record.js` must agree,
  and so must `reputation/fingerprint.rb` and `public/js/fingerprint.js`. If they
  drift, every `ack` points at a record the other side cannot find and no
  reference resolves. `spec/record_parity_spec.rb` guards both.
- **The genesis record.** `config/genesis/tom.json` is the bottom of the chain.
  Regenerating it orphans every record that acknowledged the old one, which is
  the whole chain. `script/generate_genesis.rb` refuses to overwrite it.
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

## Vendored files

- `public/js/vendor-argon2.umd.min.js` — hash-wasm 4.12.0, `dist/argon2.umd.min.js`,
  from the npm registry. sha256
  `dcec617a2e1b700fa132d1583a186cb70611113395e869f2dd6cc82b415d3094`.
- `config/bip39-english.txt` — canonical BIP39 English wordlist, sha256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
