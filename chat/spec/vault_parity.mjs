// The browser half of the vault, driven from Ruby so the two can be tested
// against each other rather than each against itself. See
// spec/vault_parity_spec.rb.
//
//   echo '{"op":"seal","seed":7,"domain":"...","value":{}}'        | node vault_parity.mjs
//   echo '{"op":"unseal","seed":7,"domain":"...","ciphertext":"..","iv":".."}' | node vault_parity.mjs
import { readFileSync } from "node:fs";
import { deriveKey, seal, unseal } from "../public/js/vault.js";

const input = JSON.parse(readFileSync(0, "utf8"));
// A byte value rather than a phrase: the raw seed is whatever Argon2id produced,
// and this test is about the two vault implementations, not the KDF.
const key = await deriveKey(new Uint8Array(32).fill(input.seed), input.domain);

const ops = {
  seal:   () => seal(key, input.value),
  unseal: () => unseal(key, { ciphertext: input.ciphertext, iv: input.iv }),
  // Printed so Ruby can compare the derived key itself, not only what it opens.
  // A key mismatch and a framing mismatch both show up as "will not decrypt",
  // and they are fixed in different places.
  key:    async () => ({
    key: Buffer.from(
      await crypto.subtle.exportKey(
        "raw",
        await crypto.subtle.deriveKey(
          { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0),
            info: new TextEncoder().encode(input.domain) },
          await crypto.subtle.importKey("raw", new Uint8Array(32).fill(input.seed),
                                        "HKDF", false, ["deriveKey"]),
          { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"],
        ),
      ),
    ).toString("base64url"),
  }),
};

process.stdout.write(JSON.stringify(await ops[input.op]()));
