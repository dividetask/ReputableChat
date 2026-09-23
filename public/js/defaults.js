// What a client knows before it has fetched anything, and what a brand new
// identity declares about the world.

// The genesis account starts as everybody's friend.
//
// It has to, or nothing works: an unrated account sits at exactly zero and is
// invisible to everyone, so a network where nobody has vouched for anybody has
// nothing anyone can see. Trusting the genesis gives a new arrival one anchor
// to see the world through, and gives the genesis a way to vouch for people
// who would otherwise be invisible forever.
//
// Two things about how it is done matter more than the fact of it.
//
// It is an ORDINARY RATING in the user's own config, not a rule in the client
// and not a rule on the server. It shows up in the friend list beside everyone
// else, and it can be removed like anyone else. A trust that cannot be seen or
// withdrawn is not a default, it is a policy wearing a default's clothes --
// and this whole project exists to avoid a reputation nobody chose.
//
// And it is seeded ONCE, when the identity is created. Re-adding it whenever
// it is missing would mean removing it never took, which is the same thing as
// not being able to remove it.
export function initialRatings({ genesisPubkey, ownPubkey }) {
  // The genesis account does not vouch for itself. Nobody contributes to their
  // own score anywhere else either.
  if (!genesisPubkey || genesisPubkey === ownPubkey) return {};

  return {
    [genesisPubkey]: { friend: true, reported: false, net_votes: 0, cleared: false },
  };
}

// The genesis account's handle, read out of the declaration the client already
// holds at boot.
//
// Every other name comes from a fetched config, and the genesis has none to
// fetch -- it has an identity declaration, which is the thing a config is being
// replaced by. Without this the one account everybody trusts by default is the
// one account nobody can see the name of, which is how it ended up rendering as
// "someone" in the friend list.
//
// Returns the profile shape the client currently uses. That mapping disappears
// when the client moves onto identity declarations and stops having two names
// for the same field.
export function genesisProfile(genesis) {
  if (!genesis?.payload) return null;

  let declaration;
  try {
    declaration = JSON.parse(genesis.payload);
  } catch {
    return null;
  }
  if (!declaration.handle) return null;

  return {
    username: declaration.handle,
    message: declaration.bio || "",
    icon: declaration.icon || null,
  };
}
