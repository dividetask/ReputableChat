# Running bots

Test traffic for the server: scammers, trolls, credulous people and ordinary
ones, posting and reacting on their own schedules so there is something for the
reputation system to do. Each bot is one process holding one real account —
same seed phrase, same key derivation, same signed records a browser sends.

This file is how to use them. [docs/project/bots.md](../docs/project/bots.md)
is why they are built the way they are.

## Start here

From a fresh clone, with the server running (`bundle exec puma`):

```bash
bin/vouch --count 3                          # once per server, ever
bin/bot personas/regular.yml --name ana      # one bot, in the foreground
```

`bin/vouch` creates a few accounts that introduce new bots, and has the genesis
account friend them. **Do this first.** An account nobody has vouched for sits
at exactly zero and is invisible to everyone — including the other bots — so
without it your swarm posts into a room where nothing can see it.

It needs the genesis seed for the environment it is talking to. A fresh clone
already has the development one committed, so this works with no setup. If you
run it against a server whose seed is elsewhere, it prints the
`script/tim.rb friend` commands to run there instead.

Then watch it happen:

```bash
bundle exec rake dump                        # everything the server is holding
bundle exec ruby script/tim.rb status        # who the genesis account has rated
```

Bots are invisible to **you** too until you rate one. Friend a single bot from
your own account and watch how far that reaches — that is the interesting part.

## A swarm

One persona file backs any number of bots. `--name` is what separates their
accounts, so a dozen spammers need one file and a loop:

```bash
for i in $(seq 1 12); do bin/bot personas/spammer.yml --name spam-$i & done
```

They stagger themselves — a bot waits a random part of its away-time before its
first visit, so twenty started together do not all arrive at once. Kill them
with `pkill -f bin/bot`; state is saved after every action, so nothing is lost
and restarting continues the same accounts.

At the shipped rates most of the swarm is asleep at any moment. An away bot
makes no requests at all.

## What ships

| persona | category | brain | what it is for |
|---|---|---|---|
| `regular.yml` | realperson | llm | baseline traffic |
| `lurker.yml` | realperson | markov | reacts constantly, posts once a week |
| `expert.yml` | expert | llm | the standing that should be hardest to shift |
| `helper-bot.yml` | bot | llm | honest automation; a harmless control |
| `gullible.yml` | gullible | llm | vouches for exactly the wrong people |
| `scammer.yml` | scammer | scripted | urgency and credential phishing, simulated |
| `spammer.yml` | spammer | scripted | volume nobody asked for |
| `troll.yml` | troll | llm | picks fights; the test case for reports |

`scammer` and `spammer` are scripted, so they cost nothing to run and you can
start fifty. The rest want a model; without one they read the room and post
nothing, which is a quiet way to have a swarm do very little.

## Writing one

Three keys are the minimum. Everything else has a default:

```yaml
category: "realperson"      # one of the seven in config/bot-categories.yml
username: "Ana"
lines: ["hello everyone"]   # only needed by the scripted brain
```

Check what you wrote without touching the server:

```bash
bin/bot personas/mybot.yml --explain
```

That prints the schedule the numbers imply, the share of actions that end up
being posts, reactions and reading, and the full briefing the model would get.
A persona whose numbers contradict each other is refused here, by name, rather
than hours into a run.

### Every field

| key | default | what it does |
|---|---|---|
| `category` | — | required; one of the seven in `config/bot-categories.yml` |
| `username` | — | required; the display name |
| `usernames` | — | pool to draw from, for bots that recycle |
| `bio` | `""` | profile line |
| `room` | `general` | which room to live in |
| `brain` | `scripted` | `scripted`, `markov` or `llm` |
| `lines` | `[]` | what a scripted bot says; required for that brain |
| `disposition` | `""` | this bot's own character, added after the category's briefing |
| `reply_ratio` | `0.7` | share of posts that reply to something rather than start it |
| `friend_per_visit` | `0.02` | chance of friending somebody it has already been positive about |
| `starting_friends` | `1.0` | mean number of other bots friended at birth, besides the genesis account |
| `emote_bias` | `8/2/1` | relative weights for positive, neutral and negative reactions |
| `recycle_after_days` | never | abandon the account after this long and come back as somebody new |
| `poll_seconds` | `10` | how often it refreshes the room while it is present |
| `show_unrated` | `false` | see accounts nobody has rated. Leave it off |
| `seed` | generated | a fixed seed phrase, for a bot that must keep one account |
| `posting` | see below | the schedule |
| `llm` | see below | where the model is |

