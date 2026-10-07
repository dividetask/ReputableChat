// Who is called what, from this viewer's position.
//
// Handles are not unique and never will be, so something has to decide which
// Joe is "Joe" and which is "Joe a4f2c1de". The rule is seniority, and the
// order it is measured in is what makes it useful against impersonation: an
// impersonator always arrives after the person they are copying, so they are
// always the one wearing the suffix.
//
//   1. friends, longest-held handle first
//   2. accounts you have seen, earliest sighting first
//   3. everybody else
//
// Friends outrank sightings outright. Somebody you chose is more yours than
// somebody who merely turned up first.
//
// "Longest held" rather than "added first", because a friend who renames
// forfeits seniority exactly as a sighting does -- otherwise somebody befriended
// years ago could rename onto a newer friend's handle and outrank them on time
// they never served under that name. The friend LIST is still ordered by when
// each was added; these are two different clocks and only one of them resets.

// The same eight characters the fingerprint has always been, so a suffix and a
// fingerprint are the same string rather than two things to learn.
export const SUFFIX_LENGTH = 8;

export const suffixOf = (pubkey) => pubkey.slice(0, SUFFIX_LENGTH);

// pubkey -> { handle, suffix } where suffix is null for whoever holds the
// handle outright.
export function resolveNames({ handles = {}, friends = [], seen = [] } = {}) {
  const rank = new Map();
  // Sorted by when the handle was taken, not by position, so the friend list
  // can stay in the order somebody built it.
  [...friends].sort((a, b) => (a.at || 0) - (b.at || 0)).forEach((entry, index) => {
    if (entry?.pubkey && !rank.has(entry.pubkey)) rank.set(entry.pubkey, [0, index]);
  });
  seen.forEach((entry, index) => {
    if (entry?.pubkey && !rank.has(entry.pubkey)) rank.set(entry.pubkey, [1, index]);
  });

  const holders = new Map();
  for (const [pubkey, handle] of Object.entries(handles)) {
    if (!handle) continue;
    if (!holders.has(handle)) holders.set(handle, []);
    holders.get(handle).push(pubkey);
  }

  const names = {};
  for (const [handle, group] of holders) {
    const ordered = [...group].sort((a, b) => compare(rank.get(a), rank.get(b), a, b));

    ordered.forEach((pubkey, position) => {
      names[pubkey] = {
        handle,
        suffix: group.length > 1 && position > 0 ? suffixOf(pubkey) : null,
      };
    });
  }
  return names;
}

// Anybody unranked sorts last: not chosen, not seen before, so not the one who
// gets to hold a contested name. Ties break on the key so two clients with the
// same information agree.
function compare(left, right, leftKey, rightKey) {
  const a = left || [2, 0];
  const b = right || [2, 0];

  if (a[0] !== b[0]) return a[0] - b[0];
  if (a[1] !== b[1]) return a[1] - b[1];
  return leftKey < rightKey ? -1 : 1;
}

// --- the seen set --------------------------------------------------------
//
// Every account a message has been seen from that is neither a friend nor
// blocked. It exists to record seniority and nothing else.

// A sighting under a handle they no longer use is worthless, and keeping it
// would be worse than worthless: an account seen long ago could rename itself
// to somebody else's handle and outrank them on seniority it never earned
// under that name. So a rename starts them over.
export function recordSighting(seen, pubkey, handle, at) {
  if (!pubkey || !handle) return seen;

  const existing = seen.find((entry) => entry.pubkey === pubkey);
  if (existing && existing.handle === handle) return seen;

  const without = existing ? seen.filter((entry) => entry.pubkey !== pubkey) : seen;
  return [...without, { pubkey, handle, at }];
}

// Friends and blocked accounts are not in the set by definition: one is ranked
// above it and the other is never shown.
export function forget(seen, pubkey) {
  return seen.filter((entry) => entry.pubkey !== pubkey);
}

// Over budget, the newest sightings go. Seniority is the entire content of this
// set, so dropping the oldest would throw away the only thing it records -- and
// it leaves the conservative bias in place: an account with no sighting on file
// loses a contested name to one that has.
export function prune(seen, limit) {
  if (!limit || seen.length <= limit) return seen;

  return [...seen].sort((a, b) => a.at - b.at).slice(0, limit);
}

// Merging two devices: the earlier sighting wins, because when it happened is
// the whole point of the record. See docs/project/identity.md.
export function merge(mine = [], theirs = []) {
  const byPubkey = new Map();

  for (const entry of [...theirs, ...mine]) {
    if (!entry?.pubkey) continue;
    const seen = byPubkey.get(entry.pubkey);
    if (!seen || entry.at < seen.at) byPubkey.set(entry.pubkey, entry);
  }
  return [...byPubkey.values()].sort((a, b) => a.at - b.at);
}

// --- friends -------------------------------------------------------------
//
// An entry is { pubkey, handle, at }, the same shape as a sighting, and for the
// same reason: a name claim is only as old as the name. Array order is when
// they were added and never changes; `at` is when they took the handle they are
// using now and resets when they change it.

export function rememberFriend(friends, pubkey, handle, at) {
  if (friends.some((entry) => entry.pubkey === pubkey)) return friends;

  return [...friends, { pubkey, handle, at }];
}

export function forgetFriend(friends, pubkey) {
  return friends.filter((entry) => entry.pubkey !== pubkey);
}

// A rename resets the claim and leaves the position alone.
export function refreshFriendHandle(friends, pubkey, handle, at) {
  const existing = friends.find((entry) => entry.pubkey === pubkey);
  if (!existing || !handle || existing.handle === handle) return friends;

  return friends.map((entry) => (
    entry.pubkey === pubkey ? { ...entry, handle, at } : entry
  ));
}

// A vault written before friends carried handles holds bare public keys. They
// are read as having been friended at the beginning of time, which is what they
// were, and pick up a handle the first time one is seen.
export function normalizeFriends(stored = []) {
  return stored.map((entry) => (
    typeof entry === "string" ? { pubkey: entry, handle: null, at: 0 } : entry
  )).filter((entry) => entry?.pubkey);
}
