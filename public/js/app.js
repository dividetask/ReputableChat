// UI wiring. The interesting parts live in identity.js (keys and signing),
// reputation.js (scoring) and session.js (buckets); this file moves data
// between them.

import * as seed from "./seed.js";
import * as identity from "./identity.js";
import { Reputation, Graph, toNumber, toFixed, toDecimal } from "./reputation.js";
import { Session } from "./session.js";
import { initialRatings, declarationProfile } from "./defaults.js";
import * as vault from "./vault.js";
import * as names from "./names.js";

const ROOM = "general";
const LOGIN_PATH = "/";
const NEW_ACCOUNT_PATH = "/new-account";
// A quick picker, not the whole set: sixteen emotes make a toolbar wider than
// the message it floats over. The rest stay configured and unused for now.
const QUICK_EMOTES = 8;
const PUBKEY = /^[A-Za-z0-9_-]{42,44}$/;
const $ = (id) => document.getElementById(id);

const state = {
  config: null, emotes: null, me: null, profile: null, revision: 0,
  ratings: {}, graph: new Graph(), reputation: null, session: null,
  identityRevision: 0, attestationRevision: 0, attestationPending: 0, attestationAt: 0,
  voted: new Set(), viewing: null, settings: {}, vaultRevision: 0,
  vaultDirty: false,
  reactions: new Map(), recentlyBlocked: new Map(), replyingTo: null,
  genesis: null, host: null, tip: null, newFriends: {}, limits: null,
  seen: [], friendList: [], names: {},
  renderEpoch: 0, renderedKey: null, pendingRegistration: false,
};

// Anything that changes how the chat should look without changing what the
// server returned -- a bucket moving, a profile learned, a vote cast. Polling
// alone must not rebuild the DOM, so local changes announce themselves here.
const touch = () => { state.renderEpoch += 1; };

// The record this client will name as the last thing it saw. `tip` is the most
// recent record whose author cleared the bar; with nothing yet seen it is the
// genesis, which is why Tim exists.
function currentAck() {
  return state.tip || state.genesis.hash;
}

// The genesis account's committed declaration or this server's host
// account's, whichever `pubkey` belongs to. Both are in hand before anything
// has been fetched, which is what lets the default friends have a name and a
// face on the account creation screen.
function committedFor(pubkey) {
  return [state.genesis, state.host].find((record) => record && record.pubkey === pubkey) || null;
}

// The bar is the viewer's own, read through the viewer's own config, so two
// people disagree about which references were legitimate and no server can
// settle it. Acknowledging only people you rate is what leaves new and
// low-reputation accounts unanchored -- see docs/project/chain.md.
function chooseTip(messages) {
  if (!state.session) return null;

  const bar = toFixed(state.config.chain.min_reputation_to_acknowledge);

  for (let i = messages.length - 1; i >= 0; i--) {
    const { pubkey: author, hash } = messages[i];
    if (!hash) continue;
    if (author === state.me.pubkey) return hash;
    if (state.session.scoreOf(author) > bar) return hash;
  }
  return null;
}

async function api(path, options = {}) {
  const response = await fetch(path, { credentials: "same-origin", ...options });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `request failed (${response.status})`);
  return data;
}

