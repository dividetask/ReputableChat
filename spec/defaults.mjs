// Prints the initial ratings for a few cases so the Ruby side can assert on
// them. See spec/defaults_spec.rb.
import { initialRatings } from "../public/js/defaults.js";

const GENESIS = "g".repeat(43);
const ME = "m".repeat(43);

console.log(JSON.stringify({
  newcomer: initialRatings({ genesisPubkey: GENESIS, ownPubkey: ME }),
  genesis_itself: initialRatings({ genesisPubkey: GENESIS, ownPubkey: GENESIS }),
  no_genesis: initialRatings({ genesisPubkey: null, ownPubkey: ME }),
  genesis_key: GENESIS,
}));
