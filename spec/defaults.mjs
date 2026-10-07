// Prints the initial ratings for a few cases so the Ruby side can assert on
// them. See spec/defaults_spec.rb.
import { initialRatings, declarationProfile } from "../public/js/defaults.js";

const GENESIS = "g".repeat(43);
const HOST = "h".repeat(43);
const ME = "m".repeat(43);

console.log(JSON.stringify({
  newcomer: initialRatings({ genesisPubkey: GENESIS, ownPubkey: ME }),
  newcomer_with_host: initialRatings({ genesisPubkey: GENESIS, hostPubkey: HOST, ownPubkey: ME }),
  genesis_itself: initialRatings({ genesisPubkey: GENESIS, ownPubkey: GENESIS }),
  host_itself: initialRatings({ genesisPubkey: GENESIS, hostPubkey: HOST, ownPubkey: HOST }),
  no_genesis: initialRatings({ genesisPubkey: null, ownPubkey: ME }),
  genesis_key: GENESIS,
  host_key: HOST,
  genesis_profile: declarationProfile({
    pubkey: GENESIS,
    payload: JSON.stringify({ handle: "Tim", bio: "Legally distinct.", icon: null }),
  }),
  genesis_profile_no_handle: declarationProfile({ pubkey: GENESIS, payload: JSON.stringify({}) }),
  genesis_profile_malformed: declarationProfile({ pubkey: GENESIS, payload: "not json" }),
  genesis_profile_missing: declarationProfile(null),
}));
