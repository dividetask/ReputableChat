# Reputation

Reputation is **subjective**. There is no global reputation. Every number here
is one viewer's view of the network, calculated on that viewer's own machine
from their own ratings and other people's published ones. Two clients may differ
in the last decimal place and that is not a bug — it is what "your view of the
network" means.

Implementation: `lib/reputable_chat/reputation/` (Ruby, reference) and
`public/js/reputation.js` (JavaScript, what actually runs). Parameters live in
`config/reputation.yml`.

## Direct ratings

A **rating** is what one person gives another; a **reputation** is what a
viewer calculates from their own rating and everybody else's. Three actions
move a rating:

| action | effect |
|---|---|
| friend | +0.5 |
| positive emote on a message | net vote count, through the curve below |
| report | −1, absolute |

A rating is clamped to −1..+1. Friending plus a maxed-out curve reaches exactly
+1.

**A report is absolute within one rater.** Reporting someone makes that rater's
rating −1 regardless of how many of the target's messages they previously liked.

**A report is not absolute across raters.** At aggregation it is just −1 in the
mean, so roughly three friendships at the same depth outvote it. This is
deliberate: making reports unoutvoteable would let a single malicious contact
you rated +0.001 permanently hide anyone from you, with no way for the rest of
your network to overrule them.

## The vote curve

```
value(x) = sign(x) * min(cap, A*x² + B*|x|)
```

Quadratic, so the first few emotes are nearly weightless and later ones bite
progressively harder. Odd-symmetric, so negative emotes mirror positive ones.

Defaults: `A = 0.0004`, `B = 0`, `cap = 0.5`.

| net votes | 1 | 2 | 3 | 10 | 20 | 30 | 36 |
|---|---|---|---|---|---|---|---|
| value | 0.0004 | 0.0016 | 0.0036 | 0.04 | 0.16 | 0.36 | cap |

`B` exists but defaults to 0. `curve(2)/curve(1)` is `(4A+2B)/(A+B)`, which is 4
at `B = 0` and falls toward 2 as `B` grows — and that ratio is the safety margin
on the report rule below, so raising `B` eats it.

The sign must be applied to the magnitude, not fed through the polynomial:
`A*x²` is positive for negative `x`, so a negative count would otherwise read as
a positive one.

## The ladder

```
weight(d) = (1 - k) * k^d          k = 0.1, hops 0..7
```

| hops | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| weight | 0.9 | 0.09 | 0.009 | 0.0009 | 9e-5 | 9e-6 | 9e-7 | 9e-8 |

These sum to 1, so a reputation is always inside −1..+1 with no clamping. Depth
0 takes `1-k` of the total, which means **the ceiling for anyone you have never
personally rated is exactly `k`** — 0.1. That is intended: strangers are meant
to sit in the Tolerated band, and the pressure that creates to friend people or
like their messages is the point of the app.

A reputation is the weighted sum over depths of the mean rating at that
depth. The mean is taken over **the people who actually rated the target** at
that depth, not over everyone at that depth with non-raters counted as zero.

## Traversal

Breadth-first from the viewer, gated at every hop by `gate.min_rating`.
Reaching hop `d` means every link on the path was rated above the gate by the
person one step closer in; a single non-positive link and the whole branch
beyond it goes unread.

The walk stops at **hop 2**, and the fourth term comes from other people's
arithmetic rather than from walking further. `max_accounts` still bounds it, and
still has to: a positive-only graph branches, so even two hops is 900 people at
30 ratings each and 22,500 at 150.

### Why the walk stops at two

A forward walk is quadratic in ratings-per-person, so hop 3 is where it stops
being something a phone can do. At 30 ratings each that is 27,000 people; at a
more realistic 150 it is 3.4 million. There is no version of "fetch all of
them" that works.

So depth 3 is filled in rather than walked. Every attestation publishes its
author's own calculated reputations out to `attestation.published_hops`, and a
viewer takes the mean of those derived reputations from the people at hop 2:

```
reputation = 0.9    * your own rating
           + 0.09   * mean rating published by the people you rated
           + 0.009  * mean rating published by the people they rated
           + 0.0009 * mean REPUTATION published by the people they rated
```

The first three terms read ratings. The fourth reads a summary, and
trusts the people at hop 2 to have done their own arithmetic honestly — which
is the same thing the third term already trusts them for.

Those weights sum to 0.9999 rather than 1. Under-summing is harmless: a
reputation is still inside −1..+1 with no clamping. The old hops 4 to 7
are simply gone, and their 0.0001 with them.

### What the fourth term is for

Almost nothing, most of the time — and that is the point. It is bounded by
0.0009, while `trusted_at` is 0.01, so **the fourth term can never make anyone
Trusted on its own.** Eleven times its maximum would be needed.

What it can do is move someone from exactly 0 to slightly above it. An account
nobody within two hops has rated sits at precisely zero and is therefore
Blocked — that is the sybil defense — and this is the one thing that can lift
them into Tolerated without anyone nearby vouching for them. It exists to
rescue the well-regarded stranger, and it is deliberately too weak to do
anything else.

It cuts the other way too, though only just. Someone whose first three terms
come to between 0 and 0.0009 can be pushed back under the line by a
negative fourth term. That is a real bucket change, from Tolerated to Blocked,
on a hair's-breadth reputation.

### What it costs, and what it does not buy

A derived reputation is reached through its author's own configuration, and
nothing published says what that configuration was. A reader reaching for the
cache has run out of its own reach, so it either takes the number or leaves it;
knowing the author's parameters would give it nothing it could act on, and
publishing them would tell everyone the settings a particular reader scores
under.

