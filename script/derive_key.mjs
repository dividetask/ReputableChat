// The half of genesis generation that Ruby cannot do: Argon2id and Ed25519
// signing. Driven by script/generate_genesis.rb, which owns the canonical
// serialization and the payload shape.
//
// This runs the REAL client derivation -- the vendored hash-wasm build the
// browser loads, the same KDF parameters out of config/reputation.yml, and
// WebCrypto Ed25519 -- rather than a second implementation that could drift
// from what the browser does and strand the account it creates.
//
//   echo '{"phrase":"...","kdf":{...}}'          | node derive_key.mjs derive
//   echo '{"private_key":"...","message":"..."}' | node derive_key.mjs sign

import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const hashwasm = require("../public/js/vendor-argon2.umd.min.js");

// DER prefix for a PKCS8-wrapped Ed25519 private key, followed by 32 raw
// bytes. Same constant as public/js/identity.js.
const PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const fromB64url = (text) => new Uint8Array(Buffer.from(text, "base64url"));

async function importPrivate(rawSeed) {
  const pkcs8 = new Uint8Array(PKCS8_PREFIX.length + 32);
  pkcs8.set(PKCS8_PREFIX, 0);
  pkcs8.set(rawSeed, PKCS8_PREFIX.length);

  return crypto.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, ["sign"]);
}

async function derive({ phrase, kdf }) {
  const rawSeed = await hashwasm.argon2id({
    password: phrase,
    salt: new TextEncoder().encode(kdf.domain),
    parallelism: kdf.parallelism,
    iterations: kdf.iterations,
    memorySize: kdf.memory_kib,
    hashLength: 32,
    outputType: "binary",
  });

  const key = await importPrivate(rawSeed);
  const jwk = await crypto.subtle.exportKey("jwk", key);

  // The raw Argon2id output IS the Ed25519 private key, which is why it can be
  // printed for safekeeping while the browser's copy stays non-extractable.
  return { pubkey: jwk.x, private_key: b64url(rawSeed) };
}

async function sign({ private_key: privateKey, message }) {
  const key = await importPrivate(fromB64url(privateKey));
  const signature = await crypto.subtle.sign("Ed25519", key, new TextEncoder().encode(message));

  return { signature: b64url(signature) };
}

const command = process.argv[2];
const input = JSON.parse(readFileSync(0, "utf8"));
const handlers = { derive, sign };

if (!handlers[command]) {
  process.stderr.write(`unknown command: ${command}\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(await handlers[command](input)));
