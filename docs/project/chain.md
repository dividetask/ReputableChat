# The chain

Every signed record in ReputableChat names the most recent records its author
had seen when they signed it. That one field turns a pile of independent
signatures into a single tangled history: if you can see a record, you can walk back from it
through everything its author had already seen, and everything *those* authors
had seen, until you reach the genesis.

There is no proof of work and no mining. The chain is not there to put records
in one agreed order or to stop double spends — it is there so that a record
cannot be quietly removed, back-dated, or shown to one person and not another. A server
that drops a message has to drop everything that acknowledged it, and everything
that acknowledged *those*, which is not something it can do selectively without
the gap being visible.

## Records

A record is a signed payload. Five kinds so far:

| purpose | what it is |
|---|---|
| `reputablechat:identity:v1` | an **identity declaration**: who someone is, in their own words |
| `reputablechat:attestation:v1` | what someone thinks of everyone else |
| `reputablechat:message:v1` | a message in a room |
| `reputablechat:emote:v1` | one person's response to one message |
| `reputablechat:release:v1` | a published version of the client |

Every one of them carries `ack`: a list of record hashes, sorted, with no
duplicates, at most 16. Sorted and unique so that the same set of records always
produces the same bytes; the server refuses any other ordering rather than
fixing it, because fixing it would change what was signed. The private vault
has none, because nobody else ever sees it — see [identity.md](identity.md).

Records are **generated, not stored as files.** The server keeps database rows
and builds the record when someone asks for it. That is only safe because the
canonical form is deterministic: the same row produces the same bytes and
therefore the same hash and the same signature, every time, on any machine. The
moment that stops being true the whole structure stops verifying, which is why
`spec/canonical_parity_spec.rb` exists and why floats are refused outright.

## Notes

Every chain record carries a `note`: free text, null unless set, which the
software never reads.

It is there because a chain is browsable. Somebody reading the raw records — an
archivist, an auditor, a person checking what was signed when — gets a place
where the author can speak to them directly, rather than only to whatever
client happened to render the record. Bitcoin's genesis block has a newspaper
headline in it for the same reason.

Three properties make it safe to have:

- **It is signed.** A note sits inside the payload, so nobody can attach one to
  somebody else's record, strip one, or edit one afterwards.
- **Nothing branches on it.** No code reads it, so nothing can be smuggled
  through it by writing something that reads like a directive. It is inert by
  construction rather than by policy.
- **It is bounded** (16,000 bytes, room for the rules) and **normalized**: an absent note and an
  empty one produce identical bytes, so two records a reader would call the
  same cannot carry different signatures.

Anything that renders a note treats it as text and never as markup, like every
other string somebody else wrote. That rule is not special to notes — see the
`textContent` line in CLAUDE.md — but a note is the field most likely to be
displayed by a tool nobody thought about when it was written.

A note is permanent and cannot be retracted, which is worth saying twice: it is
signed into a record that other records will acknowledge.

## Record hashes

`ack`, `reply_to` and an emote's `message` field all point at record hashes. A
signature identifies a payload; a hash identifies the *record*, signature
included, which is what you want when the thing you are linking to needs to be
tamper-evident as a whole.

```
record_hash = SHA256("reputablechat:record:v1\n" + canonical_payload + "\n" + signature)
```

Hex, 64 characters, the same shape as a content-addressed image name.

The two newlines are unambiguous separators rather than a convention, because
canonical JSON can never contain a raw `0x0A` — JSON escapes a newline inside a
string to the two characters `\n`, and there is no whitespace between tokens.
Base64url contains no newline either. So there is exactly one pair of strings
that produces any given hash input.

Hashing the stored `payload` **string** rather than a re-serialized object is
deliberate. The server holds the canonical bytes exactly as they arrived and
never parses them back into an object; re-serializing server-side is the one
thing guaranteed to break a signature eventually.

The domain prefix keeps this hash from colliding with the other SHA-256 in the
system, which addresses image and asset bytes directly.

## Genesis

The genesis account's first identity declaration is the bottom of the chain.
It is the only record whose `ack` is empty; every record that has seen nothing
else acknowledges it. Its `note` carries the first version of the rules — see
**Rules** below.