There is also mild double counting. A hop-2 person's derived reputation for the
target is 90% their own rating of it, which the third term already counted at
0.009. So the fourth term re-counts their direct opinion at 0.00081, and only
the remainder is genuinely news from further out.

And the cache is not free to publish. An attestation carrying derived
reputations for everyone within three hops is thousands of entries, and a viewer
fetches hundreds of attestations. That is the cost of not walking hop 3
directly, and it only stays reasonable while the published set does. It will
need bounding — Merkle proofs over the derived map, so a reader can fetch the
few entries it wants and verify them against the signed root, are the known way
to do it without asking the server to be trusted about what it left out.

### Sampling

`max_accounts` truncates the walk. On a large graph that means the mean at
depth 2 is taken over whichever people breadth-first order happened to reach
first, which is arbitrary and differs between clients for no principled reason.
Deterministic selection — nearest first, then by pubkey — at least makes two
clients with the same view agree.

Each person is counted once, at their **shortest** distance. Someone reachable
by two paths does not get to vote twice. Nobody contributes to their own
reputation.

Your rating of someone is a **gate, not a multiplier**. A contact you rated
+0.001 carries exactly the same weight in judging strangers as one you friended
and maxed out.

## The three buckets

Computed once at login, then used for the session.

| bucket | reputation |
|---|---|
| Trusted | >= `trusted_at` (0.01) |
| Tolerated | > 0 |
| Blocked | <= 0 |

**Blocked unless strictly above zero.** This covers the unrated (who sit at
exactly 0) and anyone the network is net-negative on.

Because hop 2 tops out at 0.009, just under `trusted_at`, **Trusted means you
rated them or someone you rated did**. Nobody at three hops or beyond reaches
it however well-regarded they are. That sits right on the boundary, so it flips
if `k` moves.

`show_unrated` lets a user opt into seeing users nobody has rated — necessary
for anyone willing to wade through the muck and vouch for newcomers. It surfaces
only the unrated, never the net-negative.

That rule exists because of a real bug in an earlier design. When visibility was
purely threshold-based, an unrated spammer sat at 0 and was hidden — but the
same spammer *reported* from two hops out came to −0.009, which is above any
sane hide threshold, so reporting them made them **more** visible. The further
away the reporter, the stronger the effect. Sign-based visibility removes the
whole class of problem.

## Sessions

Reputations are calculated once at login, everyone is sorted into a bucket, and
the numbers are discarded. For the rest of the session the buckets are what
matter.

The session holds a **snapshot** of the graph, not a live view. Freezing only
the walk is not enough: a rating published later by someone already inside it
would still leak through. So further likes and dislikes — yours or anyone
else's — move nobody until the next login.

Reports are the exception, since waiting a whole session to act on one defeats
the point. `session.report_blocks` maps hops to how many reporters at that
distance are needed:

| reporter is | reporters needed |
|---|---|
| you | 1 |
| 1 hop away | 1 |
| 2 hops away | 2 |
| 3+ hops | no immediate effect |

Because the reputation is gone by then, this is a flat count rather than a
weighing. That makes it **stricter than the login-time maths**, so someone
blocked this way may reappear at the next login once the report is averaged
against everything else. That is expected, not a bug.

`Session#explain` re-derives the reputation and itemises it — which hop, who
rated, what each contributed. It is defined in terms of the same `breakdown`
that produces the reputation, so what the UI explains cannot drift from what it
acts on.

## The coupling — read before retuning anything

The rule "a report from three steps out hides someone you have liked once, but
two of your likes outweigh it" is a constraint tying the curve to the ladder:

```
curve(1)  <  k³  <  curve(2)
   A      < 0.000729 <  4A
```

which pins `A` to the window **(0.00025, 0.001)**. The arithmetic is unchanged
now that depth 3 is the derived term rather than a walked hop, but it means
something different: one like of yours is outweighed by your two-hop
neighbourhood collectively estimating someone at −1, and two likes outweigh it.
It is a statement about a summary rather than about a single distant reporter.
At `A = 0.0004` the margins are symmetric: one like lands 0.00054 below the line
and two likes 0.00054 above it, each 60% of the report's weight.

This means **`k`, `max_hops`, `A`, `B` and `cap` are no longer independent**.
Changing any one of them can silently flip a distant report from hiding someone
to not. `spec/reputation_rules_spec.rb` asserts the rule directly and fails the
build if a retune breaks it — if that test goes red after a config change, the
config change is the thing to reconsider.

`rake curve` prints the current curve, ladder and window.

## Precision

All arithmetic is decimal — `BigDecimal` in Ruby, BigInt fixed-point at scale 18
in JavaScript. Not for cross-client agreement, which is not required, but
because visibility turns on `effective > 0`: in binary floating point, values
that should cancel to exactly zero land on ±1e-17 and flip people across that
line at random.

Scale interacts with `max_hops`. A single like at depth 7 is ~1e-12, so too
small a scale rounds deep contributions away and makes the deeper traversal
wasted work.

## Configuration layering

Three layers resolve in order: a user's pinned value, the current server
default, the hardcoded fallback. A key that is absent or blank in a user's
settings tracks the default, so editing `config/reputation.yml` moves every user
who never pinned that setting and nobody who did.

An attestation carries **ratings**, not the actions behind them. `friend`,
`reported` and `net_votes` stay in the author's vault; what gets published is
the rating they came to.

Publishing the actions instead would ask every reader to apply *their own*
curve to *somebody else's* counts, which computes a number neither of them
holds — there is no answer to whose curve a stranger's `net_votes` should go
through. The author runs their own curve once and publishes the rating, so the
curve is an authoring parameter rather than a reading one.

The cost is that a published rating goes stale when its author retunes, where
an action count never would. The author's next attestation carries the retuned
ratings. See **Derived cache** in [glossary.md](glossary.md).
