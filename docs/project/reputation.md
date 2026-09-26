# Reputation

Reputation is **subjective**. There is no global reputation. Reputation is always based upon the viewer's perspective, calculated from their own ratings and other people's published ones.

Implementation: `lib/reputable_chat/reputation/` (Ruby) and `public/js/reputation.js` (JavaScript). Parameters live in `config/reputation.yml`.

## Direct ratings

**Rating** is what one person gives another; **reputation** is what a viewer calculates from their own rating and everybody else's. Three actions move a rating:

| action | effect |
|---|---|
| friend | +0.5 |
| positive reaction to a message | net count of positive and negative reactions, through the curve below |
| report | −1, absolute |

Friending plus a maxed-out curve reaches exactly +1, the most a rating can be.

**A report is absolute within one rater.** Reporting someone makes that rater's rating −1 regardless of how many of the target's messages they previously liked.

**A report is not absolute across raters.** At aggregation it is just −1 in the mean, so roughly three friendships at the same depth outvote it. This is deliberate: making reports unoutvoteable would let a single malicious contact you rated +0.001 permanently hide anyone from you, with no way for the rest of your network to overrule them.

**These are the default values and can be overwritten by a user's config file.**

## The vote curve

```
value(x) = sign(x) * min(cap, A*x² + B*|x|)
```

Quadratic, so the first few reactions are nearly weightless and later ones bite progressively harder. Odd-symmetric, so negative reactions mirror positive ones.

Defaults: `A = 0.0004`, `B = 0`, `cap = 0.5`.

| net votes | 1 | 2 | 3 | 10 | 20 | 30 | 36 |
|---|---|---|---|---|---|---|---|
| value | 0.0004 | 0.0016 | 0.0036 | 0.04 | 0.16 | 0.36 | cap |

## The ladder

```
weight(d) = (1 - k) * k^d          k = 0.1, hops 0..7
```

| hops | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| weight | 0.9 | 0.09 | 0.009 | 0.0009 | 9e-5 | 9e-6 | 9e-7 | 9e-8 |

These sum to 1, so a reputation is always inside −1..+1 with no clamping. Depth 0 takes `1-k` of the total, which means the ceiling for anyone you have never personally rated is exactly `k` — 0.1.

Reputation is the weighted sum over depths of the mean rating at that depth. The mean is taken over the people who actually rated the target at that depth, not over everyone at that depth with non-raters counted as zero.

## Traversal

Breadth-first from the viewer, gated at every hop by `gate.min_rating`. Reaching hop `d` means every link on the path was rated above the gate by the person one step closer in; a single non-positive link and the whole branch beyond it goes unread.

The walk goes out to `ladder.max_hops` (7) and stops early once it has reached `ladder.max_accounts` (5,000), whichever comes first. On a small network it may reach every hop; on a large one `max_accounts` is the limit that bites.

### When the walk is cut short

If `max_accounts` is reached partway through a hop, the accounts reached so far in that hop are kept and the rest are not read. Which ones make it depends on traversal order: nearest first, then the order raters and their ratings are visited.

Each person is counted once, at their **shortest** distance. Someone reachable by two paths does not get to vote twice. Nobody contributes to their own reputation.

Your rating of someone is a **gate, not a multiplier**. A contact you rated +0.001 carries exactly the same weight in judging strangers as one you friended and maxed out.

### The derived cache

Attestations may carry `derived`, the author's own calculated reputations. These are used whenever `max_accounts` or `max_hops` is reached and added to the sum as though they were the next hop out. They will use the author's formulas which may differ from the current user's formulas.

## The three buckets

Computed once at login, then used for the session.

| bucket | reputation |
|---|---|
| Trusted | >= `trusted_at` (0.01) |
| Tolerated | > 0 |
| Blocked | <= 0 |

**Blocked unless strictly above zero.** This covers the unrated (who sit at exactly 0) and anyone the network is net-negative on.

Because hop 2 tops out at 0.009, just under `trusted_at`, **Trusted means you rated them or someone you rated did**. Nobody at three hops or beyond reaches it however well-regarded they are. That sits right on the boundary, so it flips if `k` moves.

`show_unrated` lets a user opt into seeing users nobody has rated — necessary for anyone willing to wade through the muck and vouch for newcomers. It surfaces only the unrated, never the net-negative.

That rule exists for those willing to do the work of wading through the spam to find honest users and give them a chance to join the network. We will also allow other ways to join the network such as having a automated user request email verification and/or captcha completion and give a small rating to those who complete it. Users may choose to set the trust value for the automated user to zero if they find the verification method too prone to abuse.

## Sessions

Reputations are calculated by the client once at login, everyone is sorted into a bucket, and the numbers are discarded. For the rest of the session the buckets are what matter.

The session holds a **snapshot** of the graph, not a live view. Freezing only the walk is not enough: a rating published later by someone already inside it would still leak through. So further likes and dislikes — yours or anyone else's — move nobody until the next login or recalculation is requested (the later is not yet implemented).

Reports are the exception, since waiting a whole session to act on one defeats the point. The server, after detecting an influx of reports against a single user, will send an alert to all users indicating this. This report will include the offending user and a list of users reporting them. A second report will be issued if the offender hits a second threshold. The client will need to decide whether to listen to the report depending upon which bucket the reporters fall into. The reason for the second threshold is in case the first report was ignored due to not trusting the initial reporters.

`session.report_blocks` maps hops to how many tolerated or trusted reporters are needed to tentatively block a user. Tentatively blocking a user simply means blocking them for the remainder of the session. It is likely they will remain blocked next session, but until their reputation is recalculated we cannot know for certain whether or not the block will remain.

`daily.report_blocks.initial` and `daily.report_blocks.secondary` are used by the server to determine whether or not to issue a report warning of poor behavior. Future versions will need additional safeguards to prevent malicious users from repeatedly reporting themselves with new unknown accounts and prematurely trigger the report feature before engaging in malicious behavior.

## Precision

All arithmetic is decimal — `BigDecimal` in Ruby, BigInt fixed-point at scale 18 in JavaScript. Not for cross-client agreement, which is not required, but because visibility turns on `effective > 0`: in binary floating point, values that should cancel to exactly zero land on ±1e-17 and flip people across that line at random.

Scale interacts with `max_hops`. A single like at depth 7 is ~1e-12, so too small a scale rounds deep contributions away and makes the deeper traversal wasted work.

## Configuration layering

Three layers resolve in order: a user's pinned value, the current server default, the hardcoded fallback. A key that is absent or blank in a user's settings tracks the default, so editing `config/reputation.yml` moves every user who never pinned that setting and nobody who did.

An attestation carries **ratings**, not the actions behind them. `friend`, `reported` and `net_votes` stay in the author's vault; what gets published is the rating they came to.

The cost is that a published rating goes stale when its author retunes, where an action count never would. The author's next attestation carries the retuned ratings. See **Derived cache** in [glossary.md](glossary.md).
