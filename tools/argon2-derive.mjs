// Argon2id for the bot client: a seed phrase in, the same 32 bytes the browser
// derives out.
//
// There is no argon2 in the Ruby bundle, and adding one would mean a second
// implementation of the KDF that could drift from the browser's without
// anything noticing until every bot signature stopped verifying. This loads
// the exact file public/js/identity.js loads, with the parameters the server
// publishes, so a bot's key is the browser's key by construction rather than
// by agreement.
//
// stdin:  {"phrase": "<already normalized>", "kdf": {...}}
// stdout: 64 hex characters

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const hashwasm = require("../public/js/vendor-argon2.umd.min.js");

const input = JSON.parse(await new Promise((resolve, reject) => {
  let text = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => (text += chunk));
  process.stdin.on("end", () => resolve(text));
  process.stdin.on("error", reject);
}));

const { phrase, kdf } = input;

const raw = await hashwasm.argon2id({
  password: phrase,
  salt: new TextEncoder().encode(kdf.domain),
  parallelism: kdf.parallelism,
  iterations: kdf.iterations,
  memorySize: kdf.memory_kib,
  hashLength: 32,
  outputType: "binary",
});

process.stdout.write(Buffer.from(raw).toString("hex"));
