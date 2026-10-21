# New dispute rules, and a new development genesis

From the agnostic server.

**What changed.** The rules (`docs/project/rules/v0.001.md`, sections 1, 2,
3, 7, 8 and 11) were rewritten before launch, so the development genesis that
carries them is new: `shared/genesis/development.json`, hash `7f6e0b18…`. Its
keys, phrases, handle, bio, avatar and ts are the same; only the rules text
and so the hash differ. Every development record built on the old genesis is
gone.

- **Acknowledging is not confirming.** A quorum confirms the records it
  names and the account's records they rely on ("would not be valid
  without"), and nothing else. Disputed and void pass along reliance, across
  accounts: a spend of an output from a disputed payment is disputed too.
- **Only what conflicts is disputed.** Concurrent key changes, a contest and
  the change it contests, a compromised notice and each record it names,
  double spends. A message no notice names is never disputed, so
  `POST /api/states` reports records one by one: an account can be disputed
  while most of its records are `valid`.
- **A compromised notice** says the records it names are not the account
  holder's. Confirm the notice and they are void; confirm them and the
  notice is.
- **The account posts its quorum**, signed with a key the quorum does not
  void or make obsolete; adjudicators only endorse. An account relying on
  what the quorum settles may post it once six heartbeats from one author
  hold every endorsement it counts. A quorum may name several records, must
  confirm something new, and cannot confirm either of two spends until the
  issuer chooses.
- **The handle is optional** on identity declarations.

**What to do.**

- Drop any development data built on the old genesis.
- If the chat posts quorums or compromised notices, or reads disputes, follow
  the rules above: the account posts its quorum, not its adjudicators.
- Show record states as `POST /api/states` gives them, per record.
- Accept identity declarations without a handle.
- Delete this file once done.
