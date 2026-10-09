# What the chat needs from the agnostic server

Changes the chat is waiting on in `server/`, which is the `Agnostic-Server-V0`
branch's. Each says what to add and how the chat will use it. Remove an entry
once it has landed and the chat has caught up with it.

## 1. Rating adjustments from apps

**Why.** An app learns things about other servers that the agnostic server
cannot see. The chat, for one, learns whether another chat server answers
and whether it has the files it is asked for. Each app should move the
rating of the accounts it deals with by its own judgement, computed and
configured in the app; the agnostic server should only add the moves up. The
agnostic server's reachability measures the other agnostic server, not that
server's apps, so the two are separate facts and both count.

**What to add.**

- `POST /api/adjustments`, taken only on the local listener (item 2), so
  only an app beside this server can make one.
  Body: `{"app": "chat", "account": "<account ID>", "reputation": "0.004",
  "trust": "0"}`.
  - `app` names the app, as the further part of its record types does
    (`:chat`).
  - `reputation` and `trust` are decimals from -1 to 1, spelled as the rules
    spell one. An app may move both.
  - One adjustment per app and account; a new one replaces the old.
    `"0"` and `"0"` clears it. Adjustments do not expire.
- What the server rates an account:
  - an operator's rating by hand (`rake rate`) when there is one, which
    overrides everything, adjustments included;
  - otherwise its own reachability rating plus every app's adjustment,
    reputation and trust each summed and clamped to -1..1. With no
    reachability rating the server's own part is 0.
- `GET /api/ratings` gives, for each account, the rating it publishes and
  where it came from: `"reachability"` (the server's own rating, if any),
  `"adjustments"` (by app) and `"operator"` (if set). An app reads its own
  adjustment back from there and the server's own rating beside it.
- `rake ratings` shows the same.
- Publishing stays as it is: an attestation of the host account carrying
  only the ratings that changed.

**How the chat will use it.** Over the last 30 days of its attempts to fetch
files from a server, a reached fetch scores 1, a missing file
`1 - missing_penalty` and no answer 0. Its adjustment is
`step * (2 * average - 1)`, `step` being a chat setting, `"0.01"` by default:
+0.01 for a server that always has what it is asked for, -0.01 for one that
never answers, nothing with no attempts. Trust it leaves at 0 for now. It
sends the adjustment rounded to three decimals, and only when it changes.

Then `POST /api/contacts` has nothing left to do for the chat, which stops
sending contact reports: what it learns goes into its adjustment instead,
and counting it in both would count it twice.

## 2. A local listener for the apps beside the server

**Why.** Signed uploads are meant to make outside servers prove who they are,
not the apps on the same machine. Telling the two apart by address is unsafe:
behind a reverse proxy on the same machine every outside request arrives
from 127.0.0.1, and an operator who forgets to list the proxy in
`trusted_proxies` lets outsiders upload unsigned without anything visibly
breaking.

**What to add.**

- A second listener that only local apps can reach, and on which uploads need
  no signature: a Unix socket under `host/<environment>/` (0600 or 0660, so
  only the server's user or group can connect), or a port bound to 127.0.0.1
  alone. Configured in `config/server.yml` (say `local.bind`), on by default
  in development.
- The server knows which listener a request came in on from the socket
  itself, never from anything the request says: `Host`, `X-Forwarded-*` and
  Rack's `SERVER_PORT` (taken from `Host`) are all the client's to choose.
- On the local listener, `POST /api/records` needs no upload headers, and
  records are judged against the rules exactly as on the public one.
  `POST /api/contacts` and `POST /api/adjustments` (item 1) are taken only
  there, with no signature at all. The public listener refuses both.
- Everything else is the same on both. The public listener still requires
  signed uploads, and a reverse proxy forwards only to it, so it cannot open
  the local one by accident.

**How the chat will use it.** `chain_url` points at the local listener; the
chat stops signing uploads and contact reports, and `Host#upload_headers`
goes. Until then it signs every upload as the host account, which works
because only something that can read `host/<environment>/host.seed` can.

## 3. A `CLAUDE.md` per app

**Why.** Both branches edit the root `CLAUDE.md`, so they conflict at every
merge.

**What to change.** Move the agnostic server's instructions into
`server/CLAUDE.md`. Claude Code reads a directory's `CLAUDE.md` when working
in it. The root keeps only what every branch shares: how to talk to the user,
the layout, `shared/`, `host/` and `docs/project/rules/`. The chat's
instructions are already in `chat/CLAUDE.md`. Avoid wording such as "this
branch is the agnostic server alone", which is true there and wrong once the
file is merged into an app's branch.

## 4. The genesis and its development phrases in `shared/`

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

## 5. Tell the chat when these change

The chat's specs check these against `server/`
(`chat/spec/compatibility_spec.rb`, and every spec that starts a real
agnostic server):

- the development genesis record;
- the development genesis phrase;
- the key that phrase derives;
- `GET /api/host`, `/api/genesis`, `/api/records`, `/api/states`,
  `/api/accounts`, `/api/keys/<pubkey>` and `/api/ratings`, and
  `POST /api/records` and `/api/contacts`, and the signed-upload headers;
- not listening, or answering 503, until the server is live.

A change to any of these is a change the chat must follow. Please note it in
the commit message.
