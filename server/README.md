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
- **Syncs with other servers at each heartbeat, both ways.** It pushes what
  it accepted, offers its heartbeat, sends what the peer is missing, and pulls
  what the peer accepted. A peer whose heartbeat is more than ten minutes from
  this server's clock is ignored.

It holds no vault, signs nobody in, stores no images, and computes no
reputation. Apps run beside it and use it for the chain: the chat passes its
users' records here and reads back what it shows.

## Running it

```bash
cd server
bundle install
bundle exec rake spec          # the suite
bundle exec rake setup         # a fresh server: handle, address, other servers
bundle exec puma               # http://localhost:9393 (config/puma.rb), beside the chat's 9292
bundle exec rake peers         # the servers it syncs with, or has forgotten
bundle exec rake "sweep[<url>,<url>]"  # copy the chain from servers, generation by generation
bundle exec rake host          # this server's host account
BACKGROUND=0 bundle exec puma  # the API alone: no heartbeats, no syncing
PEERS=https://a.example,https://b.example HOST_URL=https://me.example bundle exec puma
```

Settings are in [config/server.yml](config/server.yml), which documents each
one: heartbeat interval, peers, how many records to hold for missing
ancestors, how far ahead of the clock a record may be, request limits.
`DATABASE_URL`, `DATA_DIR`, `GENESIS`, `PEERS`, `HOST_URL` and
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
into `host/<environment>/` at the root of the repository (`host_dir`,
`HOST_DIR`). That is outside this app on purpose: every app beside this server
-- the chat -- signs as the same account, one account per server.

- `host.seed`, the working phrase. The server signs with it, and refuses to
  boot without it rather than quietly becoming a new account.
- `host-master.seed`, the master phrase. Its key is declared as `mpubkey` and
  the server never reads it again. **Move it off the server**: it is what
  moves the account to a new working key if this machine's is ever taken, and
  that only works if it was not taken with it. The server says so on the
  boot that makes it. Its public key stays behind in `host-master.pub`.

