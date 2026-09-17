// One login's worth of reputation. Mirrors
// lib/reputable_chat/reputation/session.rb.
//
// Scores are computed once, everyone is sorted into trusted / tolerated /
// blocked, and the numbers discarded. For the rest of the session the buckets
// are what matter: further likes and dislikes, from anyone, move nobody until
// the next login. Reports are the exception, since waiting a whole session to
// act on one defeats the point.

export class Session {
  constructor(reputation, viewer, graph, reportBlocks) {
    this.reputation = reputation;
    this.viewer = viewer;
    this.depths = reputation.reachableDepths(viewer, graph);
    this.graph = graph.snapshot(this.depths.keys());
    this.buckets = new Map();
    this.reports = new Map();
    this.reportBlocks = new Map(
      Object.entries(reportBlocks || {}).map(([hops, needed]) => [Number(hops), Number(needed)]),
    );
  }

  build(candidates) {
    for (const pubkey of candidates) this.bucketOf(pubkey);
    return this;
  }

  // Always against the walk and the snapshot taken at login, never a fresh
  // one -- that is what makes other people's config changes invisible.
  bucketOf(pubkey) {
    if (!this.buckets.has(pubkey)) {
      this.buckets.set(pubkey, this.reputation.bucket(this.viewer, pubkey, this.graph, this.depths));
    }
    return this.buckets.get(pubkey);
  }

  visible(pubkey) {
    return this.bucketOf(pubkey) !== "blocked";
  }

  hopsTo(pubkey) {
    return pubkey === this.viewer ? 0 : this.depths.get(pubkey) ?? null;
  }

  in(bucket) {
    return [...this.buckets].filter(([, b]) => b === bucket).map(([pubkey]) => pubkey);
  }

  // Records a report seen during the session and blocks the subject if the
  // thresholds are met.
  //
  // The score is gone by now, so this cannot weigh the report against what is
  // already there -- it is a flat count of reporters at each distance. That
  // makes it stricter than the login-time maths, and someone blocked this way
  // may come back at the next login once the report is weighed properly.
  report(subject, reporter) {
    const hops = this.hopsTo(reporter);
    if (hops === null) return this.bucketOf(subject);

    if (!this.reports.has(subject)) this.reports.set(subject, new Map());
    this.reports.get(subject).set(reporter, hops);

    this.bucketOf(subject);
    if (this.blockedByReports(subject)) this.buckets.set(subject, "blocked");

    return this.buckets.get(subject);
  }

  reportersOf(subject) {
    return this.reports.get(subject) || new Map();
  }

  blockedByReports(subject) {
    const counts = new Map();
    for (const hops of this.reportersOf(subject).values()) {
      counts.set(hops, (counts.get(hops) || 0) + 1);
    }

    for (const [hops, needed] of this.reportBlocks) {
      if ((counts.get(hops) || 0) >= needed) return true;
    }
    return false;
  }

  // Itemised score for the recalculate view: who contributed what.
  explain(target) {
    const result = this.reputation.breakdown(this.viewer, target, this.graph, this.depths);

    return { ...result, bucket: this.bucketOf(target), reporters: this.reportersOf(target) };
  }
}
