// BIP39 wordlist encoding and checksum. Mirrors
// lib/reputable_chat/cryptography/seed.rb.

const BITS_PER_WORD = 11;
const CHECKSUM_BITS = 8;
export const MIN_WORDS = 8;

let WORDLIST = null;
let INDEX = null;

export async function loadWordlist(url = "/wordlist.txt") {
  if (WORDLIST) return WORDLIST;

  const response = await fetch(url);
  if (!response.ok) throw new Error("could not load the wordlist");

  WORDLIST = (await response.text()).split("\n").map((w) => w.trim()).filter(Boolean);
  if (WORDLIST.length !== 2048) throw new Error(`wordlist should hold 2048 words, got ${WORDLIST.length}`);

  INDEX = new Map(WORDLIST.map((word, i) => [word, i]));
  return WORDLIST;
}

// Both the checksum and the key derivation run over this form, so whitespace
// and capitalisation can never change an identity.
export function normalize(phrase) {
  return String(phrase || "").toLowerCase().trim().split(/\s+/).filter(Boolean).join(" ");
}

export function words(phrase) {
  const cleaned = normalize(phrase);
  return cleaned ? cleaned.split(" ") : [];
}

export function entropyBitsFor(wordCount) {
  return wordCount * BITS_PER_WORD - CHECKSUM_BITS;
}

// Returns null when the phrase is good, or a reason the UI can show.
// Distinguishing "not a word" from "checksum failed" matters: the first is a
// typo the user can see and fix, the second means a word is transposed or
// misremembered and they need to look harder.
export async function validate(phrase, minWords = MIN_WORDS) {
  await loadWordlist();
  const list = words(phrase);

  if (list.length < minWords) return `A seed needs at least ${minWords} words.`;

  const unknown = list.filter((w) => !INDEX.has(w));
  if (unknown.length) return `Not in the wordlist: ${unknown.join(", ")}`;

  if (!(await checksumOk(list))) return "Checksum failed — check for a mistyped or swapped word.";

  return null;
}

export async function isValid(phrase, minWords = MIN_WORDS) {
  return (await validate(phrase, minWords)) === null;
}

async function checksumOk(list) {
  const bits = list.map((w) => INDEX.get(w).toString(2).padStart(BITS_PER_WORD, "0")).join("");
  const entropy = bits.slice(0, -CHECKSUM_BITS);
  const provided = bits.slice(-CHECKSUM_BITS);

  return provided === (await checksumFor(entropy, list.length));
}

// The word count is hashed alongside the entropy so seeds of different lengths
// cannot collide once the entropy is byte-padded.
async function checksumFor(entropyBits, wordCount) {
  const padded = entropyBits.padEnd(Math.ceil(entropyBits.length / 8) * 8, "0");
  const entropyBytes = new Uint8Array(padded.length / 8);
  for (let i = 0; i < entropyBytes.length; i++) {
    entropyBytes[i] = parseInt(padded.slice(i * 8, i * 8 + 8), 2);
  }

  const input = new Uint8Array(1 + entropyBytes.length);
  input[0] = wordCount;
  input.set(entropyBytes, 1);

  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return digest[0].toString(2).padStart(8, "0").slice(0, CHECKSUM_BITS);
}

export async function generate(wordCount = MIN_WORDS) {
  await loadWordlist();

  const bitCount = entropyBitsFor(wordCount);
  const random = new Uint8Array(Math.ceil(bitCount / 8));
  crypto.getRandomValues(random);

  const entropy = Array.from(random)
    .map((b) => b.toString(2).padStart(8, "0"))
    .join("")
    .slice(0, bitCount);

  const bits = entropy + (await checksumFor(entropy, wordCount));
  const out = [];
  for (let i = 0; i < bits.length; i += BITS_PER_WORD) {
    out.push(WORDLIST[parseInt(bits.slice(i, i + BITS_PER_WORD), 2)]);
  }
  return out.join(" ");
}
