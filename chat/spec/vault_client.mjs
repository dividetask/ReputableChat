// Exercises public/js/vault.js and prints the results for the Ruby side to
// assert on. See spec/vault_client_spec.rb.
import { deriveKey, seal, unseal, merge } from "../public/js/vault.js";

const DOMAIN = "reputablechat:vault:v1";
const rawSeed = new Uint8Array(32).fill(7);
const key = await deriveKey(rawSeed, DOMAIN);
const otherDomain = await deriveKey(rawSeed, "reputablechat:elsewhere:v1");
const otherSeed = await deriveKey(new Uint8Array(32).fill(8), DOMAIN);

const contents = { settings: { display: { show_unrated: true } }, voted: ["a", "b"] };
const sealed = await seal(key, contents);
const again = await seal(key, contents);
const tampered = { ...sealed, ciphertext: `${sealed.ciphertext.slice(0, -4)}AAAA` };

console.log(JSON.stringify({
  ciphertext_is_base64url: /^[A-Za-z0-9_-]+$/.test(sealed.ciphertext),
  iv_is_base64url: /^[A-Za-z0-9_-]+$/.test(sealed.iv),
  round_trips: await unseal(key, sealed),
  wrong_domain: await unseal(otherDomain, sealed),
  wrong_seed: await unseal(otherSeed, sealed),
  tampered: await unseal(key, tampered),
  nonce_reused: again.iv === sealed.iv,
  ciphertext_repeated: again.ciphertext === sealed.ciphertext,

  merged_votes: merge(
    { settings: { a: 1 }, voted: ["local", "shared"] },
    { settings: { a: 2 }, voted: ["remote", "shared"] },
  ),
  merged_with_nothing: merge({ settings: {}, voted: ["only"] }, null),
}));
