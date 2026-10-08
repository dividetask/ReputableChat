// Exercises public/js/names.js and prints the results for the Ruby side.
import {
  resolveNames, recordSighting, forget, prune, merge, suffixOf,
  rememberFriend, forgetFriend, refreshFriendHandle, normalizeFriends,
} from "../public/js/names.js";

const A = "a".repeat(43);
const B = "b".repeat(43);
const C = "c".repeat(43);
const D = "d".repeat(43);

const joes = { [A]: "Joe", [B]: "Joe", [C]: "Ada" };

console.log(JSON.stringify({
  suffix_length: suffixOf(A).length,

  unique_handle: resolveNames({ handles: joes, friends: [], seen: [] })[C],

  friend_beats_older_sighting: resolveNames({
    handles: joes,
    friends: [{ pubkey: B, handle: "Joe", at: 90 }],
    seen: [{ pubkey: A, handle: "Joe", at: 1 }],
  }),

  friends_use_claim_age: resolveNames({
    handles: joes,
    friends: [{ pubkey: A, handle: "Joe", at: 1 }, { pubkey: B, handle: "Joe", at: 5 }],
    seen: [],
  }),

  // A friend who renames onto another friend's handle does not bring their
  // seniority with them, in either direction.
  newcomer_renames_onto_a_held_handle: resolveNames({
    handles: joes,
    friends: refreshFriendHandle(
      [{ pubkey: A, handle: "Joe", at: 1 }, { pubkey: B, handle: "Ada", at: 5 }],
      B, "Joe", 99,
    ),
    seen: [],
  }),

  old_friend_renames_onto_a_newer_one: resolveNames({
    handles: joes,
    friends: refreshFriendHandle(
      [{ pubkey: A, handle: "Ada", at: 1 }, { pubkey: B, handle: "Joe", at: 5 }],
      A, "Joe", 99,
    ),
    seen: [],
  }),

  // The list order is a different clock and does not move.
  rename_keeps_list_position: refreshFriendHandle(
    [{ pubkey: A, handle: "Joe", at: 1 }, { pubkey: B, handle: "Ada", at: 5 }],
    A, "Bob", 99,
  ).map((entry) => entry.pubkey),

  remembering_a_friend: rememberFriend([], A, "Joe", 7),
  remembering_twice_is_once: rememberFriend(
    [{ pubkey: A, handle: "Joe", at: 7 }], A, "Joe", 99,
  ),
  forgetting_a_friend: forgetFriend([{ pubkey: A, handle: "Joe", at: 7 }], A),
  old_vaults_normalize: normalizeFriends([A]),

  sightings_use_seniority: resolveNames({
    handles: joes,
    friends: [],
    seen: [{ pubkey: B, handle: "Joe", at: 5 }, { pubkey: A, handle: "Joe", at: 9 }],
  }),

  // Neither chosen nor seen: sorts last, so a stranger never takes a name off
  // somebody the viewer has a record of.
  stranger_loses: resolveNames({
    handles: { [A]: "Joe", [D]: "Joe" },
    friends: [],
    seen: [{ pubkey: A, handle: "Joe", at: 1 }],
  }),

  rename_restarts_seniority: recordSighting(
    [{ pubkey: A, handle: "Joe", at: 1 }], A, "Bob", 50,
  ),
  same_handle_keeps_seniority: recordSighting(
    [{ pubkey: A, handle: "Joe", at: 1 }], A, "Joe", 50,
  ),

  forgetting: forget([{ pubkey: A, handle: "Joe", at: 1 }, { pubkey: B, handle: "Ada", at: 2 }], A),

  prune_keeps_the_oldest: prune([
    { pubkey: A, handle: "x", at: 3 },
    { pubkey: B, handle: "y", at: 1 },
    { pubkey: C, handle: "z", at: 2 },
  ], 2).map((entry) => entry.at),

  merge_keeps_the_earlier: merge(
    [{ pubkey: A, handle: "Joe", at: 9 }],
    [{ pubkey: A, handle: "Joe", at: 2 }, { pubkey: B, handle: "Ada", at: 4 }],
  ),
}));
