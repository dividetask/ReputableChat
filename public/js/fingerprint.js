// A hash of the parameters a score was computed under. Mirrors
// lib/reputable_chat/reputation/fingerprint.rb.
//
// An attestation publishes its author's calculated scores as a cache, and that
// cache only means anything to a reader whose parameters match -- reputation
// is subjective and configuration is per-user. Comparing fingerprints is how a
// reader decides whether to use the cache or do the walk themselves.

import * as canonical from "./canonical.js";

export const DOMAIN = "reputablechat:params:v1";

// Every key that can change a computed score, and nothing else. Seed and
// session keys are absent deliberately: they cannot move a number, so
// including them would invalidate caches for no reason.
export const SCORING_KEYS = [
  "precision.scale",
  "constants.k",
  "ladder.max_hops",
  "ladder.max_accounts",
  "gate.min_rating",
  "actions.friend.value",
  "actions.report.value",
  "vote_curve.cap",
  "vote_curve.a",
  "vote_curve.b",
  "display.visible_above",
  "display.trusted_at",
  "display.show_unrated",
];

// Values are stringified so a YAML "0.1" and a JSON 0.1 cannot fingerprint
// differently for the same setting.
export function values(lookup) {
  const out = {};
  for (const key of SCORING_KEYS) out[key] = String(lookup(key));
  return out;
}

export async function of(lookup) {
  return digest(values(lookup));
}

export async function digest(map) {
  const input = new TextEncoder().encode(`${DOMAIN}\n${canonical.dump(map)}`);
  const hashed = await crypto.subtle.digest("SHA-256", input);
  return [...new Uint8Array(hashed)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
