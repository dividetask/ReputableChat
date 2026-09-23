// Identity: seed -> key -> signatures.
//
// The seed is turned into a key and dropped; it is never stored or sent. The
// private key is a NON-EXTRACTABLE WebCrypto key -- the reason for using
// WebCrypto over a JS Ed25519 library: it can sign, but its bytes cannot be
// read back out. Origin isolation keeps other sites away from it; the CSP in
// app.rb keeps injected script from using it.

import * as canonical from "./canonical.js";
import * as seed from "./seed.js";

const DB_NAME = "reputablechat";
const STORE = "identity";
const KEY_ID = "current";

// DER prefix for a PKCS8-wrapped Ed25519 private key, followed by 32 raw bytes.
const PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

export function b64url(bytes) {
  let binary = "";
  for (const b of new Uint8Array(bytes)) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(text) {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

// Memory-hard by necessity. A usernameless login has nothing to salt with, so
// an attacker grinds candidate seeds against every registered key at once --
// the cost of breaking SOME account is 2**80 / users, not 2**80. Argon2id is
// what makes each guess expensive enough for that to stay out of reach.
// Parameters come from the server's config so they can be raised later without
// invalidating anyone's identity, as long as `domain` stays put.
async function stretch(phrase, kdf) {
  if (!globalThis.hashwasm?.argon2id) throw new Error("argon2 did not load");

  return globalThis.hashwasm.argon2id({
    password: seed.normalize(phrase),
    salt: new TextEncoder().encode(kdf.domain),
    parallelism: kdf.parallelism,
    iterations: kdf.iterations,
    memorySize: kdf.memory_kib,
    hashLength: 32,
    outputType: "binary",
  });
}

// Imports once as extractable purely to read the public half out of the JWK,
// then re-imports the private key non-extractable and lets the first one go.
async function importKeypair(rawSeed) {
  const pkcs8 = new Uint8Array(PKCS8_PREFIX.length + 32);
  pkcs8.set(PKCS8_PREFIX, 0);
  pkcs8.set(rawSeed, PKCS8_PREFIX.length);

  const extractable = await crypto.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, ["sign"]);
  const jwk = await crypto.subtle.exportKey("jwk", extractable);

  const privateKey = await crypto.subtle.importKey(
    "jwk",
    { kty: "OKP", crv: "Ed25519", x: jwk.x, d: jwk.d },
    "Ed25519",
    false, // non-extractable: this is the point
    ["sign"],
  );

  return { privateKey, pubkey: jwk.x };
}

export async function deriveFromSeed(phrase, kdf) {
  const reason = await seed.validate(phrase, kdf.min_words);
  if (reason) throw new Error(reason);

  const rawSeed = await stretch(phrase, kdf);
  const identity = await importKeypair(rawSeed);
  rawSeed.fill(0);

  return identity;
}

// --- persistence -------------------------------------------------------
//
// A CryptoKey survives structured cloning, so the non-extractable key can live
// in IndexedDB across a page refresh without its bytes ever being exposed.
// Memory-only storage would die on every refresh, which is not a log out --
// this matches "stays until you log off" more literally.

function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function transact(db, mode, fn) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const request = fn(tx.objectStore(STORE));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function remember(identity) {
  const db = await openDb();
  await transact(db, "readwrite", (s) => s.put(identity, KEY_ID));
  db.close();
}

export async function recall() {
  const db = await openDb();
  const stored = await transact(db, "readonly", (s) => s.get(KEY_ID));
  db.close();
  return stored || null;
}

export async function forget() {
  const db = await openDb();
  await transact(db, "readwrite", (s) => s.delete(KEY_ID));
  db.close();
}

// --- signing -----------------------------------------------------------

export async function sign(identity, payload) {
  const signature = await crypto.subtle.sign("Ed25519", identity.privateKey, canonical.bytes(payload));
  return b64url(signature);
}

export const PURPOSE = {
  LOGIN: "reputablechat:login:v1",
  MESSAGE: "reputablechat:message:v1",
  CONFIG: "reputablechat:config:v1",
  PRIVATE_CONFIG: "reputablechat:private-config:v1",
  EMOTE: "reputablechat:emote:v1",
  IDENTITY: "reputablechat:identity:v1",
  ATTESTATION: "reputablechat:attestation:v1",
  ADJUSTMENT: "reputablechat:adjustment:v1",
  RELEASE: "reputablechat:release:v1",
  NOTICE: "reputablechat:notice:v1",
};

// These must match lib/reputable_chat/cryptography/payload.rb exactly.
//
// `note` is free text for a person reading the raw chain. Nothing here or in
// the server reads it, and nothing branches on it -- render it with
// textContent, never as markup, like any other text somebody else wrote.
export function loginPayload({ pubkey, nonce, origin, ts }) {
  return { purpose: PURPOSE.LOGIN, pubkey, nonce, origin, ts };
}

export function messagePayload({ author, room, seq, prev, body, ack, ts, replyTo = null, note = null }) {
  return { purpose: PURPOSE.MESSAGE, author, room, seq, prev, reply_to: replyTo, ack, note, ts, body };
}

export function configPayload({ pubkey, revision, profile, ratings, ts }) {
  return { purpose: PURPOSE.CONFIG, pubkey, revision, profile, ratings, ts };
}

export function emotePayload({ author, room, message, emote, ack, ts, note = null }) {
  return { purpose: PURPOSE.EMOTE, author, room, message, emote, ack, note, ts };
}

export function privateConfigPayload({ pubkey, revision, settings, voted, ts }) {
  return { purpose: PURPOSE.PRIVATE_CONFIG, pubkey, revision, settings, voted, ts };
}

// `master_pubkey` and `previous_pubkey` are placeholders for key rotation and
// are always null for now. They sit in the signed shape from the start because
// adding a field later changes the canonical bytes of every record, which
// invalidates every signature ever made.
export function identityPayload({
  pubkey, revision, handle, bio, icon, ack, ts,
  masterPubkey = null, previousPubkey = null, note = null,
}) {
  return {
    purpose: PURPOSE.IDENTITY, pubkey, revision, handle, bio, icon,
    master_pubkey: masterPubkey, previous_pubkey: previousPubkey, ack, note, ts,
  };
}

// `scores` maps a pubkey to { reputation, trust }, both decimal STRINGS:
// canonical serialization refuses floats, and the Blocked line is
// `reputation > 0`, which binary floating point cannot be trusted to land on.
// `derived` is a cache and carries the hash of the parameters it was computed
// under, so a reader can tell whether the numbers mean anything to them.
export function attestationPayload({ pubkey, revision, scores, derived, ack, ts, note = null }) {
  return { purpose: PURPOSE.ATTESTATION, pubkey, revision, scores, derived, ack, note, ts };
}

export function adjustmentPayload({
  pubkey, baseRevision, seq, target, reputation, trust, ack, ts, note = null,
}) {
  return {
    purpose: PURPOSE.ADJUSTMENT, pubkey, base_revision: baseRevision, seq,
    target, reputation, trust, ack, note, ts,
  };
}

// `supersedes` is the notice this one replaces, or null. A correction is a new
// record pointing at the old one, never an edit -- a mutated record no longer
// matches its signature, and the point of a notice is that what was said is
// still there to be checked.
export function noticePayload({
  publisher, revision, kind, title, body, ack, ts, supersedes = null, note = null,
}) {
  return {
    purpose: PURPOSE.NOTICE, publisher, revision, kind, title, body,
    supersedes, ack, note, ts,
  };
}

export function releasePayload({ publisher, revision, label, files, notes, ack, ts, note = null }) {
  return { purpose: PURPOSE.RELEASE, publisher, revision, label, files, notes, ack, note, ts };
}

// Verifies a blob the server handed back against a public key.
export async function verifyBlob(pubkey, blob) {
  try {
    const key = await crypto.subtle.importKey(
      "jwk", { kty: "OKP", crv: "Ed25519", x: pubkey }, "Ed25519", false, ["verify"],
    );
    return await crypto.subtle.verify(
      "Ed25519", key, fromB64url(blob.signature), new TextEncoder().encode(blob.payload),
    );
  } catch {
    return false;
  }
}