The genesis account is the developer's, and it is the same on every server:
there is one network and one chain. Its handle is Tim by default, but the docs
say *genesis account* because the handle is only a handle.

It is generated by `script/generate_genesis.rb` and committed to
`config/genesis/<environment>.json`. That file is the only record stored as a
file, and it is stored as one because every client needs to agree on the hash
before it has fetched anything — a genesis you have to download from the server
is not a genesis.

### The host account

A server can have an account of its own: the **host account**. Its first
identity declaration acknowledges the genesis, so a server's account hangs off
the network's chain instead of starting a second one. It is optional; a server
without one runs on the genesis account alone.

It is generated by `rake host` (`script/generate_genesis.rb --host`, which
takes the same `--handle`, `--bio` and `--icon` flags as the genesis) and
committed to `config/host/<environment>.json`, with its icon beside it, for the
same reason the genesis is: a client needs it before it has fetched anything.
The server refuses to boot on a host account that does not acknowledge the
genesis it runs.

Nothing enforces who signs what. By convention the genesis account signs what
covers the whole network — releases and the rules — and the host account signs
what concerns one server, such as an outage message. `script/tim.rb --host`
signs as the host account.

### Everyone starts by trusting them

A new account starts with the genesis account as a friend, and with the host
account as a second one where the server has one.

It has to. An unrated account sits at exactly zero and is invisible to
everyone, which is the sybil defense — but it also means a newcomer who trusts
nobody sees nobody, and a network where nobody has vouched for anybody shows a
blank screen. Trusting the genesis gives a new arrival one anchor to see
through, and it is what makes `script/tim.rb visible <pubkey>` do anything:
lifting somebody over the line in the genesis account's own ratings lifts them
for everyone who has the genesis at one hop.

Two things about how it is done matter more than the fact of it.

**It is an ordinary friend in the user's own vault** — not a rule in the
client, not a rule on the server, and not a special case anywhere. The friend
list is private; what reaches anyone else is the genesis account's own
attestation, which is published like everybody's. It sits in the friend list
beside everybody else and it can be removed like anybody else.
A trust that cannot be seen or withdrawn is not a default, it is a policy
wearing a default's clothes, and avoiding a reputation nobody chose is the
entire point of this project.

**It is seeded once, when the identity is created.** Re-adding it whenever it
is missing would mean removing it never took, which is the same thing as not
being able to remove it. `public/js/defaults.js` holds the rule, and
`spec/defaults_spec.rb` asserts there is exactly one call site.

Removing it is a real choice with real consequences: without the genesis at one
hop, nothing it vouches for reaches you, and nobody it has made visible is
visible. That is the user's decision to make, which is why they get to make it.
Everything here applies to the host account too.

### Its avatar is committed too

The genesis account's icon sits beside its record as
`config/genesis/<environment>.<ext>`, and the server adopts it into the image
store at boot.

Every other image reaches the store by being uploaded. This one cannot: the
declaration naming it is committed and read before any client has fetched
anything, and the store lives under `data/`, which is not in the repository. So
the bytes are committed as well, and the name stays what it is for every other
image — the SHA-256 of those bytes — which is what lets a reader confirm the
avatar is the one that was signed for.

Adopting it rather than serving it from `config/` keeps one serving path. And
the adoption checks: if the committed image does not hash to the name the
declaration carries, the server says so, because the alternative is a broken
avatar and no other sign that a signed claim was wrong.

### Development and production

Development and production have different genesis accounts, and different host
accounts, and the difference is not cosmetic. What follows is said of the
genesis and holds for the host account the same way.

**Development's seed is committed**, so that identity is public: everyone who
has cloned the repository can sign as it. That is the point. A fresh clone can
post messages and vouch for accounts locally without anybody being handed
a secret, and the CLI works out of the box. Nothing of value is protected by
it, because a development chain is not one anybody relies on.

**Production's seed is never committed.** Whoever holds it is the genesis
account, and can publish a release every client would run. The production
genesis seed lives with the developer, never on a server: a server needs only
the committed record. A server's production host seed lives on that server.

