# CLAUDE.md — ReputableChat

This file is shared by every branch. Each directory beside it has its own
`CLAUDE.md` for what is its alone: [server/CLAUDE.md](server/CLAUDE.md) for
the agnostic server, and one in each app's directory. Read the one for the
directory you are working in as well as this one.

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

The agnostic server and each app are a directory here, and each is developed
on its own branch: the server on `Agnostic-Server-V0`, which holds only the
server, and each app on a branch that merges it. A directory belongs to the
branch that develops it; change it there, and keep the layout so the merges
keep working.

- `server/` — the agnostic server: checks records against the rules, stores
  and serves them, heartbeats, and syncs with other servers. It knows no app.
  Run its commands from inside it.
- `docs/project/` — the rules (`rules/`), their signed examples, and the
  design of the chain. The server's branch keeps them.
- `shared/` — files every app on a server reads, such as the BIP39 wordlist.
- `host/` (gitignored) — the host account the server and its apps share,
  made on the server's first boot.
- `coordination/` — requests and todos passed between the server and the
  apps. See [coordination/README.md](coordination/README.md).

**One name per thing:** [docs/project/glossary.md](docs/project/glossary.md) is
the vocabulary, including the terms that have been retired. Check it before
inventing a word for something that already has one.

## Environment

- Ruby 3.3.6 via rbenv. `rake` and other gem binaries are at
  `/opt/rbenv/versions/3.3.6/bin`, which is **not** on `PATH` by default — use
  `bundle exec`, or export that directory first.
- Linux, vim.

## Shared by everything

- **The rules.** `docs/project/rules/v0.001.md` is what every record must be,
  and `v0.001-examples.md` the same in bytes. A published rules file is never
  edited: the genesis carries it.
- **`shared/bip39-english.txt`** — canonical BIP39 English wordlist, the one
  copy every app reads, sha256
  `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
- **The host account** in `host/<environment>/` is one account for the
  server and every app beside it. Its seeds are 0600 and never printed or
  committed.
