// Deterministic serialization for anything that gets signed.
//
// The browser signs bytes and the server verifies bytes, so both sides have to
// produce byte-identical output for the same object or every signature fails.
// This mirrors lib/reputable_chat/crypto/canonical.rb -- the two must be
// changed together, and spec/canonical_parity_spec.rb checks that they agree.

function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);

  if (value && typeof value === "object") {
    const out = {};
    // Ruby sorts by byte order and JS by UTF-16 code unit. Every key we sign is
    // ASCII (fixed field names, or base64url public keys), where the two agree.
    for (const key of Object.keys(value).sort()) out[key] = normalize(value[key]);
    return out;
  }

  if (typeof value === "number" && !Number.isInteger(value)) {
    // Floats have no single textual form across languages. Anything signed
    // must arrive as a string or an integer.
    throw new Error(`refusing to canonicalize a float: ${value}`);
  }

  return value;
}

export function dump(object) {
  return JSON.stringify(normalize(object));
}

export function bytes(object) {
  return new TextEncoder().encode(dump(object));
}
