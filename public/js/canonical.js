// Deterministic serialization for signed payloads. Must produce byte-identical
// output to lib/reputable_chat/crypto/canonical.rb or every signature fails;
// spec/canonical_parity_spec.rb checks that they agree.

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
