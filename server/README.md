# The agnostic server

A server for the chain and nothing else. It knows records and the rules
([docs/project/rules/v0.001.md](../docs/project/rules/v0.001.md)), and nothing
about the apps built on them: a chat message and a forum post are both records
of type `message`, and the further parts of a type are not its business.

What it does:

- **Checks every record against the rules before acknowledging it.** A record
  is accepted only when it is valid under the rules and the history it
  acknowledges. Records that arrive before something they acknowledge are held
  until it does; everything else that breaks a rule is refused, with the rule.
- **Stores records and serves them back byte-identical**, by hash, in the
  order it accepted them, or filtered by type prefix, account or target.
- **Has an account of its own, the host account**, generated on first boot,
  and **publishes heartbeats** with it.
- **Exchanges records with other servers, both ways.** It pulls what its peers
  accepted since it last asked, and pushes what it accepts.

It holds no vault, signs nobody in, stores no images, and computes no
reputation.

## Running it

```bash
cd server
bundle install
bundle exec rake spec          # the suite
bundle exec puma               # http://localhost:9292
bundle exec rake host          # this server's host account
BACKGROUND=0 bundle exec puma  # the API alone: no heartbeats, no syncing
PEERS=https://a.example,https://b.example bundle exec puma
```

Settings are in [config/server.yml](config/server.yml), which documents each
one: heartbeat interval, peers, how many records to hold for missing
ancestors, how far ahead of the clock a record may be, request limits.
`DATABASE_URL`, `DATA_DIR`, `GENESIS`, `PEERS` and
`HEARTBEAT_INTERVAL_SECONDS` override the file.

## The genesis

`config/genesis/development.json` is the developer's first identity
declaration in the rules' own format, signed with the development genesis key
(the public one whose seed is committed under `chat/`). Its `rules` field is
`docs/project/rules/v0.001.md` exactly, less its trailing newline, and a spec
fails if the two drift.

Production has no genesis yet, and a production server refuses to boot until
one is placed at `config/genesis/production.json`. It also refuses one signed
by the development key. `script/generate_genesis.rb` signs one from a private
key file and refuses to overwrite an existing genesis.

The chat app's committed genesis and host records predate the rules, so this
server cannot accept them. The two are on different chains until the chat
signs the rules' record shapes.

## The host account

On first boot the server makes two 12-word seed phrases and writes each 0600
into `data/<environment>/`:

- `host.seed`, the working phrase. The server signs with it, and refuses to
  boot without it rather than quietly becoming a new account.
- `host-master.seed`, the master phrase. Its key is declared as `mpubkey` and
  the server never reads it again. **Move it off the server**: it is what
  moves the account to a new working key if this machine's is ever taken, and
  that only works if it was not taken with it. The server says so on the
  boot that makes it.

The account's first identity declaration, in `host.json` beside them,
acknowledges the genesis; its handle and bio come from `config/server.yml`.
Keys are derived from the phrases exactly as the browser derives them
(Argon2id under the chat's `seed.kdf` parameters, which a spec holds equal),
so either phrase can be typed into a client to act as the account.
`config/bip39-english.txt` is the same wordlist as the chat's, checked by its
hash.

## Heartbeats

Every `heartbeat.interval_seconds` (600 by default; never less than the rules'
480), the server signs a heartbeat acknowledging its previous one and every
record of this rules version that nothing else here acknowledges yet, as many
as fit in the rules' 1,048,576 bytes, oldest first. This version leaves out
nothing for who wrote it: the server computes no reputation, so it has nothing
to decide with. A release is never named, because a heartbeat of v0.001 may
acknowledge only v0.001 records.

If acknowledging everything would hold both sides of a split (section 10), it
leaves out the side its own account is not on.

## The API

| | |
|---|---|
| `GET /api` | the rules version, genesis, host account, record count and limits |
| `GET /api/genesis` | the genesis record |
| `GET /api/host` | the host account: id, key, and its declaration |
| `GET /api/records?since=&limit=&type=&account=&target=` | records accepted after the cursor, oldest first; `next` is the cursor for the following page |
| `GET /api/records/<hash>` | one record, or 404 |
| `GET /api/frontier` | hashes of the records nothing here acknowledges |
| `POST /api/records` | `{"records": [...]}`, or one record on its own |

A record on the wire is `{"payload": "<canonical JSON>", "signature": "<base64url>"}`;
the server adds `hash` when it serves one. A POST answers one result per
record: `accepted`, `known`, `pending` with the hashes it is `missing`, or
`refused` with the `problems`. Anything pending makes the response a 202.

The cursor is this server's own count, meaningless anywhere else. Because a
record is only accepted after everything it acknowledges, paging from 0 gives
a peer every record in an order it can accept them in.

## Reading the rules

Where the rules leave room, this is how the server reads them. Each is a
decision someone may want to make differently.

- **Fields the rules do not list are accepted**, except on a heartbeat (which
  "may hold endorse, and nothing else"), inside a transfer, inside an output,
  and inside a score.
- **Whitespace and control characters** are Unicode's: Text may not start or
  end with White_Space, and holds no Cc character but tab, newline and return.
- **A key or signature has one spelling.** Base64url that decodes to the right
  length but would re-encode differently is refused, as is padding.
- **Integers stop at 2^53 - 1**, the largest JavaScript reads exactly.
- **A quorum names exactly one record**, and its validity turns on the count
  and the master-key condition only. Section 7 also says what a quorum should
  name when no key change is in dispute, but the example chain's second quorum
  names a spend whose rival is outside the quorum's own history, so that
  sentence is read as describing the usual case rather than as a condition.
- **"Current keys"** are the newest: a key change is signed with the newest
  working or master key, and a master key change with the newest master key.
  Signing with an allowed key that is not the newest is what contests.
- **A later declaration proposes new adjudicators only when it carries the
  field.** An empty list proposes the developer's account.
- **A compromised notice names records in its own history**, since that is
  where the account they belong to is found.
- **An issuer's endorsement counts as choosing** only when the issuer is not
  disputed as seen by the endorsing record, so a record endorsing the other
  spend is refused only after a choice that counts.
- **Releases are accepted, the rules after them are not.** A release is a
  v0.001 record and is checked as one. A record of any other version is
  refused, since this server cannot tell whether it is valid. Following a new
  version means implementing it here.
- **The clock guideline is checked toward the future only** (600 seconds by
  default). A record signed long ago legitimately arrives late when a server
  catches up with a peer, and back-dating is what the split rule is for.

## Known limits

- **History is recomputed for each check** with a recursive query over the
  acks, so checking gets slower as the chain grows. Fine at this size; it will
  want caching before it is not.
- **Anyone may post**, with no rate limit beyond the size of a request and the
  bound on held records. Storage grows without a retention policy.
- **Peers are a fixed list.** There is no discovery.
- **Files are not served.** Records name files by hash; something has to hold
  the bytes, and that is not this version.
- **Changing the handle or bio in the settings does not re-declare** the host
  account; it applies to an account declared after the change.
