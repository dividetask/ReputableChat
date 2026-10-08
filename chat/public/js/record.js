// A record's identity on the chain: the hash of its canonical payload and its
// signature together. Mirrors lib/reputable_chat/cryptography/record.rb --
// spec/record_parity_spec.rb checks that they agree.

import * as canonical from "./canonical.js";

export const DOMAIN = "reputablechat:record:v1";
const SEPARATOR = "\n";
const HEX = /^[0-9a-f]{64}$/;

// Takes the canonical payload as a string wherever one is already to hand, so
// a blob the server handed back is hashed as the bytes it actually sent rather
// than as a re-serialization of them.
export async function digest(payload, signature) {
  const body = typeof payload === "string" ? payload : canonical.dump(payload);

  // The separators are unambiguous rather than conventional: canonical JSON
  // can never hold a raw newline, and base64url has none either, so exactly
  // one pair of strings produces any given hash input. Checked because the
  // claim is load-bearing.
  if (body.includes(SEPARATOR)) throw new Error("canonical payload contains a newline");
  if (String(signature).includes(SEPARATOR)) throw new Error("signature contains a newline");

  const input = new TextEncoder().encode([DOMAIN, body, signature].join(SEPARATOR));
  const hashed = await crypto.subtle.digest("SHA-256", input);

  return [...new Uint8Array(hashed)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function isValid(value) {
  return typeof value === "string" && HEX.test(value);
}