The failure this is shaped around is a production deployment quietly running
the published development key. Production therefore refuses to boot on it, and
the check compares public keys rather than filenames — the realistic mistake is
copying the development record into place, not giving it the wrong name.
`.gitignore` is written the same way round: ignore every seed, then un-ignore
development's, so a new environment is refused by default rather than committed
by an omission nobody notices.

The script runs the **real** client derivation path under Node: the vendored
Argon2id build, the same Argon2id parameters out of `config/reputation.yml`,
and WebCrypto Ed25519. It is not a second implementation that could drift from
the browser's and strand the account it creates.

It writes the seed beside the record, 0600 in both environments. The production
one is never printed — a terminal scrollback, a CI log and a screen share are
all places a seed should not turn up. Both hold the phrase rather than the
derived key, so it is the same secret a person would type into the UI and there
is one thing to look after rather than two that must not disagree.

`script/tim.rb` signs with it, which is how the genesis account posts
messages and vouches for new arrivals without somebody sitting at a
browser. That file is the one place in this project a private key lives outside
a browser, and it is the weakest point in the system: whoever holds it is the
genesis account, and can publish a release every client would run.

The command that matters on a new network is `visible`. An unrated account sits
at exactly zero and is invisible to everyone, which is the sybil defense and
also the reason nobody can get started. One positive rating from the genesis
account lifts somebody over the line for anyone who rates the genesis account.

## Rules

The rules say what every field of every record means and what makes a record
valid. The current version is the `note` of the genesis record. A later version
is a new revision of the genesis account's identity declaration whose `note`
carries the whole new text, never a diff. Every version stays on the chain, so anyone can
read the rules any record was made under.

**A record follows the newest rules it acknowledges.** Walk back through its
`ack`s; the newest revision of the genesis account's declaration found there is
the version it has to conform to. Order means acknowledgement and nothing else.
`ts` is the author's own claim and plays no part.

- **A record written for new rules waits for them.** It cannot be signed until
  those rules are published, because until then there is nothing for it to
  acknowledge them through.
- **A record written for old rules that arrives after new ones is refused.** The
  browser notices the refusal and signs it again under the new rules, along with
  anything of its own that acknowledged it.
- **Records made under old rules stay valid under them for good.** A change of
  rules is never retroactive.

The rules text is for people. Like every note it is never read by code; the
software implements the rules, and the note is what anyone can hold the
software to.

### The rules file is the source

Each version's text lives in the repository as
`docs/project/rules/v<version>.md`. The generator is to read the note straight from that file rather than from a
copy, so the file and the chain cannot disagree. A new version is a new
file; an existing one is never edited once published, because its bytes are
signed into the chain.

Version 0.001 is 7 KB, which is why a note may hold 16,000 bytes.

Versions below 1 are pre-launch and cost nothing to change, since nothing is
published. Version 1 is reserved for the first rules that go live.

### Not built

All of this section except the note limit, and the list form of `ack` above.
Today `ack` is a single hash, the genesis record's is null and its note is
empty, and `script/generate_genesis.rb` does not read the rules file.

## What gets acknowledged

You acknowledge the most recent records you have seen, up to 16, **whose
authors you rate above `chain.min_reputation_to_acknowledge`**. Not the most
recent records, full stop. More than one is what lets a record join branches of
the history that grew side by side.

That threshold is your own, it uses your own attestation and your own config,
and so the rule is subjective in exactly the way everything else here is. Two
people looking at the same room will disagree about which references were
legitimate, and there is no view from nowhere that settles it.

This has a consequence worth stating plainly rather than discovering later:
**records from accounts nobody has vouched for go unanchored.** They sit off to
the side of the history, referenced by nothing, and disappear the moment the
server stops serving them. That is the point of it — the chain is a structure
the vouched-for part of the network builds for itself, and being outside it is
the cost of having nobody at all willing to acknowledge you.

### What is actually excluded

"Never acknowledged" is too strong, and correcting it needs care, because the
obvious correction is also wrong.

It only takes **one** person willing to acknowledge somebody for them to be
anchored. If B can see someone A cannot, B may acknowledge their message, and
if A then acknowledges B, that person sits inside the history A's own records
hang from.

