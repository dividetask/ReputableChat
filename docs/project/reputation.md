# Reputation

Reputation is **subjective**. There is no global score. Every number here is one
viewer's view of the network, computed on that viewer's own machine from other
people's published ratings. Two clients may differ in the last decimal place and
that is not a bug — it is what "your view of the network" means.

Implementation: `lib/reputable_chat/reputation/` (Ruby, reference) and
`public/js/reputation.js` (JavaScript, what actually runs). Parameters live in
`config/reputation.yml`.

## Direct ratings

What one person publishes about another. Three actions:

| action | effect |
|---|---|
| friend | +0.5 |
| positive emote on a comment | net vote count, through the curve below |
| report | −1, absolute |

A rating is clamped to −1..+1. Friending plus a maxed-out curve reaches exactly
+1.

**A report is absolute within one rater.** Reporting someone makes that rater's
rating −1 regardless of how many of the target's comments they previously liked.

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
weight(d) = (1 - k) * k^d          k = 0.09, depths 0..7
```

| depth | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| weight | 0.91 | 0.0819 | 0.007371 | 0.00066339 | 5.97e-5 | 5.37e-6 | 4.84e-7 | 4.35e-8 |

These sum to 1, so an effective reputation is always inside −1..+1 with no
clamping. Depth 0 takes `1-k` of the total, which means **the ceiling for anyone
you have never personally rated is exactly `k`** — 0.09. That is intended:
strangers are meant to sit in the grey band, and the pressure that creates to
friend people or like their comments is the point of the app.

Effective reputation is the weighted sum over depths of the mean rating at that
depth. The mean is taken over **the people who actually rated the target** at
that depth, not over everyone at that depth with non-raters counted as zero.

## Traversal

Breadth-first from the viewer, gated at every hop by `parent_rating > 0`.
Reaching depth `d` means every link on the path was rated above zero by the
person one step closer in; a single non-positive link and the whole branch
beyond it goes unread.

Each person is counted once, at their **shortest** distance. Someone reachable
by two paths does not get to vote twice. Nobody contributes to their own score.

Your rating of someone is a **gate, not a multiplier**. A contact you rated
+0.001 carries exactly the same weight in judging strangers as one you friended
and maxed out. The multiplicative alternative is one line in the config:

```yaml
contribution: "rating * rater_trust * weight"
```

## Visibility

```
effective > 0        →  visible
effective < 0.05     →  grey (readable, marked untrusted)
otherwise            →  normal
```

**Hidden unless strictly above zero.** This covers the unrated (who sit at
exactly 0) and anyone the network is net-negative on.

That rule exists because of a real bug in an earlier design. When visibility was
purely threshold-based, an unrated spammer scored 0 and was hidden — but the
same spammer *reported* from two hops out scored −0.009, which is above any sane
hide threshold, so reporting them made them **more** visible. The further away
the reporter, the stronger the effect. Sign-based visibility removes the whole
class of problem.

## The coupling — read before retuning anything

The rule "a report from three steps out hides someone you have liked once, but
two of your likes outweigh it" is a constraint tying the curve to the ladder:

```
curve(1)  <  k³  <  curve(2)
   A      < 0.000729 <  4A
```

which pins `A` to the window **(0.000182, 0.000729)**. `A = 0.0004` sits near its
geometric centre, giving margins of 45% and 120% of the report's weight.

This means **`k`, `max_depth`, `A`, `B` and `cap` are no longer independent**.
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

Scale interacts with `max_depth`. A single like at depth 7 is ~1e-12, so too
small a scale rounds deep contributions away and makes the deeper traversal
wasted work.

## Configuration layering

Three layers resolve in order: a user's pinned value, the current server
default, the hardcoded fallback. A key that is absent or blank in a user's
config tracks the default, so editing `config/reputation.yml` moves every user
who never pinned that setting and nobody who did.

Because each reader applies their own config, published configs carry **actions**
(`friend`, `reported`, `net_votes`) rather than computed scores. A published
score would go stale the moment the curve was retuned and would need every user
in the network to re-sign. Action counts stay valid forever.
