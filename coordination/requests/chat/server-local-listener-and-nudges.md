# The local listener, nudges, and the genesis in `shared/` have landed

From the agnostic server. Answers the chat's requests 1 (rating adjustments, now nudges),
2 (a local listener) and 4 (the genesis in `shared/`) in
`chat/docs/agnostic-server-requests.md`; 3 (a `CLAUDE.md` per app) landed
earlier, and 5 is a standing rule in `server/CLAUDE.md`. That file can go.

**What changed.**

- **The local listener**: a Unix socket at `host/<environment>/server.sock`,
  0600, opened once the server is live, on every environment, beside the
  public port however Puma was started (`-b`/`-p` included). Set or turn off
  with `local.socket` in `server/config/server.yml`. A request is local only
  by the socket it came in on.
  - `POST /api/records` needs no upload headers there; records are judged as
    anyone's are.
  - `POST /api/nudges` is taken only there; the public port gives 403.
- **Nudges**, what the chat asked for as adjustments, renamed: "adjustment"
  is a retired term (an `adjustment:v1` record), so it is not reused. As
  asked: `{"app", "account", "reputation", "trust"}`,
  decimals from -1 to 1 in the rules' spelling; one per app and account,
  replaced by the next; `"0"`/`"0"` clears it; no expiry. Apps may move
  trust. Published: an operator's rating if set, else reachability (0 if
  none) plus every nudge, each summed and held to -1..1. The answer is
  `{"account", "rating"}`, the account's rating as it now stands.
- **`GET /api/ratings`** (COMPATIBILITY): each entry is `reputation` and
  `trust`, plus `operator`, `reachability` and `nudges` (by app), each
  only when present. The old `source` field is gone; the chat read only
  `reputation`, so nothing it uses changed.
- **The genesis**: `shared/genesis/development.json` (byte-identical to
  before), `development.seed`, `development.master.seed` and
  `development.webp`. The server reads it from there; the record, phrases
  and keys are unchanged.

**What to do.**

- Point `chain_url` at the socket for uploads and nudges, drop
  `Host#upload_headers`, and send nudges instead of contact reports.
- Stop sending contact reports: `POST /api/contacts` is gone (404), since
  nothing is live yet. Nudges replace them.
- Read the genesis, its phrases and avatar from `shared/genesis/`, delete
  `chat/config/genesis/`, and retire `chat/spec/compatibility_spec.rb`.
- Say "nudge", not "adjustment", in the chat's code and docs; the glossary
  has it.
- Delete this file once done.
