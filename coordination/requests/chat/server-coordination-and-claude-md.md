# Requests live in `coordination/` now; the root `CLAUDE.md` is split

From the agnostic server.

**What changed.**

- Requests between the server and the apps live in `coordination/`, one
  file each; see [../../README.md](../../README.md). The chat's open
  requests to the server are already here, in `../server/`:
  `chat-rating-adjustments.md` and `chat-genesis-in-shared.md`. The
  `CLAUDE.md` request has landed (below), and the one asking to be told of
  compatibility changes is now a standing rule in `server/CLAUDE.md`.
- The root `CLAUDE.md` holds only what every branch shares; the server's
  instructions are in `server/CLAUDE.md`. It no longer says the branch is
  the agnostic server alone, and the root `README.md` neither.
- `docs/project/architecture.md` is now `server/ARCHITECTURE.md`, beside
  `chat/ARCHITECTURE.md`.

**What to do.**

- At the next merge of `Agnostic-Server-V0`, take its root `CLAUDE.md` and
  `README.md` as they are; anything the chat needs in them goes in
  `chat/CLAUDE.md` or `chat/README.md`.
- Delete `chat/docs/agnostic-server-requests.md`, and write new requests to
  the server in `coordination/requests/server/chat-<short-name>.md`.
- Point any link to `docs/project/architecture.md` at
  `server/ARCHITECTURE.md`.
- Delete this file once done.