The account is not declared on first boot. Its first identity declaration,
written to `host.json` beside them, is made when the server goes live, once
it has caught up (see **Catching up**), and acknowledges the latest
heartbeats it caught up to -- at most 16, heartbeats first, the genesis only
when there is nothing else. A declaration acknowledging nothing newer than
the genesis would be left behind by any server with more than 256 heartbeats
(section 10), and could never be joined. Its handle, bio and `url` come from
`host:` in `config/server.yml`; when any of them changes, going live
publishes a new declaration. The `url` is where other servers reach this one -- a server is
known by its account, so a server that wants live updates from its peers
declares the address they can reach it at.
Keys are derived from the phrases exactly as the browser derives them
(Argon2id under the chat's `seed.kdf` parameters, which a spec holds equal),
so either phrase can be typed into a client to act as the account.
`shared/bip39-english.txt` at the root is the wordlist, the one file both apps read, checked by its
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

## Syncing

The server stays online throughout, answering any server that connects. Its
own heartbeat waits on a timer until it is due (`heartbeat.interval_seconds`
after the last); then it publishes it and right away syncs with every peer in
turn. It reaches out to no one between its heartbeats:

1. **Share the heartbeat** with `POST /api/sync`, and nothing else unasked:
   the peer may have seen the rest already.
2. **The peer asks for what it is missing.** To check the heartbeat it needs
   every record in its history, so it answers with the hashes it does not
   hold, and is sent them, and asks again -- what it was sent may have
   ancestors it lacks too -- until it holds them all. The ask
   travels as its answer, not as a request of its own, because the sharing
   server may have no address the peer could reach.

Nothing is pulled the other way: the peer shares its records the same way,
when it publishes its own heartbeat. So records posted here reach the peers
with the next heartbeat, not sooner.

## Catching up

A new server spends some time catching up before it goes live: before its
first heartbeat it sweeps the chain from the servers it was given at setup,
several at once, and only then starts publishing. It does the same after a
restart, picking up where it stopped. `bundle exec rake "sweep[<url>,<url>]"`
sweeps by hand.

**Generations.** The chain is swept a generation at a time, and generations
belong to an account that publishes heartbeats: generation *g* of an account
is every record its heartbeat *g* brought into its history that none of its
earlier heartbeats held, so generation 1 is everything up to its first. A
record's history never changes, so every server holding those heartbeats
reaches the same generations. Within one, records are ordered by depth (one
past the deepest of their parents in the same generation), then by hash:
each comes after everything it acknowledges, and the order is the same on
every server. The part size is each server's own, though, so every part of
one generation is taken from the same server; if that server fails partway,
the generation starts again from its first part on another.

**The request.** `GET /api/sweep?account=&generation=&part=` names the
account whose generations are wanted (the answering server's own if left
out), the generation, and the part. A part holds at most
`limits.sweep_records` (500). The answer says how many parts the generation
has, the latest generation of that account the server holds, and the `next`
part to ask for, or nothing after the last. Each caller may make
`limits.sweep_requests_per_minute` (60) sweep requests in any minute -- a
caller being the address its request came from, or behind a reverse proxy
listed in `limits.trusted_proxies`, the address the proxy forwarded -- past
that it gets a 429 saying how many seconds to wait, and a server catching up
waits that long and asks again.

**From several servers at once.** A server catching up counts generations by
the first of its servers' own account, asks each server how far it holds
them, and fetches up to one generation from each server in parallel, then
checks them in order. A server that fails on a generation is replaced by the
next that holds it. Progress is kept per account.

Records no heartbeat of that account holds yet are in no generation; they
arrive with heartbeats once the server is live.

**Then it looks for a chain split.** Once caught up, the server asks each of
those servers for its latest records -- what nothing on it acknowledges yet
-- and fetches whatever of their history it lacks. If one of them holds a
record the rules refuse for holding both sides of a split, or their latest
records taken together hold a record and the heartbeat that orphaned it
(section 10), the server stops and waits for its administrator to pick a side.

**Not listening until then.** Until a server has caught up -- and after a
split, until a side is picked -- it has published nothing, not even its
account's declaration, and it has not opened its port: catching up happens
in `config.ru`, which Puma loads before it binds, so nobody can reach a
server that is not ready. (In Puma's cluster mode that holds only with
`preload_app!`.) The API also answers 503 if it is ever reached early. The check runs on every start, so a server that was
offline through a split wakes up stopped rather than settling it alone.

**Picking a side.** `bundle exec rake status` lists what split, and for each
split which side each server is on: *went on* (it holds the heartbeat that
left a record behind) or *left behind* (it holds that record and not the
heartbeat). `bundle exec rake "choose[<url>]"` follows the side that server
is on: servers on the other side are forgotten, the account is declared
acknowledging the chosen server's latest records, and the server goes live.

A split that happens while a server is running is settled by the rules
alone: its heartbeats stay on the side its own account is on.

## Which servers

**Setup.** `rake setup` asks a fresh server for the servers it should
know, and the list may be empty: the server then runs alone until another
reaches it. Every other server is learned from the records passed along. An
account that has published a heartbeat and whose latest identity declaration
names a `url` is taken for a server, and synced with once it answers at that
url as that account; one answering as anyone else is a failed try. So a
server that wants live updates declares its address (`host.url`), and one
that does not is still synced with by the servers it reaches itself.

**Withdrawing an address.** A server's address is the one its latest
identity declaration names. A new declaration with no `url` takes it off the
list and it is no longer contacted; one with a different `url` replaces the
old address.

**How many.** At most `peers.max_learned` (100) learned servers are synced
with at once. Past that a newly learned one is skipped until one is
forgotten; servers named at setup or in the settings do not count.

**Servers that cannot be reached** are tried less and less often: after the
first failure the next try waits `peers.retry.first_seconds` (10 minutes),
and each further failure multiplies the wait by `peers.retry.multiplier` (2),
up to `peers.retry.max_seconds` (a day). A server not reached for
`peers.forget_after_seconds` (a week) is forgotten at its next failed try. A
new identity declaration from it, or a sync from it, brings it back; its
heartbeats arriving through others do not, or a server whose address cannot
be reached would be tried at full pace for as long as they travel.

**Clocks.** A heartbeat offered for sync was signed a moment ago, so its `ts`
is the sending server's clock. When it is more than
`peers.max_clock_skew_seconds` (600) from the receiving server's clock, either
way, the receiver refuses it and ignores that server from then on: its syncs
are refused, and it is no longer pulled from or pushed to. A server is known
by its host account, not its address. Before ignoring anyone the receiver
checks that the heartbeat is valid and signed by the account it names, so a
forged heartbeat cannot get an honest server ignored. Only the offered
heartbeat is checked this way; older records sent as missing ancestors are
not, since being old is what they are.

Ignoring lasts `peers.ignore_seconds`, a week by default, and covers direct contact
only: the ignored server's records still arrive through other peers, since
refusing valid records would cut this server off from the network rather than
it. `bundle exec rake ignored` lists who is ignored, until when and why, and
`bundle exec rake "forgive[<host account id>]"` stops ignoring one early.

## Rating other servers

Rarely, a server publishes ratings of other servers: an attestation of its
host account, judged only by whether it could reach each server at the
address its account declared. Every value is in `ratings:` in
`config/server.yml`.

| what happened | rating |
|---|---|
| never reached, then forgotten | `never_reached`, -1 |
| reached for a while, then forgotten | `went_offline`, -0.01 |
| reached at least `reliable_ratio` (90%) of the times tried, 120 days after it was first reached | `reliable.rating`, 0.01 |
| the same, a year after | `established.rating`, 0.02 |
| anything else | nothing published |

A server this one rates -1 -- by reachability, or by an operator's hand -- is
ignored from then on: its syncs are refused and it is not contacted, until
an administrator brings it back with `bundle exec rake "forgive[<account>]"`.
Every other server, one that went offline included, comes back by itself.
An account a server has published nothing about counts as 0. Each rating
carries a trust of 0, always: that a server reliably produces heartbeats says
nothing about whether its ratings are worth believing, and publishing any
other trust would suggest it does. An attestation holds
only the ratings that changed since the last one, so most heartbeats publish
none. It is signed just before a heartbeat, which then carries it.

### By hand

The operator can set any account's rating, trust included, from the machine
the server runs on. It stands in for what reachability says until removed,
and goes out in the attestation published with the next heartbeat; an
account nobody has an opinion of any more is published as 0 with trust 0,
since an attestation can amend an entry but not delete one.

```bash
bundle exec rake "rate[<account id>,<reputation>,<trust>]"   # decimals from -1 to 1
bundle exec rake "unrate[<account id>]"                      # back to reachability
bundle exec rake ratings                                     # what it says of whom, and why
```

The apps beside the server read the current ratings at `GET /api/ratings`:
the chat uses them to choose which other chat servers to ask for files.

## The API

| | |
|---|---|
| `GET /api` | the rules version, genesis, host account, record count and limits |
| `GET /api/genesis` | the genesis record |
| `GET /api/host` | the host account: id, key, and its declaration |
| `GET /api/records?since=&limit=&type=&account=&target=` | records accepted after the cursor, oldest first; `next` is the cursor for the following page |
| `GET /api/records/<hash>` | one record with its `state`, or 404 |
| `POST /api/states` | `{"hashes": [...]}`: each record's state -- valid, tentative, disputed, confirmed or void -- as seen by everything here; null for one not held |
| `GET /api/accounts/<id>` | an account's newest identity declaration and attestation, and the record accepted from it last |
| `POST /api/accounts` | `{"accounts": [...]}`: the same for several |
| `GET /api/keys/<pubkey>` | the account a working key signs for, or null |
| `GET /api/ratings` | this server's current ratings of other accounts, each by hand or by reachability |
| `GET /api/frontier` | hashes of the records nothing here acknowledges |
| `POST /api/records` | `{"records": [...]}`, or one record on its own |
| `GET /api/sweep?account=&generation=&part=` | one capped part of one generation of an account, and the `next` part to ask for; 429 when asked too often |
| `POST /api/sync` | `{"heartbeat": ...}`: a peer's newest heartbeat; 403 when the peer is or becomes ignored |

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
- **The clock guideline** ("servers refuse records whose ts is far from their
  own clock") is read two ways. Any record more than
  `records.max_future_seconds` (600) ahead of the clock is refused. And a
  peer's heartbeat, offered as it syncs, more than ten minutes off either way
  gets that peer ignored (see **Syncing**). Records are not refused for being
  old: they legitimately arrive late when a server catches up, and back-dating
  is what the split rule is for.

## Known limits

- **History is recomputed for each check** with a recursive query over the
  acks, so checking gets slower as the chain grows. Fine at this size; it will
  want caching before it is not.
- **Anyone may post**, with no rate limit beyond the size of a request and the
  bound on held records. Storage grows without a retention policy.
- **Peers are a fixed list.** There is no discovery.
- **Files are not served.** Records name files by hash; something has to hold
  the bytes, and that is not this version.
