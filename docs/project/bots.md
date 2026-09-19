# Bots

Test traffic. Each bot is one process holding one account, talking to the
server exactly as a browser does: it asks for a challenge, signs it, keeps the
session cookie, and sends signed records. The server cannot tell the difference,
which is the point — a bot that took a shortcut would be testing the shortcut.

The purpose is to give the moderation machinery something to moderate. How fast
does a scammer get silenced? How much damage does one credulous account do by
vouching for the wrong people? Does a troll's reports move anybody, and does an
expert's standing survive a swarm of them?

```bash
bin/vouch --count 3                          # once, before the first swarm
bin/bot personas/regular.yml --name ana
bin/bot personas/regular.yml --explain       # what this persona implies
```

One persona file can back any number of bots. `--name` is what separates their
accounts and their state, so a dozen spammers need one file:

```bash
for i in $(seq 1 12); do bin/bot personas/spammer.yml --name spam-$i & done
```

## Getting seen

An unrated account sits at exactly zero and is invisible to everybody. That is
the sybil defense, and it applies to bots as hard as it applies to anybody —
so a swarm does not get to opt out of it with `show_unrated` and still call the
test realistic. Somebody visible has to vouch.

Tim cannot do it directly for every bot: the genesis account friending two
hundred accounts would make it a rubber stamp and nothing downstream would mean
anything. So `bin/vouch` creates a handful of **voucher** accounts, Tim friends
those once, and each new bot is introduced by one of them as it is born:

```
Tim ──friend──▶ voucher ──"this account exists"──▶ bot
```

A bot is then three hops from anyone who rates Tim: **visible, and nowhere near
trusted**, which is exactly what a brand new account should be. The vouch is
deliberately not a friendship — it is the least rating that clears the
visibility line, read off the curve under the server's own parameters, so it
says "this account exists" rather than "I know them".

Vouchers live in `data/bots/vouchers.json`, written 0600 because they are seed
phrases. If the genesis seed is not on the machine you run `bin/vouch` on, it
prints the `script/tim.rb friend` commands to run wherever it is.

Every bot also friends the genesis account when it is born, and `starting_friends`
other bots — a new account arrives with a contact or two, the way a person who
joined a small server on somebody's recommendation does.

## Categories

Every persona declares one of seven, defined once in
`config/bot-categories.yml`:

| category | what it is for |
|---|---|
| `realperson` | the baseline: ordinary traffic for the bad actors to hide among |
| `expert` | useful and accurate; the account whose standing should be hardest to shift |
| `bot` | honest automation, small mechanical corrections; a harmless control |
| `gullible` | honest, and vouches for exactly the people it should not |
| `scammer` | urgency and credential-phishing patterns, simulated |
| `spammer` | volume nobody asked for |
| `troll` | picks fights; the test case for reports and negative emotes |

The category's `definition` and `guidance` go to the model verbatim, above the
persona's own `disposition`, so a persona can be nothing more than a name and a
voice and still behave like the kind of account it claims to be.

Two fields in that file are read by the script rather than the model, because a
270M model cannot be relied on to follow an instruction it was given four
hundred tokens ago:

- **`drawn_to`** — which categories this one gravitates towards when choosing
  whom to answer, react to and friend. A gullible account befriending scammers
  is the behaviour under test, so it is arranged rather than hoped for.
- **`links`** — see below.

## Links

Nothing a bot posts can contain a link to anywhere that was not vetted. The
scammer and spammer categories are `links: safe`, which means every URL in what
they were about to post is **replaced** with one from `safe_links` — the
rickroll, or `/caught.html`, a page on this server explaining what clicking a
stranger's link usually gets you. Every other category is `links: none`, and
URLs are stripped.

This is enforced in `lib/reputable_chat/bot/brain.rb`, on the way out, for
every brain. A persona's own scripted lines go through it too: a link written
into a YAML file by a person is not more trustworthy than one a model invented.

## The visit model

Nothing in a persona file says how long to wait between posts. It says how
often the bot shows up, how long it stays, and how much it does per week; the
rest follows.

A bot is either **visiting** — reading, reacting, occasionally posting — or
**away**. A visit ends because something offline took the person's attention,
which is a clock and not a quota, so departure is exponential: still being here
after ten minutes says nothing about whether they leave in the next one.

```yaml
posting:
  visits_per_week: 14.0     # how often they check in
  visit_minutes: 12.0       # mean visit length
  posts_per_week: 12.0      # mean posts
  reactions_per_week: 45.0  # mean reactions
  min_gap_seconds: 10       # floor between actions
  mode_gap_seconds: 45      # typical gap while they are at the keyboard
```

Each parameter has exactly one job, so no two can contradict each other:

- `visits_per_week` and `visit_minutes` are the two-state process. Time away is
  exponential around `(week / visits_per_week) - visit_seconds`, derived rather
  than configured.
- `min_gap_seconds` and `mode_gap_seconds` are the tempo *within* a visit: how
  fast they click, not how much they do. The gap is log-normal, so most are a
  minute or two and the occasional one is much longer, where they are reading
  rather than typing.
- `posts_per_week` and `reactions_per_week` decide what each action turns out
  to be. Whatever is left over is **reading** — a poll that does nothing, which
  is most of what anybody does.

Posts therefore arrive in clusters minutes apart with hours of nothing between,
without anything in the scheduler arranging that: they can only happen while
the bot is present.

A visit is also a login, which is how the reputation rules want it — buckets
are sorted on arrival and hold until the bot comes back, so a reaction it makes
at 9pm changes nothing it can see until tomorrow.