The tempting reading is that this is a leak — a bad actor sneaking in through
somebody careless. It is not, and treating it that way would contradict the
whole premise. **There is no objective troll.** Someone unbearable to A may be
worth reading to B, and B acknowledging them is B's judgement working
correctly, not failing. Being loud, rude or disagreeable is a matter of
tolerance, and tolerance is exactly what this system declines to decide
centrally. The intended end state is that the same person is muted by some and
tolerated by others, at the same time, with both views equally correct.

So the property is not "disagreeable people are kept out". It is narrower and
more useful:

**A record is anchored only if at least one person who clears somebody's bar
chose to acknowledge it.**

That is still a real defense, because it is what a sybil cannot satisfy. A
thousand accounts controlled by one person can acknowledge each other all day
and build an elaborate history among themselves, but nothing they make is ever
referenced from a record anyone else hangs their own records from. They get a
private region of the graph that the rest of the network never walks into.
Nobody is excluded for being disagreeable; the unvouched-for are excluded for
being unvouched-for.

And what anchoring confers is worth naming precisely: tamper-evidence, and
nothing else. A record that has been acknowledged cannot be silently dropped
without leaving a gap. It buys no visibility — A still never renders it — no
reputation, and no reach.

There is deliberately **no lever** against somebody else's acknowledgements. A
trust multiplier governs what a person's recommendations are worth, not what
they choose to anchor, and that asymmetry is correct: what B finds worth
acknowledging is B's business, and A disagreeing about it is precisely the
disagreement the system exists to hold open rather than resolve.

Refusing to acknowledge B over what B acknowledged would also be ruinous
mechanically. It means walking B's ancestry before every message, and it fragments
the DAG along each viewer's visibility, so a shared history stops being
shared — for the sake of enforcing a judgement that was never meant to be
shared in the first place.

### Walking the chain is reputation-blind

The above only stays harmless because of a rule that is easy to violate by
accident:

**Chain traversal ignores reputation entirely. Only rendering is filtered.**

Every record is content-addressed and independently signed, so a viewer can
fetch and verify a record whose author they would never display — the server
has no opinion about who can see whom, and a signature verifies without
trusting the signer. That is what keeps the walk back to the genesis intact
across a link through somebody hidden.

If a client ever gates *hash resolution* on visibility rather than gating
display, the walk stops at the first record it will not show, and the chain
genuinely does break from that viewer's perspective — not because the structure
is wrong, but because the client refused to look. Filter at the point of
rendering, never at the point of fetching.

The cost is that a viewer's ancestry is not confined to people they can see. A
full verification back to the genesis pulls in records from strangers and from
people that viewer has blocked, because both may sit on the path — somebody
else found them worth acknowledging, which is all it takes. Anyone trading
completeness for bandwidth is choosing how far back tamper-evidence actually
reaches.

The server does not check any of this. It cannot: it never computes a
reputation, so it has no opinion about whether an `ack` was well chosen. It
stores what it is given and serves it back. Verification is the reader's, and
only a reader running the author's own parameters can even attempt it.

## Attestations

An attestation is what one author thinks of everyone else, as **ratings** in a
field named `scores`:

```json
{ "purpose": "reputablechat:attestation:v1",
  "pubkey":  "...",
  "revision": 4,
  "ack":     ["<64 hex>"],
  "ts":      1710000000,
  "scores":  { "<pubkey>": { "reputation": "0.5", "trust": "1" } },
  "derived": { "scores": { "<pubkey>": "0.0123" } } }
```

`reputation` is the author's **rating** of that person; the signed field name
changes only with the next shape. Most people never set it by hand — friending
and emoting move it, and the curve runs once, in the author. Advanced users can
set it directly.

`trust` is the multiplier on everything that person recommends. It defaults to
1 for anyone positive and 0 for anyone blocked, so it only needs storing when
somebody has overridden it. It exists for the case where a friend is worth
reading but has terrible taste in who *else* to vouch for: set them to 0 and
their messages stay visible while their recommendations stop carrying spam in.

**Multipliers compound along the path.** A 0.5 at hop one and a 0.5 at hop two
means everything past the second is worth a quarter. A 0 prunes the branch
there — the traversal stops rather than carrying a zero through the remaining
hops, which is both correct and cheaper. A negative inverts, which is what
"I trust this person to be reliably wrong" means, and it compounds like any
other factor, so two negatives in a chain do multiply back to positive.