const send = (method, path, body) =>
  api(path, { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

const post = (path, body) => send("POST", path, body);

function status(el, message, kind = "") {
  el.textContent = message;
  el.className = `status ${kind}`;
}

// People are identified by key, never by name — names are not unique, so the
// fingerprint is all that stands between a user and a convincing impersonator.
const fingerprint = (pubkey) => pubkey.slice(0, 8);

// --- the vault ----------------------------------------------------------
//
// Settings, the voted list, the friend list, the seen set and the private
// ratings behind every published score. Held on the server so they survive a
// new device, sealed before they leave the browser, and signed over the
// ciphertext so tampering is detectable. The server holds it and cannot read
// it -- not merely private from other users, which is what the signed-only
// record this replaces amounted to.

function deepMerge(base, overrides) {
  const merged = { ...base };

  for (const [key, value] of Object.entries(overrides || {})) {
    const nested = value && typeof value === "object" && !Array.isArray(value);
    merged[key] = nested ? deepMerge(base?.[key] || {}, value) : value;
  }

  return merged;
}

// The viewer's pinned settings layered over the server defaults, which is the
// same shape the config system uses everywhere else.
function buildReputation() {
  return new Reputation(deepMerge(state.config, state.settings));
}

// --- the vault ---------------------------------------------------------
//
// Local first. Changes land in memory immediately and reach the server on a
// timer, when the page is hidden, and at log off. What that costs is bounded
// and worth naming: a tab that dies between pushes loses whatever happened
// since the last one.

function vaultContents() {
  return {
    settings: state.settings,
    voted: [...state.voted],
    seen: state.seen,
    // Canonical serialization sorts keys, so the ratings object comes back from
    // the server in public-key order and cannot carry "who I added first".
    // Each entry also records the handle that friend is using and when they
    // took it, because a name claim is only as old as the name.
    friends: state.friendList,
    // Friending, reporting and voting are private now. What the network sees
    // is the score they come to, published in an attestation.
    ratings: state.ratings,
    attestation: {
      revision: state.attestationRevision,
      pending: state.attestationPending,
      at: state.attestationAt,
    },
  };
}

function applyVault(contents) {
  state.settings = contents.settings || {};
  state.voted = new Set(contents.voted || []);
  state.seen = contents.seen || [];
  state.friendList = names.normalizeFriends(contents.friends || contents.friend_order || []);
  state.ratings = contents.ratings || {};
  state.attestationRevision = contents.attestation?.revision || state.attestationRevision;
  state.attestationPending = contents.attestation?.pending || 0;
  state.attestationAt = contents.attestation?.at || 0;
}

async function loadVault() {
  const { vault: blob } = await api("/api/vault");

  state.settings = {};
  state.voted = new Set();
  state.vaultRevision = 0;
  state.vaultDirty = false;
  if (!blob) return;

  // Verified even though the MVP takes other people's records on trust --
  // detecting tampering is the entire reason this one is signed.
  if (!(await identity.verifyBlob(state.me.pubkey, blob))) {
    return status($("chat-status"),
                  "Your saved settings did not verify and were ignored.", "error");
  }

  const payload = JSON.parse(blob.payload);
  state.vaultRevision = payload.revision || 0;

  const contents = await vault.unseal(state.me.vaultKey, payload);
  if (!contents) {
    return status($("chat-status"),
                  "Your saved settings could not be decrypted and were ignored.", "error");
  }
  applyVault(contents);
}

// Long enough that a run of votes becomes one write, short enough that
// closing the tab afterwards does not lose them.
const VAULT_DEBOUNCE_MS = 3_000;
let vaultPush = null;

// What a change calls. Nothing waits on the network -- a vote must not block on
// a request -- but the write is scheduled rather than left to the hourly timer.
//
// That timer was the whole durability story until friends and reports moved in
// here. When ratings were published on every change the server always had them;
// now the vault is the only copy, and an hour is far too long to hold somebody's
// friend list in one tab.
function vaultChanged() {
  state.vaultDirty = true;
  clearTimeout(vaultPush);
  vaultPush = setTimeout(() => pushVault().catch(() => {}), VAULT_DEBOUNCE_MS);
}

async function writeVault(revision, contents) {
  const ts = Math.floor(Date.now() / 1000);
  const sealed = await vault.seal(state.me.vaultKey, contents);
  const payload = identity.vaultPayload({
    pubkey: state.me.pubkey, revision, ...sealed, ts,
  });

  await send("PUT", "/api/vault", {
    revision, ...sealed, ts, signature: await identity.sign(state.me, payload),
  });
  state.vaultRevision = revision;
}

// A rejection means the other device got there first, so this one merges
// rather than retrying -- see vault.merge for which direction each list
// resolves in.
async function pushVault({ force = false } = {}) {
  if (!state.me?.vaultKey) return;
  if (!state.vaultDirty && !force) return;

  state.vaultDirty = false;
  try {
    await writeVault(state.vaultRevision + 1, vaultContents());
  } catch {
    try {
      const { vault: blob } = await api("/api/vault");
      const payload = blob ? JSON.parse(blob.payload) : null;
      const theirs = payload ? await vault.unseal(state.me.vaultKey, payload) : null;

      applyVault(vault.merge(vaultContents(), theirs));
      await writeVault(Math.max(state.vaultRevision, payload?.revision || 0) + 1, vaultContents());
    } catch (error) {
      // Kept dirty, so the next push tries again rather than dropping it.
      state.vaultDirty = true;
      status($("chat-status"), `Could not save your settings: ${error.message}`, "error");
    }
  }
}


// Re-sorts everyone from the graph already in hand. In-session reports are
// replayed so a toggle does not quietly un-block someone.
function rebuildSession() {
  const previous = state.session ? [...state.session.reports] : [];

  // The viewer's own entry is their vault's actions, not a published score:
  // `ratingValue` runs the curve for them, and is the one place in the system
  // that sees an unpublished rating. Everyone else's entry is the score they
  // published, because the curve already ran wherever it was published.
  //
  // Re-added on every rebuild rather than left to the one `loadNetwork` wrote.
  // That one happens to keep working because it stored the live state.ratings
  // object and mutations show through, which is true today and is not a thing
  // to depend on.
  state.graph.add(state.me.pubkey, state.ratings);
  state.session = new Session(
    state.reputation, state.me.pubkey, state.graph, state.config.session.report_blocks,
  );

  for (const [subject, reporters] of previous) {
    for (const reporter of reporters.keys()) state.session.report(subject, reporter);
  }
}

// --- seed entry --------------------------------------------------------

// No word suggestions here any more: the field is a password field so it is
// not readable over a shoulder, and suggesting the word being typed would put
// it straight back on screen.
// Login and new account are separate URLs, navigated with pushState so the
// derived key and the typed seed survive the move between them.
const creatingAccount = () => window.location.pathname === NEW_ACCOUNT_PATH;

function goTo(path, { replace = false } = {}) {
  if (window.location.pathname !== path) {
    window.history[replace ? "replaceState" : "pushState"]({}, "", path);
  }
  renderRoute();
}

function renderRoute() {
  const newAccount = creatingAccount();
  $("new-account").classList.toggle("hidden", !newAccount);
  $("login-intro").classList.toggle("hidden", newAccount);

  // On the new account screen there is one button and it creates the account.
  // Two buttons there read as two different destinations when only one of them
  // goes anywhere -- "New Account" would only regenerate the seed already on
  // screen, and "Login" was what actually created the account.
  $("unlock").textContent = newAccount ? "Create Account" : "Login";
  $("generate").classList.toggle("hidden", newAccount);
}
const chosenName = () => $("new-name").value.trim();

async function refreshSeedField() {
  const phrase = $("seed").value;
  const words = seed.words(phrase);
  let reason = phrase.trim() ? await seed.validate(phrase, state.config.seed.min_words) : "type your seed";

  // On the new-account page the name is part of signing up, so it gates the
  // button too rather than being asked for afterwards.
  if (!reason && creatingAccount() && !chosenName()) reason = "pick a display name";

  $("unlock").disabled = reason !== null;
  status($("seed-status"), reason || `${words.length} words · looks good`, reason ? "" : "ok");
}

// --- login -------------------------------------------------------------

async function unlock(event) {
  if (event) event.preventDefault();
  $("unlock").disabled = true;

  try {
    // This seed was derived a moment ago and only the name was missing, so
    // there is no reason to spend another second in Argon2 on it.
    if (state.pendingRegistration && chosenName()) {
      status($("seed-status"), "creating your account…");
      return await registerWith(chosenName());
    }

    status($("seed-status"), "deriving your key — this takes a moment by design…");
    await signIn(await identity.deriveFromSeed($("seed").value, state.config.seed.kdf));
  } catch (error) {
    status($("seed-status"), error.message, "error");
    $("unlock").disabled = false;
  }
}

// `restoring` means this came from a key left in IndexedDB rather than from
// someone typing a seed, so nothing here may open a signup they did not ask for.
async function signIn(derived, { restoring = false } = {}) {
  const { nonce } = await post("/api/challenge", {});
  const ts = Math.floor(Date.now() / 1000);
  const payload = identity.loginPayload({
    pubkey: derived.pubkey, nonce, origin: window.location.origin, ts,
  });

  const session = await post("/api/session", {
    pubkey: derived.pubkey, nonce, ts, signature: await identity.sign(derived, payload),
  });

  state.me = derived;

  if (session.registered) return enterChat();

  // A remembered key whose account was never created -- someone started a
  // signup and left. Drop it and stay on the login screen rather than making
  // the new account screen the first thing anyone sees.
  if (restoring) {
    await identity.forget();
    state.me = null;
    return;
  }

  if (creatingAccount() && chosenName()) return registerWith(chosenName());

  // An unregistered seed typed on the login screen. Send them to the new
  // account screen for a display name rather than growing a name field on the
  // login screen. The seed stays in its password field so the page works
  // without ever putting it back on screen -- it is not one we generated.
  state.pendingRegistration = true;
  $("new-seed-block").classList.add("hidden");
  $("unregistered-note").classList.remove("hidden");
  $("new-name").value = "";
  resetNewFriends();
  goTo(NEW_ACCOUNT_PATH);
  $("new-name").focus();
  refreshSeedField();
}

// --- choosing friends before the account exists -------------------------
//
// A friend list is a list of public keys and nothing else, so none of this
// needs the server: a key that belongs to nobody yet, or to nobody ever, is
// still a perfectly good thing to write down. That is what makes it possible
// to choose here, before the account being created has said anything.

// Before login there are no fetched profiles, so the only names available are
// the default friends', out of the declarations already in hand.
function newAccountName(pubkey) {
  const record = committedFor(pubkey);
  if (!record) return "unknown";

  const fallback = record === state.genesis ? "the genesis account" : "this server's account";
  return declarationProfile(record)?.handle || fallback;
}

function resetNewFriends() {
  state.newFriends = initialRatings({
    genesisPubkey: state.genesis?.pubkey,
    hostPubkey: state.host?.pubkey,
    ownPubkey: state.me?.pubkey,
  });
  renderNewFriends();
}

function renderNewFriends() {
  const box = $("new-friends");
  box.replaceChildren();

  const keys = Object.keys(state.newFriends);
  if (!keys.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "nobody — you will not be able to see anyone";
    return box.append(empty);
  }

  for (const pubkey of keys) {
    const row = document.createElement("div");
    row.className = "row";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = newAccountName(pubkey); // textContent, never innerHTML

    const key = document.createElement("span");
    key.className = "pubkey";
    key.textContent = pubkey;

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "secondary";
    remove.textContent = "remove";
    remove.addEventListener("click", () => removeNewFriend(pubkey));

    row.append(avatarFor(pubkey), name, key, remove);
    box.append(row);
  }
}

// Removing a default friend here is the one choice on this screen with a
// consequence somebody might not have in mind, so it is the one that asks.
// Removing a key pasted in ten seconds ago is not worth a dialog.
async function removeNewFriend(pubkey) {
  if (committedFor(pubkey)) {
    const sure = await confirmAction(
      `Start without ${newAccountName(pubkey)}? Nothing it vouches for will reach ` +
      "you, and accounts nobody else has vouched for will be invisible. You can " +
      "add it back later.",
      "Yes, remove",
    );
    if (!sure) return;
  }

  delete state.newFriends[pubkey];
  renderNewFriends();
}

function addNewFriend() {
  const field = $("new-friend-key");
  const pubkey = field.value.trim();
  const say = (message, kind) => status($("new-friend-status"), message, kind);

  if (!PUBKEY.test(pubkey)) return say("That is not a public key.", "error");
  if (pubkey === state.me?.pubkey) return say("That is your own key.", "error");
  if (state.newFriends[pubkey]) return say("Already on the list.", "error");

  // The same shape the seeded friendship uses, so nothing downstream can tell
  // which entries were chosen here and which were the default.
  state.newFriends[pubkey] = { friend: true, reported: false, net_votes: 0, cleared: false };
  field.value = "";
  say("Added.", "ok");
  renderNewFriends();
}

// A brand new seed, shown so it can be copied across.
async function startNewAccount() {
  $("new-seed-words").value = await seed.generate(state.config.seed.min_words);
  $("new-name").value = "";
  $("seed").value = "";
  state.pendingRegistration = false;
  $("new-seed-block").classList.remove("hidden");
  $("unregistered-note").classList.add("hidden");
  resetNewFriends();
  goTo(NEW_ACCOUNT_PATH);
  refreshSeedField();
  $("new-name").focus();
}

async function registerWith(username) {
  await post("/api/register", {});
  state.profile = { username, message: "", icon: null };

  // Whatever was on the new account screen, which started from the seeded
  // default and is theirs to have edited. Their own key can only have got in
  // here by being pasted before they had one, so it goes now.
  state.ratings = { ...state.newFriends };
  delete state.ratings[state.me.pubkey];
  // Captured before anything round-trips through the server, which is the only
  // moment this order exists: canonical serialization sorts keys, so it cannot
  // be recovered from the ratings afterwards.
  state.friendList = Object.keys(state.ratings).map((pubkey) => ({
    pubkey, handle: newAccountName(pubkey), at: now(),
  }));
  vaultChanged();

  state.profile = { handle: username, bio: "", icon: null };
  await publishIdentity();
  // Published straight away rather than waiting on the cadence: an account
  // with no attestation contributes nothing to anybody, and the friendships
  // just chosen are the whole reason this screen exists.
  await publishAttestation();
  // Waited on rather than scheduled. This is the one moment where the vault is
  // the only record of the choices just made, and a tab closed before the
  // first write would take the whole account's friend list with it.
  await pushVault({ force: true });
  await enterChat();
}



async function logOff() {
  // Best effort, and the last of several: the timer and the hidden-page push
  // are what actually keep a vault current, because a tab can close without
  // ever reaching this line.
  await pushVault().catch(() => {});
  await identity.forget();
  location.reload();
}

// --- identity declarations and attestations -----------------------------
//
// An identity declaration says who you are; an attestation says what you think
// of everybody else. They are
// separate so that changing your mind about somebody does not mean re-signing
// who you are -- and so that the actions behind an opinion can stay private
// while the opinion itself travels.

function parseRecord(blob) {
  if (!blob) return null;
  try {
    return JSON.parse(blob.payload);
  } catch {
    return null;
  }
}

async function publishIdentity() {
  state.identityRevision += 1;
  const ts = now();
  const body = {
    revision: state.identityRevision,
    handle: state.profile.handle,
    bio: state.profile.bio || "",
    icon: state.profile.icon || null,
    ack: currentAck(),
    ts,
  };
  const payload = identity.identityPayload({ pubkey: state.me.pubkey, ...body });

  await send("PUT", "/api/identity", { ...body, signature: await identity.sign(state.me, payload) });
}

// What the vault's private actions come to, as a number. The curve runs here,
// once, rather than in every reader -- which is the whole difference between
// an attestation and the config it replaces.
function myScores() {
  const scores = {};

  for (const [pubkey, rating] of Object.entries(state.ratings)) {
    const value = state.reputation.ratingValue(rating);
    if (value === null) continue;

    scores[pubkey] = {
      reputation: toDecimal(value),
      trust: toDecimal(state.reputation.multiplierOf(rating)),
    };
  }
  return scores;
}

const configValue = (path) => path.split(".").reduce(
  (node, key) => (node == null ? undefined : node[key]),
  deepMerge(state.config, state.settings),
);

// The cache other people use as the fourth term of their own score. Carries the
// fingerprint of the parameters it was computed under, because reputation is
// subjective and configuration is per-user: without it a reader cannot tell
// whether these numbers mean anything to them.
function derivedScores() {
  const hops = Number(state.config.attestation?.published_hops ?? 3);
  const scores = {};
  if (!state.session) return scores;

  for (const [pubkey, depth] of state.session.depths || []) {
    if (depth > hops || pubkey === state.me.pubkey) continue;
    scores[pubkey] = toDecimal(state.session.scoreOf(pubkey));
  }
  return scores;
}

async function publishAttestation() {
  state.attestationRevision += 1;
  const ts = now();
  const body = {
    revision: state.attestationRevision,
    scores: myScores(),
    derived: { scores: derivedScores() },
    ack: currentAck(),
    ts,
  };
  const payload = identity.attestationPayload({ pubkey: state.me.pubkey, ...body });

  await send("PUT", "/api/attestation", { ...body, signature: await identity.sign(state.me, payload) });
  state.attestationPending = 0;
  state.attestationAt = ts;
  vaultChanged();
}

// A change to what somebody is worth. Counted rather than published, because
// re-signing an entry for everyone ever rated on every emote is absurd -- see
// the cadence in config/reputation.yml.
function scoreChanged() {
  state.attestationPending += 1;
  vaultChanged();
}

// Nothing goes out without something to say. Both limits are floors on when
// pending changes are published, not schedules.
function attestationIsDue() {
  if (!state.attestationPending) return false;

  const settings = state.config.attestation || {};
  const changes = Number(settings.resubmit_after_changes ?? 10);
  const seconds = Number(settings.resubmit_after_seconds ?? 604800);

  return state.attestationPending >= changes
    || (state.attestationAt > 0 && now() - state.attestationAt >= seconds)
    || state.attestationRevision === 0;
}

async function publishIfDue() {
  if (!attestationIsDue()) return;

  await publishAttestation().catch((error) => {
    status($("chat-status"), `Could not publish your ratings: ${error.message}`, "error");
  });
}

async function loadOwnIdentity() {
  const { identity: blob } = await api(`/api/identity/${state.me.pubkey}`);
  const declaration = parseRecord(blob);

  state.identityRevision = declaration?.revision || 0;
  state.profile = {
    handle: declaration?.handle || "anonymous",
    bio: declaration?.bio || "",
    icon: declaration?.icon || null,
  };

  const { attestation } = await api(`/api/attestation/${state.me.pubkey}`);
  state.attestationRevision = parseRecord(attestation)?.revision || 0;
}

// Walks outward from the viewer, fetching a whole hop per request. Bounded by
// max_hops and max_accounts together: a positive-only graph still branches, so
// hop count alone does not bound the fetch.
async function loadNetwork() {
  const { max_hops: maxHops, max_accounts: maxAccounts } = state.config.ladder;
  state.graph = new Graph();
  state.graph.add(state.me.pubkey, state.ratings);
  state.profiles = new Map([[state.me.pubkey, state.profile]]);

  // The default friends' first declarations are committed files rather than
  // published records, so their names come from the copies already in hand.
  // Seeded before the walk, so one they have published since wins over it.
  for (const record of [state.genesis, state.host]) {
    const profile = declarationProfile(record);
    if (profile) state.profiles.set(record.pubkey, profile);
  }

  let frontier = [state.me.pubkey];
  const seen = new Set(frontier);

  for (let hop = 0; hop < maxHops && seen.size < maxAccounts; hop++) {
    const wanted = [];

    for (const rater of frontier) {
      for (const [subject, rating] of Object.entries(state.graph.ratingsBy(rater))) {
        if (seen.has(subject) || seen.size + wanted.length >= maxAccounts) continue;
        if (state.reputation.ratingValue(rating) <= state.reputation.minRating) continue;
        wanted.push(subject);
      }
    }
    if (!wanted.length) break;

    await fetchConfigs(wanted);
    wanted.forEach((pubkey) => seen.add(pubkey));
    frontier = wanted;
  }
}

async function fetchConfigs(pubkeys) {
  const fresh = pubkeys.filter((key) => key && !state.graph.has(key));
  if (!fresh.length) return;

  // MVP: signatures are taken on trust (session.verify_signatures). The
  // verification path is written and tested server-side; until it runs here, a
  // malicious server can fabricate any rating it likes.
  //
  // Two fetches because they are two records: who somebody is, and what they
  // think. Plenty of accounts have one and not the other -- the genesis has
  // never rated anybody, and a brand new account has not published an
  // attestation yet.
  const [{ attestations }, { identities }] = await Promise.all([
    post("/api/attestation/batch", { pubkeys: fresh }),
    post("/api/identity/batch", { pubkeys: fresh }),
  ]);

  for (const blob of attestations) {
    const payload = parseRecord(blob);
    if (!payload || payload.pubkey !== blob.pubkey) continue;

    state.graph.add(blob.pubkey, payload.scores || {});
  }

  for (const blob of identities) {
    const payload = parseRecord(blob);
    if (!payload || payload.pubkey !== blob.pubkey) continue;

    state.profiles.set(blob.pubkey, {
      handle: payload.handle, bio: payload.bio, icon: payload.icon,
    });
  }

  for (const key of fresh) if (!state.graph.has(key)) state.graph.add(key, {});

  touch(); // names and icons just became available
}

// --- chat --------------------------------------------------------------

async function enterChat() {
  // Remembered only now: before the account exists, storing the key strands a
  // signup nobody finished.
  await identity.remember({ privateKey: state.me.privateKey, pubkey: state.me.pubkey });

  goTo(LOGIN_PATH, { replace: true }); // do not leave /new-account in the bar
  $("seed").value = ""; // the seed has done its job
  state.pendingRegistration = false;
  $("login").classList.add("hidden");
  $("chat").classList.remove("hidden");

  await loadVault();
  state.reputation = buildReputation();
  await loadOwnIdentity();
  await loadNetwork();
  rebuildSession();

  $("me").textContent = `${state.profile.handle} · ${fingerprint(state.me.pubkey)}`;
  refreshMessages();
  setInterval(refreshMessages, 4000);
  // Local first, pushed on a timer. The interval is the server's advice, and
  // it bounds how much a dying tab can lose rather than how often anything is
  // allowed to happen.
  setInterval(() => pushVault().catch(() => {}), (state.limits?.vault_sync_seconds || 3600) * 1000);
}

async function refreshMessages() {
  let messages;
  let emotes;
  try {
    [{ messages }, { emotes }] = await Promise.all([
      api(`/api/room/${ROOM}/messages`),
      api(`/api/room/${ROOM}/emotes`),
    ]);
  } catch (error) {
    return status($("chat-status"), error.message, "error");
  }

  await fetchConfigs([...new Set([...messages.map((m) => m.pubkey), ...emotes.map((e) => e.pubkey)])]);
  state.tip = chooseTip(messages);
  recordSightings(messages);
  recomputeNames();

  // Most polls find nothing new. Rebuilding the list anyway costs a full DOM
  // teardown, drops any text selection, and closes an open hover menu.
  const key = renderKey(messages, emotes);
  if (key === state.renderedKey) return;

  state.renderedKey = key;
  state.reactions = tallyReactions(emotes);
  render(messages);
}

// Everything the rendered list depends on. The undo stubs are in here because
// they expire on a timer, so they have to redraw even when nothing arrives.
function renderKey(messages, emotes) {
  const stubs = [...state.recentlyBlocked.keys()].filter((key) => withinUndoWindow(key));

  return [
    messages.map((m) => m.hash).join(","),
    emotes.map((e) => `${e.message}${e.emote}${e.pubkey}`).join(","),
    stubs.join(","),
    state.renderEpoch,
  ].join("|");
}

const AT_BOTTOM_SLACK = 48;

function render(messages) {
  const list = $("messages");

  // Only follow new messages if you were already at the bottom. Otherwise keep
  // your place: this re-renders every few seconds, and pinning unconditionally
  // drags you back down mid-read. replaceChildren resets scrollTop, so the
  // position has to be put back by hand.
  const distanceFromBottom = list.scrollHeight - list.scrollTop - list.clientHeight;
  const wasFollowing = distanceFromBottom <= AT_BOTTOM_SLACK;
  const previousTop = list.scrollTop;

  list.replaceChildren();

  const byHash = new Map(messages.map((m) => [m.hash, m]));

  for (const message of messages) {
    const mine = message.pubkey === state.me.pubkey;
    const bucket = mine ? "trusted" : state.session.bucketOf(message.pubkey);

    if (bucket === "blocked") {
      // Someone you blocked moments ago leaves a stub you can undo. Everyone
      // else blocked simply is not here.
      if (withinUndoWindow(message.pubkey)) list.append(blockedStub(message));
      continue;
    }

    let payload;
    try {
      payload = JSON.parse(message.payload);
    } catch {
      continue;
    }

    const row = document.createElement("div");
    row.className = `msg ${bucket}`;
    row.id = domId(message.hash);

    const main = document.createElement("div");
    main.className = "msg-main";

    const who = document.createElement("span");
    who.className = "who";
    // displayName already carries a key suffix when the handle is contested,
    // so a separate fingerprint beside it would be the same eight characters
    // twice on the names that need them and clutter on the ones that do not.
    who.textContent = displayName(message.pubkey);
    who.addEventListener("click", () => showProfile(message.pubkey));

    const body = document.createElement("div");
    body.textContent = payload.body; // textContent, never innerHTML

    if (payload.reply_to) main.append(replyQuote(payload.reply_to, byHash));
    main.append(who, body, reactionBar(message, mine));
    row.append(avatarFor(message.pubkey), main);
    list.append(row);
  }

  list.scrollTop = wasFollowing ? list.scrollHeight : previousTop;
}

// message record hash -> emote -> the people who gave it.
//
// Reactions from blocked people are dropped, so a pile of spam accounts cannot
// inflate a count. Counts are therefore per-viewer, like everything else here.
function tallyReactions(emotes) {
  const tally = new Map();

  for (const { message, emote, pubkey: author } of emotes) {
    if (author !== state.me.pubkey && state.session.bucketOf(author) === "blocked") continue;

    if (!tally.has(message)) tally.set(message, new Map());
    const perEmote = tally.get(message);

    if (!perEmote.has(emote)) perEmote.set(emote, new Set());
    perEmote.get(emote).add(author);
  }

  return tally;
}

function polarityOf(emote) {
  if (state.emotes.negative.includes(emote)) return -1;
  if (state.emotes.neutral?.includes(emote)) return 0;
  return 1;
}

// True only for people this session blocked, and only until the grace period
// runs out. Nothing is persisted, so logging out ends it too.
function withinUndoWindow(pubkey) {
  const blockedAt = state.recentlyBlocked.get(pubkey);
  if (!blockedAt) return false;

  const grace = (state.config.display.block_grace_seconds ?? 3600) * 1000;
  if (Date.now() - blockedAt > grace) {
    state.recentlyBlocked.delete(pubkey);
    return false;
  }

  return true;
}

function blockedStub(message) {
  const row = document.createElement("div");
  row.className = "msg blocked-note";

  const label = document.createElement("span");
  label.textContent = "blocked";

  const actions = document.createElement("span");
  actions.className = "actions";
  const undo = document.createElement("button");
  undo.type = "button";
  undo.textContent = "undo report";
  undo.addEventListener("click", () => undoReport(message.pubkey, { confirm: false }).catch(
    (e) => status($("chat-status"), e.message, "error"),
  ));
  actions.append(undo);

  row.append(label, actions);
  return row;
}

// Names are not unique, so an avatar derived from the key gives every person a
// stable look even before they upload one. Same key, same colour, always.
// Where an icon comes from, in order: a declaration fetched during the walk,
// then the committed declaration of a default friend, which the client holds
// before it has fetched anything.
//
// The second is why the default friends have faces on the account creation
// screen, where nothing has been fetched and nothing can be -- the account
// doing the looking does not exist yet.
function iconFor(pubkey) {
  const known = state.profiles?.get(pubkey)?.icon;
  if (known) return known;

  return declarationProfile(committedFor(pubkey))?.icon || null;
}

function avatarFor(pubkey, extra = "", icon = iconFor(pubkey)) {
  // The avatar already on somebody's profile is the end of the journey, so it
  // enlarges. Everywhere else an avatar is a way to get there.
  const onProfile = extra.includes("avatar-large");

  // An <img> with an empty src resolves to the page URL and renders as a
  // broken image, so anyone without an icon gets the placeholder instead.
  if (icon) {
    const img = document.createElement("img");
    img.className = `avatar ${extra}`.trim();
    img.src = `/images/${icon}`;
    img.alt = "";
    if (onProfile) enlarges(img, `/images/${icon}`); else opensProfile(img, pubkey);
    return img;
  }

  let hash = 0;
  for (const character of pubkey) hash = ((hash * 31) + character.charCodeAt(0)) >>> 0;

  const placeholder = document.createElement("span");
  placeholder.className = `avatar placeholder ${extra}`.trim();
  placeholder.style.background = `hsl(${hash % 360} 42% 30%)`;
  placeholder.textContent = pubkey.slice(0, 2);
  // A placeholder is two letters on a colour. There is nothing to enlarge, so
  // on a profile it does nothing at all.
  if (!onProfile) opensProfile(placeholder, pubkey);
  return placeholder;
}

// How long the pointer has to rest on an avatar before it counts as wanting
// something. Without it, crossing a list of messages would open every profile
// on the way past, which is worse than no hover at all.
const HOVER_INTENT_MS = 400;

function opensProfile(element, pubkey) {
  let waiting = null;

  element.classList.add("enlargeable");
  element.addEventListener("mouseenter", () => {
    waiting = setTimeout(() => showProfile(pubkey), HOVER_INTENT_MS);
  });
  element.addEventListener("mouseleave", () => clearTimeout(waiting));
  element.addEventListener("click", (event) => {
    // A tap fires this without ever hovering, so it must not wait.
    clearTimeout(waiting);
    event.stopPropagation();
    showProfile(pubkey);
  });
}

// The overlay does not take pointer events, so what dismisses it is leaving the
// image rather than reaching the backdrop -- an overlay that swallowed the
// pointer would cover the thing whose hover is keeping it open, and flicker
// between the two states forever.
function enlarges(element, source) {
  element.addEventListener("mouseenter", () => showLarge(source));
  element.addEventListener("mouseleave", () => hideLarge());
  element.addEventListener("click", (event) => {
    event.stopPropagation();
    // A tap is not a hover: on a touch screen the overlay is not already up.
    if ($("lightbox").classList.contains("hidden")) showLarge(source); else hideLarge();
  });
}

function showLarge(source) {
  const box = $("lightbox");
  $("lightbox-image").src = source;
  box.classList.remove("hidden");
  box.setAttribute("aria-hidden", "false");
}

function hideLarge() {
  const box = $("lightbox");
  box.classList.add("hidden");
  box.setAttribute("aria-hidden", "true");
  $("lightbox-image").removeAttribute("src");
}

// Record hashes are hex, so they are already safe as an element id.
const domId = (hash) => `m-${hash}`;

// The quoted line above a reply. Clicking it scrolls to what was replied to.
function replyQuote(targetHash, byHash) {
  const quote = document.createElement("div");
  quote.className = "reply-quote";

  const target = byHash.get(targetHash);
  if (!target) {
    quote.classList.add("dangling");
    quote.textContent = "replying to a message you cannot see";
    return quote;
  }

  let body = "";
  try {
    body = JSON.parse(target.payload).body;
  } catch {
    body = "";
  }

  const arrow = document.createElement("span");
  arrow.className = "arrow";
  arrow.textContent = "\u21B1";

  const name = document.createElement("span");
  name.textContent = displayName(target.pubkey);

  const snippet = document.createElement("span");
  snippet.className = "snippet";
  snippet.textContent = body;

  quote.append(arrow, avatarFor(target.pubkey), name, snippet);
  quote.addEventListener("click", () => scrollToMessage(targetHash));
  return quote;
}

function scrollToMessage(hash) {
  const row = document.getElementById(domId(hash));
  if (!row) return;

  row.scrollIntoView({ behavior: "smooth", block: "center" });
  row.classList.remove("flash");
  void row.offsetWidth; // restart the animation if it is already running
  row.classList.add("flash");
}

function startReply(message) {
  state.replyingTo = message;
  $("replying").classList.remove("hidden");
  $("replying-to").textContent = `Replying to ${displayName(message.pubkey)}`;
  $("body").focus();
}

function cancelReply() {
  state.replyingTo = null;
  $("replying").classList.add("hidden");
}

// Recomputed rather than cached per person: a handle becomes contested when
// somebody else turns up, so one new arrival can change what an account
// already on screen is called.
function recomputeNames() {
  const handles = {};
  for (const [pubkey, profile] of state.profiles || []) {
    if (profile?.handle) handles[pubkey] = profile.handle;
  }

  state.names = names.resolveNames({
    handles,
    friends: state.friendList,
    seen: state.seen,
  });
}

function displayName(pubkey) {
  const resolved = state.names?.[pubkey];
  if (!resolved) return state.profiles?.get(pubkey)?.handle || "someone";

  return resolved.suffix ? `${resolved.handle} ${resolved.suffix}` : resolved.handle;
}

// Display order: when each was added, which never changes. Distinct from the
// name-claim clock in each entry, which resets on a rename.
//
// Recorded first, then anyone the record does not know about -- a rating from
// before the vault carried this, or from another device mid-merge.
function friendsInOrder() {
  const friends = Object.entries(state.ratings).filter(([, r]) => r.friend).map(([pubkey]) => pubkey);
  const known = state.friendList.map((entry) => entry.pubkey).filter((pubkey) => friends.includes(pubkey));

  return [...known, ...friends.filter((pubkey) => !known.includes(pubkey))];
}

function rememberFriend(pubkey) {
  state.friendList = names.rememberFriend(
    state.friendList, pubkey, state.profiles?.get(pubkey)?.handle || null, now(),
  );
}

function forgetFriend(pubkey) {
  state.friendList = names.forgetFriend(state.friendList, pubkey);
}

const now = () => Math.floor(Date.now() / 1000);

// Everybody whose message has crossed the screen and who is neither a friend
// nor blocked. Friends outrank sightings, so keeping one for a friend would be
// a record nothing ever reads.
function recordSightings(messages) {
  const before = state.seen;
  let seen = state.seen;

  for (const message of messages) {
    const author = message.pubkey;
    if (!author || author === state.me?.pubkey) continue;

    const rating = state.ratings[author];
    if (rating?.friend || rating?.reported) {
      seen = names.forget(seen, author);
      continue;
    }

    const handle = state.profiles?.get(author)?.handle;
    if (handle) seen = names.recordSighting(seen, author, handle, Math.floor(Date.now() / 1000));
  }

  seen = names.prune(seen, state.limits?.seen_entries);

  // A friend who renames forfeits their claim too: otherwise somebody
  // befriended years ago could rename onto a newer friend's handle and outrank
  // them on time they never served under that name.
  const friendsBefore = state.friendList;
  let friends = state.friendList;
  for (const entry of friendsBefore) {
    const handle = state.profiles?.get(entry.pubkey)?.handle;
    if (handle) friends = names.refreshFriendHandle(friends, entry.pubkey, handle, now());
  }

  if (seen === before && friends === friendsBefore) return;

  state.seen = seen;
  state.friendList = friends;
  vaultChanged();
}

// Reactions a message actually has, always visible with their counts, plus a
// picker that only appears on hover or keyboard focus (see .actions in the
// stylesheet). An emote nobody gave is not shown.
function reactionBar(message, mine) {
  const bar = document.createElement("div");
  bar.className = "reactions";
  const reacted = state.voted.has(message.hash);

  for (const [emote, people] of state.reactions.get(message.hash) || []) {
    const pill = document.createElement("button");
    pill.type = "button";
    pill.className = "pill";
    if (people.has(state.me.pubkey)) pill.classList.add("mine");
    pill.disabled = reacted;
    pill.title = `${people.size} ${people.size === 1 ? "person" : "people"}`;
    pill.textContent = `${emote} ${people.size}`;
    pill.addEventListener("click", () => react(message, emote));
    bar.append(pill);
  }

  // You can see reactions to your own message but not react to or report
  // yourself.
  if (mine) return bar;

  const actions = document.createElement("span");
  actions.className = "actions";

  // Reply rides the positive row and report the negative one, so each action
  // sits with the emotes of its own sign, and reply lands above report.
  const upper = emoteRow(message, reacted ? [] : state.emotes.positive.slice(0, QUICK_EMOTES), "positive");
  const lower = emoteRow(message, reacted ? [] : state.emotes.negative, "negative");

  if (!reacted) {
    upper.append(divider());
    lower.append(divider());
  }

  const reply = document.createElement("button");
  reply.type = "button";
  reply.textContent = "reply";
  reply.addEventListener("click", () => startReply(message));
  upper.append(reply);

  const report = document.createElement("button");
  report.type = "button";
  report.textContent = "report";
  report.addEventListener("click", () => reportUser(message.pubkey));
  lower.append(report);

  actions.append(upper, lower);
  bar.append(actions);
  return bar;
}

const divider = () => Object.assign(document.createElement("span"), { className: "divider" });

function emoteRow(message, emotes, kind) {
  const row = document.createElement("div");
  row.className = `emote-row ${kind}`;

  for (const emote of emotes) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = emote;
    button.title = kind === "negative" ? "Negative reaction" : "React";
    button.addEventListener("click", () => react(message, emote));
    row.append(button);
  }

  return row;
}

// One reaction per comment, which the server enforces too. The message's
// record hash is its id.
async function react(message, emote) {
  if (state.voted.has(message.hash)) return;

  if (polarityOf(emote) < 0) {
    const sure = await confirmAction(
      "Giving someone a negative emote will lower their reputation. Are you sure?",
      "Yes, react",
    );
    if (!sure) return;
  }

  const ts = Math.floor(Date.now() / 1000);
  const ack = currentAck();
  const payload = identity.emotePayload({
    pubkey: state.me.pubkey, room: ROOM, message: message.hash, emote, ack, ts,
  });

  try {
    await post(`/api/room/${ROOM}/emote`, {
      message: message.hash, emote, ack, ts,
      signature: await identity.sign(state.me, payload),
    });

    // Buckets do not move for emotes until the next login, by design; the
    // refresh only repaints the reaction counts.
    await countAsVote(message, polarityOf(emote));
    refreshMessages();
  } catch (error) {
    status($("chat-status"), error.message, "error");
  }
}

async function compose(event) {
  event.preventDefault();
  const body = $("body").value.trim();
  if (!body) return;

  const ts = Math.floor(Date.now() / 1000);
  const replyingTo = state.replyingTo;
  const replyTo = replyingTo ? replyingTo.hash : null;
  const ack = currentAck();
  const payload = identity.messagePayload({
    pubkey: state.me.pubkey, room: ROOM, body, ack, ts, replyTo,
  });

  try {
    await post(`/api/room/${ROOM}/message`, {
      body, ack, ts, reply_to: replyTo,
      signature: await identity.sign(state.me, payload),
    });
    $("body").value = "";
    cancelReply();

    // Replying counts like reacting: one vote per message either way, so
    // replying to something you already reacted to does not vote twice.
    if (replyingTo && replyingTo.pubkey !== state.me.pubkey) await countAsVote(replyingTo, 1);

    refreshMessages();
  } catch (error) {
    status($("chat-status"), error.message, "error");
  }
}

// Shared by reacting and replying. Does nothing if this message has already
// been voted on.
async function countAsVote(message, polarity) {
  if (state.voted.has(message.hash)) return;

  const current = state.ratings[message.pubkey] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[message.pubkey] = { ...current, net_votes: (current.net_votes || 0) + polarity };
  state.voted.add(message.hash);
  touch();

  scoreChanged();
  await publishIfDue();
  vaultChanged();
}

// --- profiles ----------------------------------------------------------

function showPanel(id) {
  for (const panel of ["login", "chat", "profile"]) $(panel).classList.toggle("hidden", panel !== id);
}

function showProfile(pubkey) {
  state.viewing = pubkey;
  const own = pubkey === state.me.pubkey;
  const profile = state.profiles?.get(pubkey) || { handle: "someone", bio: "", icon: null };

  $("profile-title").textContent = own ? "Your profile" : "Profile";
  $("profile-edit").classList.toggle("hidden", !own);
  $("profile-view").classList.toggle("hidden", own);
  $("breakdown").replaceChildren();
  status($("profile-status"), "");

  if (own) {
    $("my-username").value = state.profile.handle;
    $("my-message").value = state.profile.bio || "";
    $("my-key").value = pubkey;
    $("show-unrated").checked = Boolean(state.settings.display?.show_unrated);
    $("add-key").value = "";
    $("my-avatar").replaceChildren(avatarFor(pubkey, "avatar-large", state.profile.icon));
    renderRelations();
  } else {
    // iconFor rather than the fetched profile's icon, so an account with no
    // declaration to fetch -- a default friend -- still has a face here.
    $("profile-icon").replaceChildren(avatarFor(pubkey, "avatar-large"));
    $("profile-name").textContent = profile.handle || "someone";
    $("profile-fp").textContent = fingerprint(pubkey);
    $("profile-message").textContent = profile.bio || "";
    $("profile-bucket").textContent = `Currently ${state.session.bucketOf(pubkey)} this session.`;
  }

  showPanel("profile");
}

async function friendUser() {
  const pubkey = state.viewing;
  const current = state.ratings[pubkey] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[pubkey] = { ...current, friend: true, reported: false };

  scoreChanged();
  await publishIfDue();
  status($("profile-status"), "Friended. This takes full effect at your next login.", "ok");
}

// Used wherever a click has a consequence that is not obvious from the button.
// Resolves false on Escape or the backdrop.
function confirmAction(message, confirmLabel) {
  const dialog = $("confirm");
  $("confirm-text").textContent = message;
  $("confirm-yes").textContent = confirmLabel;

  return new Promise((resolve) => {
    const finish = (answer) => {
      dialog.close();
      resolve(answer);
    };

    $("confirm-yes").onclick = () => finish(true);
    $("confirm-no").onclick = () => finish(false);
    dialog.addEventListener("close", () => resolve(false), { once: true });
    dialog.showModal();
  });
}

async function reportUser(pubkey) {
  const target = pubkey || state.viewing;
  const sure = await confirmAction(
    `Report ${displayName(target)}? You will stop seeing their messages.`, "Report",
  );
  if (!sure) return;
  const current = state.ratings[target] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[target] = { ...current, friend: false, reported: true };

  scoreChanged();
  await publishIfDue();
  // Your own report blocks at once — waiting a whole session defeats the point.
  state.session.report(target, state.me.pubkey);
  state.recentlyBlocked.set(target, Date.now());
  touch();
  refreshMessages();

  if (state.viewing === target) {
    renderRelations();
    status($("profile-status"), "Reported and blocked.", "ok");
  }
}

// `confirm` defaults on, so a call site added later asks by default. The undo
// beside a just-blocked message passes it off: that one exists for a misclick,
// and a dialog guarding an undo is a dialog guarding the wrong direction.
async function undoReport(pubkey, { confirm = true } = {}) {
  if (confirm) {
    const sure = await confirmAction(
      `Unblock ${displayName(pubkey)}? Their messages become visible to you again.`,
      "Yes, unblock",
    );
    if (!sure) return;
  }

  const current = state.ratings[pubkey];
  if (current) state.ratings[pubkey] = { ...current, reported: false };

  scoreChanged();
  await publishIfDue();
  state.session.unreport(pubkey, state.me.pubkey);
  state.recentlyBlocked.delete(pubkey);
  touch();

  refreshMessages();
  renderRelations();
  status($("chat-status"), "Report undone.", "ok");
}

async function unfriend(pubkey) {
  const sure = await confirmAction(
    `Remove ${displayName(pubkey)} from your friends? Everything they vouch for ` +
    "stops reaching you, and anyone only they made visible becomes invisible.",
    "Yes, unfriend",
  );
  if (!sure) return;

  const current = state.ratings[pubkey];
  if (current) state.ratings[pubkey] = { ...current, friend: false };
  forgetFriend(pubkey);
  vaultChanged();

  scoreChanged();
  await publishIfDue();
  renderRelations();
  // Only reports move people mid-session; everything else waits for the next
  // login, so their bucket is deliberately left alone here.
  status($("profile-status"), "Unfriended. Takes effect at your next login.", "ok");
}

// Who you have friended and who you have blocked, each with a way back.
function renderRelations() {
  recomputeNames();
  fillRelations($("friend-list"), ([, r]) => r.friend, "unfriend", unfriend, friendsInOrder());
  fillRelations($("blocked-list"), ([, r]) => r.reported, "unblock", undoReport);
  renderRatings();
}

// Everyone you have rated directly, and what that rating comes to. Only your
// own actions count here -- nothing inherited through the social graph.
function renderRatings() {
  const box = $("rating-list");
  box.replaceChildren();

  const entries = Object.entries(state.ratings)
    .filter(([, r]) => r.friend || r.reported || r.cleared || (r.net_votes || 0) !== 0)
    .sort((a, b) => Number(state.reputation.ratingValue(b[1]) - state.reputation.ratingValue(a[1])));

  if (!entries.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "none";
    return box.append(empty);
  }

  for (const [pubkey, rating] of entries) {
    const row = document.createElement("div");
    row.className = "row";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = displayName(pubkey);

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(pubkey);

    const score = document.createElement("span");
    score.className = "score";
    score.textContent = toNumber(state.reputation.ratingValue(rating)).toFixed(4);

    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary";
    button.textContent = "remove";
    // Friending and reporting are deliberate and outrank a reset, so there is
    // nothing for this to do until one of them is undone above.
    button.disabled = Boolean(rating.friend || rating.reported);
    button.title = button.disabled ? "unfriend or unblock them first" : "set their rating to zero";
    button.addEventListener("click", () => clearRating(pubkey).catch(
      (e) => status($("profile-status"), e.message, "error"),
    ));

    row.append(name, fp, score, button);
    box.append(row);
  }
}

// Pins someone to zero. `cleared` survives later emotes and replies, so this
// is not undone the next time they are voted on.
async function clearRating(pubkey) {
  const current = state.ratings[pubkey] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[pubkey] = { ...current, cleared: true };

  scoreChanged();
  await publishIfDue();
  renderRatings();
  status($("profile-status"), "Rating removed.", "ok");
}

function fillRelations(box, predicate, verb, action, order = null) {
  const entries = Object.entries(state.ratings).filter(predicate);
  // The stored ratings come back in public-key order, because canonical
  // serialization sorts. Anything that should read as "first added" has to be
  // sorted by the order the vault remembers.
  if (order) {
    const position = new Map(order.map((pubkey, index) => [pubkey, index]));
    entries.sort((a, b) => (position.get(a[0]) ?? Infinity) - (position.get(b[0]) ?? Infinity));
  }
  box.replaceChildren();

  if (!entries.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "none";
    return box.append(empty);
  }

  for (const [pubkey] of entries) {
    const row = document.createElement("div");
    row.className = "row";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = displayName(pubkey);
    // The avatar enlarges now, so the name is what opens a profile -- which is
    // already how a message row behaves.
    name.addEventListener("click", () => showProfile(pubkey));

    // The whole key, not a fingerprint. This is the list where somebody
    // checks that the person they vouched for is the person they meant, and a
    // prefix is exactly what an impersonator would match.
    const key = document.createElement("span");
    key.className = "pubkey";
    key.textContent = pubkey;

    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary";
    button.textContent = verb;
    button.addEventListener("click", () => action(pubkey).catch(
      (e) => status($("profile-status"), e.message, "error"),
    ));

    row.append(avatarFor(pubkey), name, key, button);
    box.append(row);
  }
}

async function copyKey() {
  try {
    await navigator.clipboard.writeText(state.me.pubkey);
    status($("profile-status"), "Key copied.", "ok");
  } catch {
    // Clipboard access needs a secure context and permission; selecting the
    // text is always available.
    $("my-key").select();
    status($("profile-status"), "Press Ctrl+C to copy the selected key.");
  }
}

async function addByKey() {
  const pubkey = $("add-key").value.trim();
  if (!PUBKEY.test(pubkey)) return status($("profile-status"), "that does not look like a key", "error");
  if (pubkey === state.me.pubkey) return status($("profile-status"), "that is your own key", "error");

  const current = state.ratings[pubkey] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[pubkey] = { ...current, friend: true, reported: false };
  rememberFriend(pubkey);
  state.seen = names.forget(state.seen, pubkey);
  vaultChanged();

  scoreChanged();
  await publishIfDue();
  await fetchConfigs([pubkey]);
  rebuildSession();
  touch();
  refreshMessages();

  $("add-key").value = "";
  renderRelations();
  status($("profile-status"), `Added. They are now ${state.session.bucketOf(pubkey)}.`, "ok");
}

// Rebuilds rather than just re-rendering: the bucket a user lands in depends on
// the setting, so everyone has to be sorted again.
async function toggleUnrated() {
  state.settings = deepMerge(state.settings, {
    display: { show_unrated: $("show-unrated").checked },
  });
  vaultChanged();

  state.reputation = buildReputation();
  rebuildSession();
  touch();
  refreshMessages();

  const count = state.session.in("tolerated").length;
  status($("profile-status"),
         $("show-unrated").checked
           ? `Showing unrated users — ${count} in Tolerated now.`
           : "Hiding unrated users again.",
         "ok");
}

// Re-derives the score and shows which hop and which person produced each
// part of it. The session discards scores by design, so this recomputes.
function recalculate() {
  const result = state.session.explain(state.viewing);
  const box = $("breakdown");
  box.replaceChildren();

  const total = document.createElement("p");
  total.textContent = `Effective reputation ${toNumber(result.effective).toFixed(6)} — ${result.bucket}`;
  box.append(total);

  if (!result.levels.length) {
    const none = document.createElement("p");
    none.textContent = "Nobody in your network has rated them.";
    return box.append(none);
  }

  const table = document.createElement("table");
  const head = document.createElement("tr");
  for (const label of ["hops", "weight", "raters", "mean", "contribution"]) {
    const th = document.createElement("th");
    th.textContent = label;
    head.append(th);
  }
  table.append(head);

  for (const level of result.levels) {
    const row = document.createElement("tr");
    const cells = [
      String(level.hops),
      toNumber(level.weight).toFixed(6),
      level.raters.map((r) => `${displayName(r.pubkey)}(${fingerprint(r.pubkey)})${r.reported ? " reported" : ""}`).join(", "),
      toNumber(level.mean).toFixed(4),
      toNumber(level.contribution).toFixed(8),
    ];
    for (const value of cells) {
      const td = document.createElement("td");
      td.textContent = value;
      row.append(td);
    }
    table.append(row);
  }

  box.append(table);
}

async function saveProfile() {
  const username = $("my-username").value.trim();
  if (!username) return status($("profile-status"), "a display name is required", "error");

  state.profile = {
    handle: username, bio: $("my-message").value.trim(), icon: state.profile.icon,
  };

  const file = $("my-icon").files[0];
  if (file) {
    try {
      const { icon } = await api("/api/image", { method: "POST", body: file });
      state.profile.icon = icon;
    } catch (error) {
      return status($("profile-status"), error.message, "error");
    }
  }

  await publishIdentity();
  state.profiles.set(state.me.pubkey, state.profile);
  $("me").textContent = `${state.profile.handle} · ${fingerprint(state.me.pubkey)}`;
  $("my-avatar").replaceChildren(avatarFor(state.me.pubkey, "avatar-large", state.profile.icon));
  $("my-icon").value = "";
  touch();
  refreshMessages();
  status($("profile-status"), "Saved.", "ok");
}

// --- boot ---------------------------------------------------------------

async function boot() {
  let host;
  [state.config, state.emotes, state.genesis, host, state.limits] = await Promise.all([
    api("/api/defaults"), api("/api/emotes"), api("/api/genesis"), api("/api/host"),
    api("/api/limits"),
  ]);
  state.host = host.host;
  state.reputation = buildReputation();
  await seed.loadWordlist();

  // Changing the seed invalidates the key derived from the previous one.
  $("seed").addEventListener("input", () => {
    state.pendingRegistration = false;
    refreshSeedField();
  });
  $("login-form").addEventListener("submit", unlock);
  $("logout").addEventListener("click", logOff);
  $("composer").addEventListener("submit", compose);
  $("cancel-reply").addEventListener("click", cancelReply);
  $("my-profile").addEventListener("click", () => showProfile(state.me.pubkey));
  $("profile-close").addEventListener("click", () => showPanel("chat"));
  $("profile-friend").addEventListener("click", () => friendUser().catch((e) => status($("profile-status"), e.message, "error")));
  $("profile-report").addEventListener("click", () => reportUser().catch((e) => status($("profile-status"), e.message, "error")));
  $("profile-recalc").addEventListener("click", recalculate);
  $("profile-save").addEventListener("click", () => saveProfile().catch((e) => status($("profile-status"), e.message, "error")));
  $("copy-key").addEventListener("click", copyKey);
  $("add-friend").addEventListener("click", () => addByKey().catch((e) => status($("profile-status"), e.message, "error")));
  $("show-unrated").addEventListener("change",
    () => toggleUnrated().catch((e) => status($("profile-status"), e.message, "error")));

  // The seed is shown but deliberately NOT typed into the field: copying it
  // across is what makes someone keep a copy of it.
  $("new-name").addEventListener("input", refreshSeedField);

  $("generate").addEventListener("click", () => startNewAccount());
  $("new-friend-add").addEventListener("click", () => addNewFriend());
  $("new-friend-key").addEventListener("keydown", (event) => {
    // Enter in this field must not submit the login form and create the
    // account with a key half typed.
    if (event.key !== "Enter") return;
    event.preventDefault();
    addNewFriend();
  });
  window.addEventListener("popstate", renderRoute);

  // Hidden rather than unloading: a phone backgrounding a tab may never fire
  // an unload event at all, and this one it does fire.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") pushVault().catch(() => {});
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") hideLarge();
  });

  $("copy-seed").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("new-seed-words").value);
      status($("seed-status"), "Seed copied — now paste it below.", "ok");
    } catch {
      $("new-seed-words").select();
      status($("seed-status"), "Press Ctrl+C to copy the selected seed.");
    }
  });

  // A remembered key survives a refresh, which is not a log off.
  const remembered = await identity.recall();
  if (remembered) {
    try {
      await signIn(remembered, { restoring: true });
    } catch {
      await identity.forget();
    }
  }

  // Landing on /new-account directly, or after a refresh, needs a seed to show.
  if (!state.me && creatingAccount()) await startNewAccount();
  renderRoute();
}

boot().catch((error) => status($("seed-status"), error.message, "error"));
