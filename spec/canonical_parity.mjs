// Prints the canonical form of each shared vector, one per line, so the Ruby
// side can diff against it. See spec/canonical_parity_spec.rb.
import { readFileSync } from "node:fs";
import { dump } from "../public/js/canonical.js";

const path = new URL("./fixtures/canonical_vectors.json", import.meta.url);
for (const vector of JSON.parse(readFileSync(path, "utf8"))) console.log(dump(vector));
