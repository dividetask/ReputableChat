// The browser's half of the published-score format. See
// spec/decimal_parity_spec.rb, which feeds it the same values in Ruby.
import { readFileSync } from "node:fs";
import { toFixed, toDecimal } from "../public/js/reputation.js";

const values = JSON.parse(readFileSync(0, "utf8"));

process.stdout.write(JSON.stringify(values.map((text) => toDecimal(toFixed(text)))));
