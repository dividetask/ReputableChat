// UI wiring. The interesting parts live in identity.js (keys and signing),
// reputation.js (scoring) and session.js (buckets); this file moves data
// between them.

import * as seed from "./seed.js";
import * as identity from "./identity.js";
import { Reputation, Graph, toNumber, toFixed } from "./reputation.js";
import { Session } from "./session.js";
import { initialRatings, genesisProfile } from "./defaults.js";

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
  seq: 0, voted: new Set(), viewing: null, settings: {}, privateRevision: 0,
  reactions: new Map(), recentlyBlocked: new Map(), replyingTo: null,
  genesis: null, tip: null, newFriends: {},
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

// The bar is the viewer's own, read through the viewer's own config, so two
// people disagree about which references were legitimate and no server can
// settle it. Acknowledging only people you rate is what leaves new and
// low-reputation accounts unanchored -- see docs/project/chain.md.
function chooseTip(messages) {
  if (!state.session) return null;

  const bar = toFixed(state.config.chain.min_reputation_to_acknowledge);

  for (let i = messages.length - 1; i >= 0; i--) {
    const { author, hash } = messages[i];
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

// --- private config ----------------------------------------------------
//
// Settings and the voted list live on the server so they survive a new device,
// and are signed so tampering with them is detectable. Note that signed is not
// encrypted: this is private from other users, not from the server operator.

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

async function loadPrivateConfig() {
  const { config } = await api("/api/private-config");

  state.settings = {};
  state.voted = new Set();
  state.privateRevision = 0;
  if (!config) return;

  // Verified even though the MVP takes other people's configs on trust --
  // detecting tampering is the entire reason this one is signed.
  if (!(await identity.verifyBlob(state.me.pubkey, config))) {
    return status($("chat-status"),
                  "Your saved settings did not verify and were ignored.", "error");
  }

  const payload = JSON.parse(config.payload);
  state.privateRevision = payload.revision || 0;
  state.settings = payload.settings || {};
  state.voted = new Set(payload.voted || []);
}

async function publishPrivateConfig() {
  state.privateRevision += 1;
  const ts = Math.floor(Date.now() / 1000);
  const voted = [...state.voted];
  const payload = identity.privateConfigPayload({
    pubkey: state.me.pubkey, revision: state.privateRevision,
    settings: state.settings, voted, ts,
  });

  await send("PUT", "/api/private-config", {
    revision: state.privateRevision, settings: state.settings, voted, ts,
    signature: await identity.sign(state.me, payload),
  });
}

// Re-sorts everyone from the graph already in hand. In-session reports are
// replayed so a toggle does not quietly un-block someone.
function rebuildSession() {
  const previous = state.session ? [...state.session.reports] : [];

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

// Before login there are no fetched profiles, so the only name available is the
// genesis account's, out of the declaration already in hand.
function newAccountName(pubkey) {
  if (state.genesis && pubkey === state.genesis.pubkey) {
    return genesisProfile(state.genesis)?.username || "the genesis account";
  }
  return "unknown";
}

function resetNewFriends() {
  state.newFriends = initialRatings({
    genesisPubkey: state.genesis?.pubkey,
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

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(pubkey);

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "secondary";
    remove.textContent = "remove";
    remove.addEventListener("click", () => removeNewFriend(pubkey));

    row.append(avatarFor(pubkey, "", null), name, fp, remove);
    box.append(row);
  }
}

// Removing the genesis account here is the one choice on this screen with a
// consequence somebody might not have in mind, so it is the one that asks.
// Removing a key pasted in ten seconds ago is not worth a dialog.
async function removeNewFriend(pubkey) {
  if (state.genesis && pubkey === state.genesis.pubkey) {
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

  await publishConfig();
  await enterChat();
}



async function logOff() {
  await identity.forget();
  location.reload();
}

// --- config ------------------------------------------------------------

// Every change to friends, reports or emote tallies is re-signed and
// re-uploaded. The revision must climb or the server rejects it as a rollback.
async function publishConfig() {
  state.revision += 1;
  const ts = Math.floor(Date.now() / 1000);
  const payload = identity.configPayload({
    pubkey: state.me.pubkey, revision: state.revision,
    profile: state.profile, ratings: state.ratings, ts,
  });

  await send("PUT", "/api/config", {
    revision: state.revision, profile: state.profile, ratings: state.ratings,
    ts, signature: await identity.sign(state.me, payload),
  });
}

function parseConfig(blob) {
  if (!blob) return null;
  try {
    return JSON.parse(blob.payload);
  } catch {
    return null;
  }
}

async function loadOwnConfig() {
  const { config } = await api(`/api/config/${state.me.pubkey}`);
  const payload = parseConfig(config);

  state.revision = payload ? payload.revision : 0;
  state.ratings = payload?.ratings || {};
  state.profile = payload?.profile || { username: "anonymous", message: "", icon: null };
}

// Walks outward from the viewer, fetching a whole hop per request. Bounded by
// max_hops and max_configs together: a positive-only graph still branches, so
// hop count alone does not bound the fetch.
async function loadNetwork() {
  const { max_hops: maxHops, max_configs: maxConfigs } = state.config.ladder;
  state.graph = new Graph();
  state.graph.add(state.me.pubkey, state.ratings);
  state.profiles = new Map([[state.me.pubkey, state.profile]]);

  // The genesis account has no config to fetch, so its name comes from the
  // declaration already in hand. Seeded before the walk, so a config it has
  // published since wins over it.
  const genesis = genesisProfile(state.genesis);
  if (genesis) state.profiles.set(state.genesis.pubkey, genesis);

  let frontier = [state.me.pubkey];
  const seen = new Set(frontier);

  for (let hop = 0; hop < maxHops && seen.size < maxConfigs; hop++) {
    const wanted = [];

    for (const rater of frontier) {
      for (const [subject, rating] of Object.entries(state.graph.ratingsBy(rater))) {
        if (seen.has(subject) || seen.size + wanted.length >= maxConfigs) continue;
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
  const { configs } = await post("/api/config/batch", { pubkeys: fresh });

  for (const blob of configs) {
    const payload = parseConfig(blob);
    if (!payload || payload.pubkey !== blob.pubkey) continue;

    state.graph.add(blob.pubkey, payload.ratings || {});
    state.profiles.set(blob.pubkey, payload.profile || null);
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

  await loadPrivateConfig();
  state.reputation = buildReputation();
  await loadOwnConfig();
  await loadNetwork();
  rebuildSession();

  $("me").textContent = `${state.profile.username} · ${fingerprint(state.me.pubkey)}`;
  refreshMessages();
  setInterval(refreshMessages, 4000);
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

  await fetchConfigs([...new Set([...messages.map((m) => m.author), ...emotes.map((e) => e.author)])]);
  state.seq = Math.max(0, ...messages.filter((m) => m.author === state.me.pubkey).map((m) => m.seq));
  state.tip = chooseTip(messages);

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
    emotes.map((e) => `${e.message}${e.emote}${e.author}`).join(","),
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
    const mine = message.author === state.me.pubkey;
    const bucket = mine ? "trusted" : state.session.bucketOf(message.author);

    if (bucket === "blocked") {
      // Someone you blocked moments ago leaves a stub you can undo. Everyone
      // else blocked simply is not here.
      if (withinUndoWindow(message.author)) list.append(blockedStub(message));
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
    who.textContent = displayName(message.author);
    who.addEventListener("click", () => showProfile(message.author));

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(message.author);

    const body = document.createElement("div");
    body.textContent = payload.body; // textContent, never innerHTML

    if (payload.reply_to) main.append(replyQuote(payload.reply_to, byHash));
    main.append(who, fp, body, reactionBar(message, mine));
    row.append(avatarFor(message.author), main);
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

  for (const { message, emote, author } of emotes) {
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
  undo.addEventListener("click", () => undoReport(message.author, { confirm: false }).catch(
    (e) => status($("chat-status"), e.message, "error"),
  ));
  actions.append(undo);

  row.append(label, actions);
  return row;
}

// Names are not unique, so an avatar derived from the key gives every person a
// stable look even before they upload one. Same key, same colour, always.
function avatarFor(pubkey, extra = "", icon = state.profiles?.get(pubkey)?.icon) {
  // An <img> with an empty src resolves to the page URL and renders as a
  // broken image, so anyone without an icon gets the placeholder instead.
  if (icon) {
    const img = document.createElement("img");
    img.className = `avatar ${extra}`.trim();
    img.src = `/images/${icon}`;
    img.alt = "";
    img.addEventListener("click", () => showProfile(pubkey));
    return img;
  }

  let hash = 0;
  for (const character of pubkey) hash = ((hash * 31) + character.charCodeAt(0)) >>> 0;

  const placeholder = document.createElement("span");
  placeholder.className = `avatar placeholder ${extra}`.trim();
  placeholder.style.background = `hsl(${hash % 360} 42% 30%)`;
  placeholder.textContent = pubkey.slice(0, 2);
  placeholder.addEventListener("click", () => showProfile(pubkey));
  return placeholder;
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
  name.textContent = displayName(target.author);

  const snippet = document.createElement("span");
  snippet.className = "snippet";
  snippet.textContent = body;

  quote.append(arrow, avatarFor(target.author), name, snippet);
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
  $("replying-to").textContent = `Replying to ${displayName(message.author)}`;
  $("body").focus();
}

function cancelReply() {
  state.replyingTo = null;
  $("replying").classList.add("hidden");
}

function displayName(pubkey) {
  return state.profiles?.get(pubkey)?.username || "someone";
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
  report.addEventListener("click", () => reportUser(message.author));
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
    author: state.me.pubkey, room: ROOM, message: message.hash, emote, ack, ts,
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
  const seq = state.seq + 1;
  const replyingTo = state.replyingTo;
  const replyTo = replyingTo ? replyingTo.hash : null;
  const ack = currentAck();
  const payload = identity.messagePayload({
    author: state.me.pubkey, room: ROOM, seq, prev: null, body, ack, ts, replyTo,
  });

  try {
    await post(`/api/room/${ROOM}/message`, {
      seq, prev: null, body, ack, ts, reply_to: replyTo,
      signature: await identity.sign(state.me, payload),
    });
    $("body").value = "";
    state.seq = seq;
    cancelReply();

    // Replying counts like reacting: one vote per message either way, so
    // replying to something you already reacted to does not vote twice.
    if (replyingTo && replyingTo.author !== state.me.pubkey) await countAsVote(replyingTo, 1);

    refreshMessages();
  } catch (error) {
    status($("chat-status"), error.message, "error");
  }
}

// Shared by reacting and replying. Does nothing if this message has already
// been voted on.
async function countAsVote(message, polarity) {
  if (state.voted.has(message.hash)) return;

  const current = state.ratings[message.author] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[message.author] = { ...current, net_votes: (current.net_votes || 0) + polarity };
  state.voted.add(message.hash);
  touch();

  await publishConfig();
  await publishPrivateConfig();
}

// --- profiles ----------------------------------------------------------

function showPanel(id) {
  for (const panel of ["login", "chat", "profile"]) $(panel).classList.toggle("hidden", panel !== id);
}

function showProfile(pubkey) {
  state.viewing = pubkey;
  const own = pubkey === state.me.pubkey;
  const profile = state.profiles?.get(pubkey) || { username: "someone", message: "", icon: null };

  $("profile-title").textContent = own ? "Your profile" : "Profile";
  $("profile-edit").classList.toggle("hidden", !own);
  $("profile-view").classList.toggle("hidden", own);
  $("breakdown").replaceChildren();
  status($("profile-status"), "");

  if (own) {
    $("my-username").value = state.profile.username;
    $("my-message").value = state.profile.message || "";
    $("my-key").value = pubkey;
    $("show-unrated").checked = Boolean(state.settings.display?.show_unrated);
    $("add-key").value = "";
    $("my-avatar").replaceChildren(avatarFor(pubkey, "avatar-large", state.profile.icon));
    renderRelations();
  } else {
    $("profile-icon").replaceChildren(avatarFor(pubkey, "avatar-large", profile.icon));
    $("profile-name").textContent = profile.username || "someone";
    $("profile-fp").textContent = fingerprint(pubkey);
    $("profile-message").textContent = profile.message || "";
    $("profile-bucket").textContent = `Currently ${state.session.bucketOf(pubkey)} this session.`;
  }

  showPanel("profile");
}

async function friendUser() {
  const pubkey = state.viewing;
  const current = state.ratings[pubkey] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[pubkey] = { ...current, friend: true, reported: false };

  await publishConfig();
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

  await publishConfig();
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

  await publishConfig();
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

  await publishConfig();
  renderRelations();
  // Only reports move people mid-session; everything else waits for the next
  // login, so their bucket is deliberately left alone here.
  status($("profile-status"), "Unfriended. Takes effect at your next login.", "ok");
}

// Who you have friended and who you have blocked, each with a way back.
function renderRelations() {
  fillRelations($("friend-list"), ([, r]) => r.friend, "unfriend", unfriend);
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

  await publishConfig();
  renderRatings();
  status($("profile-status"), "Rating removed.", "ok");
}

function fillRelations(box, predicate, verb, action) {
  const entries = Object.entries(state.ratings).filter(predicate);
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

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(pubkey);

    const button = document.createElement("button");
    button.type = "button";
    button.className = "secondary";
    button.textContent = verb;
    button.addEventListener("click", () => action(pubkey).catch(
      (e) => status($("profile-status"), e.message, "error"),
    ));

    row.append(avatarFor(pubkey), name, fp, button);
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

  await publishConfig();
  await fetchConfigs([pubkey]);
  rebuildSession();
  touch();
  refreshMessages();

  $("add-key").value = "";
  status($("profile-status"), `Added. They are now ${state.session.bucketOf(pubkey)}.`, "ok");
}

// Rebuilds rather than just re-rendering: the bucket a user lands in depends on
// the setting, so everyone has to be sorted again.
async function toggleUnrated() {
  state.settings = deepMerge(state.settings, {
    display: { show_unrated: $("show-unrated").checked },
  });
  await publishPrivateConfig();

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
    username, message: $("my-message").value.trim(), icon: state.profile.icon,
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

  await publishConfig();
  state.profiles.set(state.me.pubkey, state.profile);
  $("me").textContent = `${state.profile.username} · ${fingerprint(state.me.pubkey)}`;
  $("my-avatar").replaceChildren(avatarFor(state.me.pubkey, "avatar-large", state.profile.icon));
  $("my-icon").value = "";
  touch();
  refreshMessages();
  status($("profile-status"), "Saved.", "ok");
}

// --- boot ---------------------------------------------------------------

async function boot() {
  [state.config, state.emotes, state.genesis] = await Promise.all([
    api("/api/defaults"), api("/api/emotes"), api("/api/genesis"),
  ]);
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
