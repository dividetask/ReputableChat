// Prints the initial ratings for a few cases so the Ruby side can assert on
// them. See spec/defaults_spec.rb.
import { initialRatings, declarationProfile } from "../public/js/defaults.js";

// Account IDs: record hashes, 64 hex characters.
const GENESIS = "a".repeat(64);
const HOST = "b".repeat(64);
const ME = "c".repeat(64);

console.log(JSON.stringify({
  newcomer: initialRatings({ genesisAccount: GENESIS, ownAccount: ME }),
  newcomer_with_host: initialRatings({ genesisAccount: GENESIS, hostAccount: HOST, ownAccount: ME }),
  genesis_itself: initialRatings({ genesisAccount: GENESIS, ownAccount: GENESIS }),
  host_itself: initialRatings({ genesisAccount: GENESIS, hostAccount: HOST, ownAccount: HOST }),
  no_genesis: initialRatings({ genesisAccount: null, ownAccount: ME }),
  genesis_key: GENESIS,
  host_key: HOST,
  // An identity declaration: the handle is its title, the bio its body.
  genesis_profile: declarationProfile({
    account: GENESIS,
    payload: JSON.stringify({ title: "Tim", body: "Legally distinct." }),
  }),
  genesis_profile_no_handle: declarationProfile({ account: GENESIS, payload: JSON.stringify({}) }),
  genesis_profile_malformed: declarationProfile({ account: GENESIS, payload: "not json" }),
  genesis_profile_missing: declarationProfile(null),
}));
