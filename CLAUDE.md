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
bundle exec rake spec       # full suite
bundle exec rake curve      # print current curve, ladder and safety window
bundle exec rake dump       # readable dump of the database
bundle exec rake "dump[messages,reactions]"   # just those sections
bundle exec rake genesis    # generate the genesis user record (once, ever)

# The genesis account from a terminal, against a running server.
bundle exec ruby script/tim.rb status
bundle exec ruby script/tim.rb post "Planned outage 02:00-03:00 UTC on Friday"
bundle exec ruby script/tim.rb visible <pubkey>   # least rating that makes them visible
bundle exec ruby script/tim.rb friend <pubkey>
```

See [docs/project/reputation.md](docs/project/reputation.md) and
[docs/project/chain.md](docs/project/chain.md).

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
- `config/bip39-english.txt` — canonical BIP39 English wordlist, sha256
