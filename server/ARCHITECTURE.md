# Architecture

The **agnostic server** knows records and the rules and nothing about the apps built on them. It checks every record against the rules before acknowledging it, stores and serves records, publishes heartbeats with its host account, and syncs with other servers at each heartbeat. How it does each of those is in [README.md](README.md).

Apps run beside it, one instance of each per server, and use it for the chain: an app is a client of its agnostic server. It never judges a record against the rules, holds its own users to its own terms, and passes their records on. Apps live on other branches, in their own directories beside `server/`, and merge the agnostic server's branch, `Agnostic-Server-V0`.

## The server does as little as possible

It never sees a user's seed and never computes a reputation. The one private key it holds is its own host account's: it makes the account's phrases on first boot and keeps the working one on the machine, 0600, because a heartbeat has to be signed by somebody and nobody sits at a browser for it. The master phrase is written beside it once, for the operator to move off the machine. The working key signs the server's own records -- heartbeats, its declaration, and its ratings of other servers' reachability -- and never anybody else's.

Signed records go out exactly as they came in. Re-serializing them would only create a way to break signatures, so the server parses the bytes it was given, serializes the result, and refuses the record unless the two are identical.

## Records

Every record on the chain is defined in [rules/v0.001.md](../docs/project/rules/v0.001.md), with signed examples in [rules/v0.001-examples.md](../docs/project/rules/v0.001-examples.md); why the chain is built the way it is lives in [chain.md](../docs/project/chain.md). `lib/agnostic/rules.rb` and `view.rb` are the only implementation of the rules.

## Layout

```
docs/project/rules/       the rules, one file per version, and signed examples
shared/                   files every app on a server reads: the BIP39 wordlist
host/                     (gitignored) the host account the server and its apps share
coordination/             requests and todos passed between the server and the apps

server/                   the agnostic server -- see server/README.md
  config/server.yml       heartbeat interval, peers, ratings, limits (env overrides)
  config/genesis/<env>.json the genesis in the rules' own format, carrying the rules file
  lib/agnostic/
    rules.rb              the rules, enforced: what a record may hold, and what its history must
    view.rb               the chain as one record sees it: keys, disputes, adjudicators, currency
    canonical.rb, record.rb, keys.rb, formats.rb   the kinds of value section 1 defines
    store.rb              records, their acks and indexes, generations, held records, peers
    ingest.rb             the one way in: accept, hold for missing ancestors, or refuse
    host_account.rb       this server's account: phrases on first boot, declared on going live
    seed.rb               seed phrases, derived the way a browser client derives them
    heartbeat.rb          heartbeats acknowledging the frontier
    peers.rb              syncing, catching up, learning servers, finding chain splits
    server_ratings.rb     ratings of other servers by reachability, or by hand
    upload_auth.rb        signed uploads: who may add records
    app.rb                the API
  script/generate_genesis.rb  signs a genesis in the rules' format
```
