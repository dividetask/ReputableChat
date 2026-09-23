// Client-side reputation. Mirrors lib/reputable_chat/reputation/; the rules and
// their reasoning are in docs/project/reputation.md.
//
// BigInt fixed-point rather than float: the Blocked line is `effective > 0`,
// and float values that should cancel to zero land on +/-1e-17 instead.

const SCALE_DIGITS = 18;
export const SCALE = 10n ** BigInt(SCALE_DIGITS);

export function toFixed(value) {
  const text = String(value).trim();
  const negative = text.startsWith("-");
  const [whole, fraction = ""] = text.replace(/^[-+]/, "").split(".");
  const padded = (fraction + "0".repeat(SCALE_DIGITS)).slice(0, SCALE_DIGITS);
  const magnitude = BigInt(whole || "0") * SCALE + BigInt(padded || "0");

  return negative ? -magnitude : magnitude;
}

export function toNumber(fixed) {
  return Number(fixed) / Number(SCALE);
}

// The form a score travels in. Never a float and never exponent notation: what
// is published is signed, and canonical serialization refuses a float outright
// because it has no single textual form across languages.
export function toDecimal(fixed) {
  const negative = fixed < 0n;
  const magnitude = negative ? -fixed : fixed;
  const whole = magnitude / SCALE;
  const fraction = (magnitude % SCALE).toString().padStart(SCALE_DIGITS, "0").replace(/0+$/, "");

  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

const mul = (a, b) => (a * b) / SCALE;
const clamp = (v) => (v > SCALE ? SCALE : v < -SCALE ? -SCALE : v);

export class Reputation {
  constructor(config) {
    const curve = config.vote_curve;

    this.a = toFixed(curve.a);
    this.b = toFixed(curve.b);
    this.cap = toFixed(curve.cap);
    this.k = toFixed(config.constants.k);
    this.maxHops = Number(config.ladder.max_hops);
    this.maxConfigs = Number(config.ladder.max_configs);
    this.friendValue = toFixed(config.actions.friend.value);
    this.minRating = toFixed(config.gate.min_rating);
    this.visibleAbove = toFixed(config.display.visible_above);
    this.trustedAt = toFixed(config.display.trusted_at);
    this.showUnrated = Boolean(config.display.show_unrated);

    this.weights = [];
    let weight = SCALE - this.k; // (1 - k)
    for (let depth = 0; depth <= this.maxHops; depth++) {
      this.weights.push(weight);
      weight = mul(weight, this.k);
    }
  }

  // sign(x) * min(cap, A*x^2 + B*|x|). The sign is applied to the magnitude
  // rather than fed through the polynomial: A*x^2 is positive for negative x,
  // so a negative count would otherwise read as a positive one.
  curve(netVotes) {
    const net = Math.trunc(netVotes) || 0;
    if (net === 0) return 0n;

    const x = BigInt(Math.abs(net));
    let value = this.a * x * x + this.b * x;
    if (value > this.cap) value = this.cap;

    return net < 0 ? -value : value;
  }

  // Precedence: report, then friend, then cleared, then accumulated votes.
  //
  // A report is absolute within one rater: it overrides however many of the
  // target's comments that same rater liked. Across raters it is only -1 in
  // the mean, and so remains outvoteable. `cleared` pins someone to zero
  // however often they are emoted or replied to, before or after; friending is
  // deliberate and outranks it.
  // A published score is taken as it stands: the curve already ran in whoever
  // published it, so there is nothing left to compute. Actions only appear
  // here for the viewer's own entry, which is built from their vault.
  ratingValue(rating) {
    if (!rating) return null;
    if (rating.reputation !== undefined) return clamp(toFixed(rating.reputation));
    if (rating.reported) return -SCALE;

    const votes = this.curve(rating.net_votes || 0);
    if (rating.friend) return clamp(this.friendValue + votes);
    if (rating.cleared) return 0n;

    return clamp(votes);
  }

  // What this person's recommendations are worth, as distinct from what they
  // are worth. Defaults to full for anyone positive and none for anyone
  // blocked, so an attestation only carries an entry where it was overridden.
  multiplierOf(rating) {
    if (rating?.trust !== undefined && rating.trust !== null) return toFixed(rating.trust);

    return this.ratingValue(rating) > 0n ? SCALE : 0n;
  }

  // A report is the only thing that reaches exactly -1, so a published score
  // of -1 is a report. Actions are private; this is what survives of them.
  reportedBy(rating) {
    if (!rating) return false;
    if (rating.reputation !== undefined) return toFixed(rating.reputation) <= -SCALE;

    return Boolean(rating.reported);
  }

  // How much each person's recommendations are worth, compounded along the
  // path that reached them. A nought anywhere makes everything past it count
  // for nothing; a negative inverts it.
  trustTo(viewer, graph, depths) {
    const trust = new Map([[viewer, SCALE]]);

    for (const [rater] of [...depths].sort((a, b) => a[1] - b[1])) {
      const carried = trust.get(rater) ?? SCALE;
      for (const [subject, rating] of Object.entries(graph.ratingsBy(rater) || {})) {
        if (trust.has(subject)) continue;
        trust.set(subject, mul(carried, this.multiplierOf(rating)));
      }
    }
    return trust;
  }

  // Breadth-first, gated at every hop. Reaching a hop means every link on the
  // path was rated above the gate by the person one step closer in. Each
  // person is counted once, at their shortest distance. The walk also stops at
  // maxConfigs -- a positive-only graph still branches, so seven hops is
  // unbounded in practice.
  reachableDepths(viewer, graph) {
    const depths = new Map([[viewer, 0]]);
    let frontier = [viewer];

    for (let depth = 0; depth < this.maxHops; depth++) {
      const next = [];

      for (const rater of frontier) {
        for (const [subject, rating] of Object.entries(graph.ratingsBy(rater) || {})) {
          if (depths.size >= this.maxConfigs) return depths;
          if (depths.has(subject)) continue;
          if (this.ratingValue(rating) <= this.minRating) continue;

          depths.set(subject, depth + 1);
          next.push(subject);
        }
      }

      if (!next.length) break;
      frontier = next;
    }

    return depths;
  }

  // `depths` lets a caller supply a walk taken earlier; a Session passes the
  // one from login so later changes stay invisible.
  effective(viewer, target, graph, depths = null) {
    return this.breakdown(viewer, target, graph, depths).effective;
  }

  // The same sum, itemised: which hop, who rated, what each contributed.
  // `effective` is defined in terms of this so the number the UI explains
  // cannot drift from the number it acts on.
  breakdown(viewer, target, graph, depths = null) {
    if (viewer === target) return { effective: 0n, levels: [] };

    const walk = depths || this.reachableDepths(viewer, graph);
    // Recomputed per call rather than cached on the instance: one Reputation
    // answers for whatever viewer it is asked about, and a cache that did not
    // know that would hand one person's trust to another.
    const trust = this.trustTo(viewer, graph, walk);
    const byDepth = new Map();

    for (const [rater, depth] of walk) {
      if (rater === target) continue;

      const rating = graph.rating(rater, target);
      const value = this.ratingValue(rating);
      if (value === null) continue;

      // What a rater says is worth what the path to them is worth.
      const weighted = mul(value, trust.get(rater) ?? SCALE);

      if (!byDepth.has(depth)) byDepth.set(depth, []);
      byDepth.get(depth).push({
        pubkey: rater, rating: weighted, reported: this.reportedBy(rating),
      });
    }

    const levels = [];
    let total = 0n;

    for (const depth of [...byDepth.keys()].sort((a, b) => a - b)) {
      const raters = byDepth.get(depth);
      // Mean over the people who actually rated the target at this depth, not
      // over everyone at this depth with non-raters counted as zero.
      const mean = raters.reduce((sum, r) => sum + r.rating, 0n) / BigInt(raters.length);
      const weight = this.weights[depth];
      const contribution = mul(weight, mean);

      total += contribution;
      levels.push({ hops: depth, weight, raters, mean, contribution });
    }

    return { effective: total, levels };
  }

  rated(target, walk, graph) {
    for (const [rater] of walk) {
      if (rater !== target && graph.rating(rater, target)) return true;
    }
    return false;
  }

  // Blocked at or below zero -- that covers the unrated (who sit at exactly
  // zero) and anyone the network is net-negative on, and it is what stops a
  // distant report from making someone MORE visible than staying unrated
  // would. showUnrated opts into seeing the unrated; it never reveals the
  // net-negative.
  classify(effective, rated = true) {
    if (!rated && this.showUnrated && effective === 0n) return "tolerated";
    if (effective <= this.visibleAbove) return "blocked";
    if (effective < this.trustedAt) return "tolerated";
    return "trusted";
  }

  bucket(viewer, target, graph, depths = null) {
    const walk = depths || this.reachableDepths(viewer, graph);

    return this.classify(this.effective(viewer, target, graph, walk),
                         this.rated(target, walk, graph));
  }
}

// Holds verified configs keyed by pubkey. Only signature-checked ratings ever
// reach here -- see app.js.
export class Graph {
  constructor() {
    this.configs = new Map();
  }

  add(pubkey, ratings) {
    this.configs.set(pubkey, ratings || {});
  }

  // A fixed copy of what the walk reached. Freezing only the walk is not
  // enough -- a rating published later by someone already inside it would
  // still leak through.
  snapshot(pubkeys) {
    const frozen = new Graph();
    for (const pubkey of pubkeys) frozen.add(pubkey, { ...this.ratingsBy(pubkey) });
    return frozen;
  }

  has(pubkey) {
    return this.configs.has(pubkey);
  }

  ratingsBy(pubkey) {
    return this.configs.get(pubkey) || {};
  }

  rating(pubkey, target) {
    return this.ratingsBy(pubkey)[target] || null;
  }
}
