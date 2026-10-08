// Prints the record hash of each shared vector, one per line, so the Ruby side
// can diff against it. See spec/record_parity_spec.rb.
import { readFileSync } from "node:fs";
import { digest } from "../public/js/record.js";

const read = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));

for (const { payload, signature } of read("record_vectors.json")) {
  console.log(await digest(payload, signature));
}
