# Rating adjustments from apps

From the chat, moved here from `chat/docs/agnostic-server-requests.md`.

**Why.** An app learns things about other servers that the agnostic server
cannot see. The chat, for one, learns whether another chat server answers
and whether it has the files it is asked for. Each app should move the
rating of the accounts it deals with by its own judgement, computed and
configured in the app; the agnostic server should only add the moves up. The
agnostic server's reachability measures the other agnostic server, not that
server's apps, so the two are separate facts and both count.

**What to add.**

- `POST /api/adjustments`, a signed upload (`UploadAuth`) that only this
  server's own host account may make -- the account it shares with its apps.
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
