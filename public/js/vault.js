// The private vault: settings, the voted list, and the friend and report lists,
// encrypted before they leave the browser.
//
// The identity key cannot do this. Ed25519 has no encryption operation, and the
// signing key is a non-extractable WebCrypto key whose bytes can never be read
// back -- which is the property the whole key storage design is built on, not an
// obstacle to route around. So the vault gets a key of its own.
//
// It comes from the Argon2id output the identity key is already derived from,
// run through HKDF under `seed.kdf.vault_domain`. One expensive derivation, two
// keys. Deriving it with a second Argon2id pass would double the wait at login
// for no security a domain-separated HKDF does not already give, and changing
// how the IDENTITY key is derived is off the table entirely -- that would
// strand every existing account.

const GCM_IV_BYTES = 12;

export function b64url(bytes) {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(text) {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

// Non-extractable, like the signing key: the page can use it and cannot read it.
export async function deriveKey(rawSeed, domain) {
  const base = await crypto.subtle.importKey("raw", rawSeed, "HKDF", false, ["deriveKey"]);

  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      // The domain separation is the `info`, so an empty salt is correct rather
      // than lazy -- the input is already the output of a memory-hard KDF over
      // its own domain.
      salt: new Uint8Array(0),
      info: new TextEncoder().encode(domain),
    },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

// A fresh nonce every time. Reusing one under AES-GCM does not merely weaken
// the ciphertext, it leaks the XOR of the two plaintexts and breaks the
// authentication -- and a vault is written on every change.
export async function seal(key, value) {
  const iv = crypto.getRandomValues(new Uint8Array(GCM_IV_BYTES));
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext);

  return { ciphertext: b64url(sealed), iv: b64url(iv) };
}

// Returns null rather than throwing on anything that does not open: a vault
// that will not decrypt is a vault from a different seed or a corrupted one,
// and neither is worth losing the session over.
export async function unseal(key, { ciphertext, iv }) {
  try {
    const opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromB64url(iv) }, key, fromB64url(ciphertext),
    );
    return JSON.parse(new TextDecoder().decode(opened));
  } catch {
    return null;
  }
}

// Merging a vault that was refused.
//
// Two signed-in devices both push, and the second is rejected because its
// revision is not newer. That rejection means MERGE, never retry. Taking the
// server's copy drops everything this device did since its last push; bumping
// the revision and overwriting drops what the other device did. Both are easy
// to write by accident, because a conflict looks like something to retry.
//
// The lists resolve in different directions, and each direction is the one that
// cannot lose information:
//
//   voted    union -- a vote is a fact about something that happened, and a
//            fact recorded on either device happened.
//   settings the local copy, since this device is the one writing now.
//
// Entries added here later follow the rule in docs/project/identity.md:
// earliest wins for sightings, latest for friends and blocks.
export function merge(mine, theirs) {
  const before = theirs || {};

  return {
    ...before,
    ...mine,
    voted: [...new Set([...(before.voted || []), ...(mine.voted || [])])],
  };
}
