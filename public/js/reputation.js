// Client-side reputation.
//
// Reputation is subjective -- it is one viewer's view of the network, built
// from other people's published ratings -- so it is computed here rather than
// on the server, and two clients are free to differ in the last decimal place.
//
// Arithmetic is BigInt fixed-point rather than float. Not for cross-client
// agreement, but because visibility is decided by `effective > 0`, and in
// binary floating point values that should cancel to exactly zero land on
// +/-1e-17 and flip people across that line at random.
//
// Mirrors lib/reputable_chat/reputation/. Rules, and why they are these rules,
// live in docs/project/reputation.md.

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

const mul = (a, b) => (a * b) / SCALE;

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

  // A report is absolute within one rater: it overrides however many of the
  // target's comments that same rater liked. Across raters it is only -1 in
  // the mean, and so remains outvoteable.
  ratingValue(rating) {
    if (!rating) return null;
    if (rating.reported) return -SCALE;

    let value = this.curve(rating.net_votes || 0);
    if (rating.friend) value += this.friendValue;

    if (value > SCALE) return SCALE;
    if (value < -SCALE) return -SCALE;
    return value;
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

  effective(viewer, target, graph) {
    if (viewer === target) return 0n;

    const depths = this.reachableDepths(viewer, graph);
    const byDepth = new Map();

    for (const [rater, depth] of depths) {
      if (rater === target) continue;

      const value = this.ratingValue(graph.rating(rater, target));
      if (value === null) continue;

      if (!byDepth.has(depth)) byDepth.set(depth, []);
      byDepth.get(depth).push(value);
    }

    let total = 0n;
    for (const [depth, values] of byDepth) {
      // Mean over the people who actually rated the target at this depth, not
      // over everyone at this depth with non-raters counted as zero.
      const mean = values.reduce((sum, v) => sum + v, 0n) / BigInt(values.length);
      total += mul(this.weights[depth], mean);
    }

    return total;
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

  bucket(viewer, target, graph) {
    return this.classify(this.effective(viewer, target, graph));
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
