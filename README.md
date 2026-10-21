# ReputableChat

A chain of signed records, the agnostic server that holds it, and the apps built on it. The server is developed on the `Agnostic-Server-V0` branch, which holds nothing else, so a machine that only wants to run the chain needs only that branch. The apps -- the chat among them -- live on their own branches, in their own directories beside `server/`, and merge it.

Every signed record names the most recent records its author had seen, which makes the history a chain: a record cannot be quietly removed, back-dated, or shown to one person and not another. Records are anchored into it only when somebody acknowledges them, so being unvouched for means being left out -- which is also what a sybil cannot buy its way past.

The server knows the chain and its rules and nothing about any app. It checks every record against [the rules](docs/project/rules/v0.001.md) before acknowledging it, stores records and serves them back unchanged, publishes heartbeats with its own host account, and syncs with other servers. It never sees a user's seed, holds no private key but its own host account's, and never computes a reputation: reputation is subjective, and belongs to the apps and the people using them.

## Layout

- **[`server/`](server/README.md)**: the agnostic server. Everything about running it is in its README.
- **`docs/`**: the rules, the signed examples, and the design of the chain.
- **`shared/`**: files every app on a server reads, such as the BIP39 wordlist.
- **`host/`** (gitignored): the host account the server and its apps share, made on first boot.
- **[`coordination/`](coordination/README.md)**: requests and todos passed between the server and the apps.
- Each app: its own directory, on its own branch.

## Running the server

```bash
cd server
bundle install
bundle exec rake spec      # the suite
bundle exec rake setup     # a fresh server: its handle, its address, the servers it knows
bundle exec puma           # http://localhost:9393; listens once it has caught up
```

Settings are in `server/config/server.yml`, which documents each one.

## Design

[glossary](docs/project/glossary.md) · [chain](docs/project/chain.md) · [server architecture](server/ARCHITECTURE.md) · [rules](docs/project/rules/v0.001.md) · [identity](docs/project/identity.md) · [reputation](docs/project/reputation.md)