### Why the weekly rates are honest

The count of actions in a visit is not `visit_length / mean_gap`. Actions are a
renewal process stopped by an independent exponential deadline, and the obvious
formula undercounts by several percent — which would quietly make every
`posts_per_week` in every persona file a few percent optimistic. `Schedule`
uses `E[N] = phi / (1 - phi)` for `phi = E[exp(-G / visit_mean)]`, computed by
quadrature because the log-normal has no closed-form transform.
`spec/bot_schedule_spec.rb` simulates three hundred weeks and checks that what
comes out is what the file asked for.

### Watching a week happen over lunch

`--speed 60` divides the waiting by sixty and changes nothing else — every
rate, distribution and ordering is the one the persona asked for. Account
recycling is scaled the same way, and state files keep honest wall-clock
timestamps so a sped-up run cannot leave behind a bot that retires itself the
moment it is used at normal speed.

## Brains

`brain:` picks where the words come from.

| brain | cost | what it is |
|---|---|---|
| `scripted` | nothing | a list of `lines:`, picked at random. Does not read the room, because real spam does not either |
| `markov` | nothing | an order-2 chain over what this account has actually read: on-topic vocabulary, no meaning |
| `llm` | one shared model | a small local model, prompted with the category, the disposition and the room |

The bot is shown the tail of the conversation **its account can actually see**,
with display names, and asked for one short line. A bot that is blocked from
seeing somebody is not writing replies informed by them either.

### The model

Run **one** server for the whole swarm and point every bot at it. A model per
bot is the same weights in memory N times, and these bots ask for roughly forty
tokens an hour each.

```bash
ollama pull gemma3:270m && ollama serve     # ~200 MB, CPU is fine
```

```yaml
brain: llm
llm:
  endpoint: "http://localhost:11434/v1/chat/completions"
  model: "gemma3:270m"
  max_tokens: 60
```

The endpoint is the OpenAI-compatible one, which both `ollama serve` and
llama.cpp's `llama-server` expose, so either works. Smallest first:
**Gemma 3 270M IT** (~200 MB), **SmolLM2-360M-Instruct** (~270 MB, chattier),
**Qwen2.5-0.5B-Instruct** (~400 MB, more coherent). All three produce stilted,
slightly off-topic chat, which is the register wanted here.

If the model is down or slow, a bot reads the room instead of posting and logs
why. It does not die — these run for days.

## Recycling

```yaml
recycle_after_days: 3
```

The spam simulation. The bot posts for a few days, abandons the account and
comes back as somebody new, so whatever the network worked out about the old
key is still perfectly correct and no longer attached to anybody. The lifetime
is jittered per instance, so a fleet started together does not all vanish on
the same afternoon, and `usernames:` supplies the pool of names to come back
under.

Retired phrases stay in the state file, so an abandoned account can still be
opened in the browser and inspected. The bot itself never touches it again.

State files hold seed phrases in plaintext under `data/`, which is gitignored.
They are throwaway test accounts and there is no recovery for any of them, so
nothing of value should ever be signed into a bot's seed.

## Accounts and the chain

A bot holds a real BIP39 seed phrase and derives its key through
`script/derive_key.mjs` — the same helper the genesis account uses, loading the
same vendored hash-wasm the browser loads. So **you can log into any bot from
the login screen** and see what it has been doing. The phrase is in the bot's
state file under `data/bots/<name>.json`, and a bot machine therefore needs
node on PATH (or `BOT_NODE=/path/to/node`).

Every record a bot signs carries an `ack`: the record hash of the most recent
thing it could see whose author it rates above
`chain.min_reputation_to_acknowledge`, or the genesis when there is nothing. A
bot checks at startup that the genesis in its checkout is the one the server is
running and refuses to start if not, because otherwise every `ack` it signs
would point at a record nobody else has.

## What the bots do to reputation

Reacting and replying both count as one vote for the author, once per message,
and are folded into the bot's own published config as `net_votes` — the records
are the display form, the config is the reputation form, and a reaction that
never reached a config changes nobody's reputation.

Friending is rare for most categories (`friend_per_visit`, around 0.02). A
friendship is worth 0.5 on its own, which is most of the way to Trusted for
everyone it reaches. The gullible category is the deliberate exception: it
hands them out, to the people its `drawn_to` says it should not.

Nothing reports anybody. Reporting is a judgement the swarm should not be
making on its own — it is the thing you are there to do, and to watch work.

## Load

An away bot does not poll at all; only a visiting bot watches the room, every
`poll_seconds`. At the default rates, fifty bots have two or three awake at any
moment. The room serves the last hundred messages with no `since` parameter, so
each poll re-fetches them and bots dedupe locally — fine at test scale, worth
remembering before pointing five hundred bots at one server.

## Flags

| flag | what it does |
|---|---|
| `--name NAME` | which instance this is; separates account and state |
| `--server URL` | where to reach the server |
| `--origin URL` | what to sign, if the server is reached by a different address than it publishes |
| `--state DIR` | where state files live (default `data/bots`) |
| `--speed N` | compress the waiting N times |
| `--visits N`, `--once` | stop after N visits, starting immediately |
| `--seed N` | fix the RNG for a reproducible run |
| `--explain` | print the schedule and briefing this persona implies, and exit |

`--origin` matters when bots run elsewhere: the origin travels inside the
signed login payload and must match the server's configured `origin` exactly,
not the address the bot happened to dial, or every login is rejected as a bad
signature.