### `posting`

Rates per week. How long it waits between posts is derived from these, not
configured — so no two settings can contradict each other.

| key | default | what it does |
|---|---|---|
| `visits_per_week` | `14.0` | how often it checks in |
| `visit_minutes` | `12.0` | mean length of a visit |
| `posts_per_week` | `12.0` | mean posts |
| `reactions_per_week` | `45.0` | mean reactions |
| `min_gap_seconds` | `10` | floor between two actions |
| `mode_gap_seconds` | `45` | typical gap while it is at the keyboard |

Whatever is left over after the posts and reactions is **reading**, which is
most of what anybody does. Posts arrive in clusters minutes apart with hours of
nothing between, because they can only happen while the bot is present.

### `llm`

| key | default |
|---|---|
| `endpoint` | `http://localhost:11434/v1/chat/completions` |
| `model` | `gemma3:270m` |
| `max_tokens` | `60` |
| `temperature` | `1.0` |
| `timeout_seconds` | `60` |

## Turning on the model

Run **one** server for the whole swarm and point every bot at it:

```bash
ollama pull gemma3:270m && ollama serve      # ~200 MB, CPU is fine
```

That endpoint is the OpenAI-compatible one, so llama.cpp's `llama-server` works
just as well. If the model is down, bots read the room instead of posting and
say so in their log rather than dying.

## Flags

| flag | what it does |
|---|---|
| `--name NAME` | which instance this is; separates account and state |
| `--server URL` | where to reach the server (default `http://localhost:9292`) |
| `--origin URL` | what to sign, if the server is reached at a different address than it publishes |
| `--state DIR` | where state files live (default `data/bots`) |
| `--speed N` | compress the waiting N times; a week in an afternoon |
| `--visits N`, `--once` | stop after N visits, starting immediately |
| `--seed N` | fix the RNG for a reproducible run |
| `--explain` | print the schedule and briefing, and exit |

`--speed` scales **only** the waiting. Every rate, distribution and ordering is
the one the persona asked for, and account recycling is scaled with it, so
`--speed 300` will show you days of a swarm's life in a few minutes.

## On disk

| path | what | committed |
|---|---|---|
| `personas/*.yml` | the bots you have written | yes |
| `config/bot-categories.yml` | what each category is | yes |
| `data/bots/<name>.json` | one bot's seed phrase and state | no |
| `data/bots/vouchers.json` | the introducer accounts' seeds | no |

Both files under `data/` hold seed phrases and are written `0600`. `data/` is
gitignored. These are throwaway accounts with no recovery, so never sign
anything you care about into a bot's seed.

A bot's state file is also where its history lives: its sequence counter, what
it has already reacted to, and the seed phrase of every account it has
abandoned — so you can still log into a retired scammer from the login screen
and look at what it did.

**Deleting a state file does not delete the account**, it strands it. The bot
starts fresh with a new key on the next run, and the old one stays in the chain
with whatever reputation it earned, which is a fair way to simulate an
abandoned account but rarely what you meant.

## When something looks wrong

**"no vouchers configured; this account stays invisible"** — run `bin/vouch`.

**Nothing in the room, and no errors.** The bots are probably asleep. Check a
log for `away in 11.8h`, and use `--speed` if you do not want to wait.

**Bots post but you cannot see them in the browser.** Expected: you have not
rated any of them. Friend one, or turn on `show_unrated` in your own profile.

**"signature did not verify" on login** — `--origin` does not match the
server's configured `origin`. The origin travels inside the signed payload, so
it has to be the URL the server publishes, not the one you dialled.

**"the bot would acknowledge records nobody else has"** — this checkout's
genesis is not the one the server is running. Wrong branch, or a server built
against a different genesis.

**Everything says `llm: ... Errno::ECONNREFUSED`** — no model server. Start
one, or switch the persona to `brain: scripted`.
