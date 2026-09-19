// Derives a key the way the BROWSER does -- through public/js/identity.js
// itself, not a copy of it -- so the Ruby bot client can be diffed against it.
// See spec/bot_identity_spec.rb.
//
// Two things the browser supplies are stubbed: the wordlist fetch, and the
// global that the vendored hash-wasm script tag sets.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const root = new URL("..", import.meta.url);

globalThis.hashwasm = require("../public/js/vendor-argon2.umd.min.js");

const wordlist = readFileSync(new URL("config/bip39-english.txt", root), "utf8");
globalThis.fetch = async (url) => {
  if (String(url) !== "/wordlist.txt") throw new Error(`unexpected fetch: ${url}`);
  return { ok: true, text: async () => wordlist };
};

const { deriveFromSeed } = await import("../public/js/identity.js");

const input = JSON.parse(readFileSync(0, "utf8"));
for (const phrase of input.phrases) {
  const { pubkey } = await deriveFromSeed(phrase, input.kdf);
  console.log(pubkey);
}
