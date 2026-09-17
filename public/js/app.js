// UI wiring. The interesting parts live in identity.js (keys and signing),
// reputation.js (scoring) and session.js (buckets); this file moves data
// between them.

import * as seed from "./seed.js";
import * as identity from "./identity.js";
import { Reputation, Graph, toNumber } from "./reputation.js";
import { Session } from "./session.js";

const ROOM = "general";
const VOTED_KEY = "reputablechat.voted";
const PREFS_KEY = "reputablechat.prefs";
const PUBKEY = /^[A-Za-z0-9_-]{42,44}$/;
const $ = (id) => document.getElementById(id);

const state = {
  config: null, emotes: null, me: null, profile: null, version: 0,
  ratings: {}, graph: new Graph(), reputation: null, session: null,
  seq: 0, voted: new Set(), viewing: null, prefs: { showUnrated: false },
};

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

// Per-viewer convenience only, so localStorage is the right home. Wrapped
// because it throws in private windows and with site data blocked.
function loadVoted() {
  try {
    return new Set(JSON.parse(localStorage.getItem(VOTED_KEY) || "[]"));
  } catch {
    return new Set();
  }
}

function saveVoted() {
  try {
    localStorage.setItem(VOTED_KEY, JSON.stringify([...state.voted]));
  } catch {
    /* nothing to do: double-vote protection degrades, nothing breaks */
  }
}

// show_unrated is a per-viewer preference, not something anyone else reads, so
// localStorage is its right home. It moves to the private config once that
// exists.
function loadPrefs() {
  try {
    return { showUnrated: false, ...JSON.parse(localStorage.getItem(PREFS_KEY) || "{}") };
  } catch {
    return { showUnrated: false };
  }
}

function savePrefs() {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(state.prefs));
  } catch {
    /* the preference just will not persist */
  }
}

