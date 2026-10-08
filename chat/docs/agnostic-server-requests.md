# What the chat needs from the agnostic server

Changes the chat is waiting on in `server/`, which is the `Agnostic-Server-V0`
branch's. Each says what to add and how the chat will use it. Remove an entry
once it has landed and the chat has caught up with it.

## 1. A contact report that says a server lacked a file

**Why.** A chat server fetches a file it lacks from the other chat servers
that announced themselves (`chat/lib/reputable_chat/file_peers.rb`), and tells
its agnostic server how each attempt went (`POST /api/contacts`). A server
that answers but does not have the file should lose reputation, though less
than one that does not answer at all. Today a report can only say `reached`
true or false, so a missing file has to be reported as one or the other.

**What to add.**

- `POST /api/contacts` accepts an `outcome` field in the signed payload, one
  of `"reached"`, `"missing"` or `"unreached"`.
  - `"missing"` means the server answered, as the account that announced it,
    but did not have what it was asked for.
  - `reached: true` / `reached: false` stay accepted, meaning `"reached"` /
    `"unreached"`, so a chat built before the change keeps working.
  - A report carrying both, or neither, is refused with 400.
- The contacts table counts misses beside successes and attempts.
- A configurable value in `config/server.yml` under `ratings:` sets how much a
  miss counts against a server, as a quoted decimal from `"0"` to `"1"`, for
  example `missing_penalty: "0.25"`.
  - `"0"`: a miss counts as reached.
  - `"1"`: a miss counts as not reached.
  - Where `reliable?` compares successes with attempts, a miss adds
    `1 - missing_penalty` to the successes.
  - A miss never makes a server count as offline. It answered.
- `bundle exec rake ratings` shows misses beside successes and attempts.

**How the chat will use it.** It reports `"missing"` when a server answers
404 for a file, and puts that server off for a shorter time than one that did
not answer. That shorter time is a chat setting. Until this lands, the chat
reports a missing file as not reached.

## 2. One-time contact reports (optional)

**Why.** A contact report is signed by the host account and checked against
the server's clock (±600 seconds). Within those ten minutes the same report
can be sent again and counted again. Reports travel only between an app and
the agnostic server beside it, usually on one machine, so this matters only
where that connection can be observed.

**What to add.** An optional `nonce` field in the payload, 16 or more random
bytes in base64url. The server refuses a nonce it has already seen within the
window. The chat will start sending one once this is accepted.

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

## 4. Tell the chat when these change

The chat's specs check these against `server/`
(`chat/spec/compatibility_spec.rb`, and every spec that starts a real
agnostic server):

- the development genesis record;
- the development genesis phrase;
- the key that phrase derives;
- `GET /api/host`, `/api/genesis`, `/api/records`, `/api/states`,
  `/api/accounts`, `/api/keys/<pubkey>` and `/api/ratings`, and
  `POST /api/records` and `/api/contacts`;
- not listening, or answering 503, until the server is live.

A change to any of these is a change the chat must follow. Please note it in
the commit message.
