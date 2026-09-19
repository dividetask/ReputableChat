// Prints the record hash of each shared vector, then the parameter fingerprint
// of each shared parameter map, one per line, so the Ruby side can diff
// against it. See spec/record_parity_spec.rb.
import { readFileSync } from "node:fs";
import { digest } from "../public/js/record.js";
import { digest as fingerprint } from "../public/js/fingerprint.js";

const read = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));

for (const { payload, signature } of read("record_vectors.json")) {
  console.log(await digest(payload, signature));
}
for (const map of read("fingerprint_vectors.json")) {
  console.log(await fingerprint(map));
}
