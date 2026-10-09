# The genesis and its development phrases in `shared/`

From the chat, moved here from `chat/docs/agnostic-server-requests.md`.

**Why.** Every app and the agnostic server should read the same genesis and
the same development genesis account. Today there are two copies of each:

- the record: `server/config/genesis/development.json` and
  `chat/config/genesis/development.json`;
- the working phrase: `server/spec/fixtures/development-genesis.seed` and
  `chat/config/genesis/development.seed`;
- the master phrase: only in the chat, `chat/config/genesis/development.master.seed`,
  although the server's genesis declares the `mpubkey` it derives.

Two copies of a genesis are two chains the moment they differ.

**What to change.**

- `shared/genesis/<environment>.json`: the genesis record in the server's
  format (`payload`, `signature`, `hash`). The server reads it from there and
  `server/config/genesis/` goes. `GENESIS` can still point elsewhere.
- `shared/genesis/development.seed` and `development.master.seed`: the
  development genesis account's working and master phrases, public on purpose.
  The server's specs read them there, and the fixture goes.
- `shared/genesis/development.webp`: the genesis avatar the development
  genesis names (`file`). It is in the chat today, which serves it, since a
  new account shows it before fetching anything.
- `.gitignore`: un-ignore exactly those two development phrases. Every other
  seed stays ignored, and production's phrases never enter the repository.
- `generate_genesis.rb` writes there and still refuses to overwrite.

This lifts the earlier hold on moving the genesis. The genesis itself does not
change, only where it is kept.

**How the chat will follow.** Once this lands, the chat reads the record,
phrases and avatar from `shared/genesis/` and deletes its own copies.
`chat/spec/compatibility_spec.rb` then has nothing left to compare and goes
too.