The friend and report lists are not here. They are in the private vault: what
the network sees is the rating that resulted, never the act that caused it.

### The derived cache

`derived` is the author's own calculated reputations, out to
`attestation.published_hops` (3 by default). It is not a convenience: it is the
**fourth term** of everyone else's reputation calculation, because the walk
stops at hop 2 and depth 3 is filled in from these summaries rather than
reached. See **Why the walk stops at two** in [reputation.md](reputation.md).

It is still never an input to a reader's own opinion at depths 0 to 2, which are
read from ratings. It carries 0.0009 of the total, cannot make anyone Trusted on
its own, and exists mainly to lift a well-regarded stranger from Blocked to
Tolerated.

A reader reaching for it has run out of its own reach: it either takes the
number or leaves it. It saves work, and a reader who wants the number checked
can walk far enough to compute it. Nothing about the parameters it was computed
under is published, which would tell everyone how a particular reader scores.

## Releases

A release record pins a version of the client:

```json
{ "purpose":   "reputablechat:release:v1",
  "publisher": "<genesis account's pubkey>",
  "revision":  12,
  "label":     "0.4.0",
  "files":     { "index.html": "<64 hex>", "js/app.js": "<64 hex>" },
  "notes":     "...",
  "ack":       ["<64 hex>"],
  "ts":        1710000000 }
```

It is a **manifest**, not an archive. A zip would have been the obvious thing
and is the wrong thing: entry order, timestamps and compression level all land
in the bytes, so the same source tree hashes differently on two machines, and a
hash that depends on who built it cannot prove anything. A manifest of
`path → sha256` is reproducible from a clean checkout by anyone. Files live in
the content-addressed asset store, so an unchanged file costs nothing across
releases — the 29 KB Argon2 build is stored once, forever.

Publishing every release to the chain means the operator cannot serve one
person different JavaScript from everyone else without it being visible. That
is the whole point; the version history is a pleasant side effect.

Releases are cut when one is published, not per commit. The chain is not the
repository.

**The genesis account is the only publisher for now.** The record carries `publisher` so that a
per-user trusted-developer setting can arrive later without re-signing
anything, but nothing today consults it.

### Not built: fetching a record by hash

There is no route that resolves a record hash to its record. Messages are
served per room, and `ack` names records that may be in another room, another
kind, or from somebody the viewer never fetched. Walking the chain at all needs
`GET` by hash, and it has to serve any record to anyone, for the reason above.

### Not built: actually loading one

The client still loads its UI from the server the ordinary way. A release
record is published and verifiable, and nothing executes off the chain yet.

That last step is deliberately not taken, because it is not the small step it
looks like. The private key lives in this origin's IndexedDB, and anything
served from this origin can use it. An old release loaded at the same address
would have full use of the current key, so pinning a version that shipped a
signing bug hands that bug back — and "load this old version, it was better" is
an easy thing to talk somebody into.

The options, when it comes to it:

- **Revocation and a floor.** A publisher-signed record makes known-bad
  versions unloadable. Cheap, covers the realistic case, and leaves the
  publisher deciding what you may run — which dents the point.
- **One origin per version** (`v12.chat.example`). Genuine isolation: the old
  version has no key at all and must ask the main origin to sign, which can
  show the user what it is signing. Needs wildcard DNS and TLS and a postMessage
  bridge.
- **No rail.** Pin whatever you like behind a warning.

Serving each version as ordinary static files from a content-addressed path
keeps `script-src 'self'` intact either way. Evaluating a bundle out of a JSON
blob would need `unsafe-eval`, and that CSP line is precisely what keeps
injected script from reaching the private key — so that approach is closed
whatever else is decided.

## What the server does with all this

The same as it did before, which is as little as possible. It verifies a
signature, rejects a rollback by revision, stores a row, and serves the bytes
back unchanged. It does not validate an `ack`, does not know what a reputation
is, and cannot tell a well-chosen reference from a bad one.

Storing rows rather than files is the balance this project wants: a record is
cheap to regenerate and expensive to store a million times over, and the
determinism that makes regeneration safe is already load-bearing for other
reasons.