// The viewer's preference is layered over the server defaults, which is the
// same shape the config system uses everywhere else.
function buildReputation() {
  return new Reputation({
    ...state.config,
    display: { ...state.config.display, show_unrated: state.prefs.showUnrated },
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

async function refreshSeedField() {
  const phrase = $("seed").value;
  const words = seed.words(phrase);
  const reason = phrase.trim() ? await seed.validate(phrase, state.config.seed.min_words) : "type your seed";

  $("unlock").disabled = reason !== null;
  status($("seed-status"), reason || `${words.length} words · looks good`, reason ? "" : "ok");

  const partial = phrase.endsWith(" ") ? "" : words[words.length - 1];
  const box = $("suggestions");
  box.replaceChildren();
  if (!partial || partial.length < 2) return;

  for (const word of await seed.suggest(partial, 6)) {
    if (word === partial) continue;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = word;
    button.addEventListener("click", () => {
      $("seed").value = `${[...words.slice(0, -1), word].join(" ")} `;
      $("seed").focus();
      refreshSeedField();
    });
    box.append(button);
  }
}

// --- login -------------------------------------------------------------

async function unlock() {
  $("unlock").disabled = true;
  status($("seed-status"), "deriving your key — this takes a moment by design…");

  try {
    const derived = await identity.deriveFromSeed($("seed").value, state.config.seed.kdf);
    $("seed").value = ""; // the seed has done its job
    await signIn(derived);
  } catch (error) {
    status($("seed-status"), error.message, "error");
    $("unlock").disabled = false;
  }
}

async function signIn(derived) {
  const { nonce } = await post("/api/challenge", {});
  const ts = Math.floor(Date.now() / 1000);
  const payload = identity.loginPayload({
    pubkey: derived.pubkey, nonce, origin: window.location.origin, ts,
  });

  const session = await post("/api/session", {
    pubkey: derived.pubkey, nonce, ts, signature: await identity.sign(derived, payload),
  });

  state.me = derived;
  await identity.remember({ privateKey: derived.privateKey, pubkey: derived.pubkey });

  if (session.registered) return enterChat();

  $("register").classList.remove("hidden");
  status($("seed-status"), "");
}

async function createAccount() {
  const username = $("username").value.trim();
  if (!username) return status($("seed-status"), "pick a display name", "error");

  await post("/api/register", {});
  state.profile = { username, message: "", icon: null };
  await publishConfig();
  enterChat();
}

async function logOff() {
  await identity.forget();
  location.reload();
}

// --- config ------------------------------------------------------------

// Every change to friends, reports or emote tallies is re-signed and
// re-uploaded. The version must climb or the server rejects it as a rollback.
async function publishConfig() {
  state.version += 1;
  const ts = Math.floor(Date.now() / 1000);
  const payload = identity.configPayload({
    pubkey: state.me.pubkey, version: state.version,
    profile: state.profile, ratings: state.ratings, ts,
  });

  await send("PUT", "/api/config", {
    version: state.version, profile: state.profile, ratings: state.ratings,
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

  state.version = payload ? payload.version : 0;
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
}

// --- chat --------------------------------------------------------------

async function enterChat() {
  $("login").classList.add("hidden");
  $("chat").classList.remove("hidden");
  state.voted = loadVoted();

  await loadOwnConfig();
  await loadNetwork();
  rebuildSession();

  $("me").textContent = `${state.profile.username} · ${fingerprint(state.me.pubkey)}`;
  refreshMessages();
  setInterval(refreshMessages, 4000);
}

async function refreshMessages() {
  let messages;
  try {
    ({ messages } = await api(`/api/room/${ROOM}/messages`));
  } catch (error) {
    return status($("chat-status"), error.message, "error");
  }

  await fetchConfigs([...new Set(messages.map((m) => m.author))]);
  render(messages);
  state.seq = Math.max(0, ...messages.filter((m) => m.author === state.me.pubkey).map((m) => m.seq));
}

function render(messages) {
  const list = $("messages");
  list.replaceChildren();

  for (const message of messages) {
    const mine = message.author === state.me.pubkey;
    const bucket = mine ? "trusted" : state.session.bucketOf(message.author);
    if (bucket === "blocked") continue;

    let payload;
    try {
      payload = JSON.parse(message.payload);
    } catch {
      continue;
    }

    const row = document.createElement("div");
    row.className = `msg ${bucket}`;

    const who = document.createElement("span");
    who.className = "who";
    who.textContent = displayName(message.author);
    who.addEventListener("click", () => showProfile(message.author));

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(message.author);

    const body = document.createElement("div");
    body.textContent = payload.body; // textContent, never innerHTML

    row.append(who, fp, body);
    if (!mine) row.append(emoteBar(message));
    list.append(row);
  }

  list.scrollTop = list.scrollHeight;
}

function displayName(pubkey) {
  return state.profiles?.get(pubkey)?.username || "someone";
}

function emoteBar(message) {
  const bar = document.createElement("div");
  bar.className = "emotes";
  const choices = [...state.emotes.positive.slice(0, 6), ...state.emotes.negative];

  for (const emote of choices) {
    const polarity = state.emotes.negative.includes(emote) ? -1 : 1;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = emote;
    if (state.voted.has(message.signature)) button.classList.add("voted");
    button.addEventListener("click", () => emote_(message, polarity));
    bar.append(button);
  }

  const report = document.createElement("button");
  report.type = "button";
  report.textContent = "report";
  report.addEventListener("click", () => reportUser(message.author));
  bar.append(report);

  return bar;
}

// One vote per comment. The signature is its id.
async function emote_(message, polarity) {
  if (state.voted.has(message.signature)) return;

  const current = state.ratings[message.author] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[message.author] = { ...current, net_votes: current.net_votes + polarity };

  state.voted.add(message.signature);
  saveVoted();

  try {
    // Buckets do not move for emotes until the next login, by design; the
    // refresh only repaints the comment as voted.
    await publishConfig();
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
  const payload = identity.messagePayload({
    author: state.me.pubkey, room: ROOM, seq, prev: null, body, ts,
  });

  try {
    await post(`/api/room/${ROOM}/message`, {
      seq, prev: null, body, ts, signature: await identity.sign(state.me, payload),
    });
    $("body").value = "";
    state.seq = seq;
    refreshMessages();
  } catch (error) {
    status($("chat-status"), error.message, "error");
  }
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
    $("show-unrated").checked = state.prefs.showUnrated;
    $("add-key").value = "";
  } else {
    $("profile-icon").src = profile.icon ? `/images/${profile.icon}` : "";
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

async function reportUser(pubkey) {
  const target = pubkey || state.viewing;
  const current = state.ratings[target] || { friend: false, reported: false, net_votes: 0 };
  state.ratings[target] = { ...current, friend: false, reported: true };

  await publishConfig();
  // Your own report blocks at once — waiting a whole session defeats the point.
  state.session.report(target, state.me.pubkey);
  refreshMessages();

  if (state.viewing === target) status($("profile-status"), "Reported and blocked.", "ok");
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
  refreshMessages();

  $("add-key").value = "";
  status($("profile-status"), `Added. They are now ${state.session.bucketOf(pubkey)}.`, "ok");
}

// Rebuilds rather than just re-rendering: the bucket a user lands in depends on
// the setting, so everyone has to be sorted again.
function toggleUnrated() {
  state.prefs.showUnrated = $("show-unrated").checked;
  savePrefs();

  state.reputation = buildReputation();
  rebuildSession();
  refreshMessages();

  const count = state.session.in("tolerated").length;
  status($("profile-status"),
         state.prefs.showUnrated
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
  status($("profile-status"), "Saved.", "ok");
}

// --- boot ---------------------------------------------------------------

async function boot() {
  [state.config, state.emotes] = await Promise.all([api("/api/defaults"), api("/api/emotes")]);
  state.prefs = loadPrefs();
  state.reputation = buildReputation();
  await seed.loadWordlist();

  $("seed").addEventListener("input", refreshSeedField);
  $("unlock").addEventListener("click", unlock);
  $("create").addEventListener("click", () => createAccount().catch((e) => status($("seed-status"), e.message, "error")));
  $("logout").addEventListener("click", logOff);
  $("composer").addEventListener("submit", compose);
  $("my-profile").addEventListener("click", () => showProfile(state.me.pubkey));
  $("profile-close").addEventListener("click", () => showPanel("chat"));
  $("profile-friend").addEventListener("click", () => friendUser().catch((e) => status($("profile-status"), e.message, "error")));
  $("profile-report").addEventListener("click", () => reportUser().catch((e) => status($("profile-status"), e.message, "error")));
  $("profile-recalc").addEventListener("click", recalculate);
  $("profile-save").addEventListener("click", () => saveProfile().catch((e) => status($("profile-status"), e.message, "error")));
  $("copy-key").addEventListener("click", copyKey);
  $("add-friend").addEventListener("click", () => addByKey().catch((e) => status($("profile-status"), e.message, "error")));
  $("show-unrated").addEventListener("change", toggleUnrated);

  $("generate").addEventListener("click", async () => {
    const phrase = await seed.generate(state.config.seed.min_words);
    $("new-seed-words").textContent = phrase;
    $("new-seed").classList.remove("hidden");
    $("seed").value = phrase;
    refreshSeedField();
  });

  // A remembered key survives a refresh, which is not a log off.
  const remembered = await identity.recall();
  if (remembered) {
    try {
      await signIn(remembered);
    } catch {
      await identity.forget();
    }
  }
}

boot().catch((error) => status($("seed-status"), error.message, "error"));
