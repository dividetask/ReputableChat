// UI wiring. The interesting parts live in identity.js (keys and signing) and
// reputation.js (who is visible); this file only moves data between them.

import * as seed from "./seed.js";
import * as identity from "./identity.js";
import { Reputation, Graph, toNumber } from "./reputation.js";

const ROOM = "general";
const $ = (id) => document.getElementById(id);

const state = { config: null, me: null, reputation: null, graph: new Graph(), seq: 0 };

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: options.body ? { "Content-Type": "application/json" } : {},
    ...options,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `request failed (${response.status})`);
  return data;
}

const post = (path, body) => api(path, { method: "POST", body: JSON.stringify(body) });

function status(el, message, kind = "") {
  el.textContent = message;
  el.className = `status ${kind}`;
}

// People are identified by key, never by name -- names are not unique, so a
// visible fingerprint is the only thing standing between a user and a
// convincing impersonator.
const fingerprint = (pubkey) => pubkey.slice(0, 8);

// --- seed entry --------------------------------------------------------

async function refreshSeedField() {
  const phrase = $("seed").value;
  const words = seed.words(phrase);
  const reason = phrase.trim() ? await seed.validate(phrase, state.config.seed.min_words) : "type your seed";

  $("unlock").disabled = reason !== null;
  status($("seed-status"), reason || `${words.length} words · looks good`, reason ? "" : "ok");

  // Type-ahead on the word being typed. BIP39 guarantees four letters is
  // enough to identify a word, so this removes spelling as a failure mode.
  const partial = phrase.trimEnd() === phrase ? words[words.length - 1] : "";
  const box = $("suggestions");
  box.replaceChildren();

  if (partial && partial.length >= 2 && !phrase.endsWith(" ")) {
    for (const word of await seed.suggest(partial, 6)) {
      if (word === partial) continue;
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = word;
      button.addEventListener("click", () => {
        const kept = words.slice(0, -1);
        $("seed").value = `${[...kept, word].join(" ")} `;
        $("seed").focus();
        refreshSeedField();
      });
      box.append(button);
    }
  }
}

// --- login -------------------------------------------------------------

async function unlock() {
  $("unlock").disabled = true;
  status($("seed-status"), "deriving your key — this takes a moment by design…");

  try {
    const derived = await identity.deriveFromSeed($("seed").value, state.config.seed.kdf);
    $("seed").value = ""; // the seed has done its job; do not keep it around
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
  const signature = await identity.sign(derived, payload);

  const session = await post("/api/session", { pubkey: derived.pubkey, nonce, ts, signature });

  state.me = { ...derived, username: session.username };
  await identity.remember({ privateKey: derived.privateKey, pubkey: derived.pubkey });

  if (session.registered) return enterChat();

  $("register").classList.remove("hidden");
  status($("seed-status"), "");
}

async function createAccount() {
  const username = $("username").value.trim();
  if (!username) return status($("seed-status"), "pick a display name", "error");

  const result = await post("/api/register", { username });
  state.me.username = result.username;
  enterChat();
}

async function logOff() {
  await identity.forget();
  state.me = null;
  location.reload();
}

// --- chat --------------------------------------------------------------

function enterChat() {
  $("login").classList.add("hidden");
  $("chat").classList.remove("hidden");
  $("me").textContent = `${state.me.username || "you"} · ${fingerprint(state.me.pubkey)}`;
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

  // Every message is verified against its author's key before it is shown.
  // The server is not trusted to have done it.
  const verified = [];
  for (const message of messages) {
    if (await verifyMessage(message)) verified.push(message);
  }

  const authors = [...new Set(verified.map((m) => m.author))];
  await loadConfigs([...authors, state.me.pubkey]);

  render(verified);
  state.seq = Math.max(0, ...verified.filter((m) => m.author === state.me.pubkey).map((m) => m.seq));
}

async function verifyMessage(message) {
  try {
    const key = await crypto.subtle.importKey(
      "jwk", { kty: "OKP", crv: "Ed25519", x: message.author }, "Ed25519", false, ["verify"],
    );
    return crypto.subtle.verify(
      "Ed25519", key,
      identity.fromB64url(message.signature),
      new TextEncoder().encode(message.payload),
    );
  } catch {
    return false;
  }
}

// Fetches signed configs in one round trip and verifies each before it is
// allowed to influence anyone's reputation. A seven-deep walk done one fetch
// at a time would be hundreds of sequential requests.
async function loadConfigs(pubkeys) {
  const wanted = pubkeys.filter((key) => key && !state.graph.has(key));
  if (!wanted.length) return;

  const { configs } = await post("/api/config/batch", { pubkeys: wanted });

  for (const blob of configs) {
    if (!blob) continue;

    try {
      const key = await crypto.subtle.importKey(
        "jwk", { kty: "OKP", crv: "Ed25519", x: blob.pubkey }, "Ed25519", false, ["verify"],
      );
      const ok = await crypto.subtle.verify(
        "Ed25519", key,
        identity.fromB64url(blob.signature),
        new TextEncoder().encode(blob.payload),
      );
      if (!ok) continue;

      const payload = JSON.parse(blob.payload);
      if (payload.purpose !== identity.PURPOSE.CONFIG || payload.pubkey !== blob.pubkey) continue;

      state.graph.add(blob.pubkey, payload.ratings);
    } catch {
      // A config that will not parse or verify simply does not join the graph.
    }
  }

  for (const key of wanted) if (!state.graph.has(key)) state.graph.add(key, {});
}

function render(messages) {
  const list = $("messages");
  list.replaceChildren();

  for (const message of messages) {
    const verdict = message.author === state.me.pubkey
      ? "normal"
      : state.reputation.visibility(state.me.pubkey, message.author, state.graph);

    // Hidden means hidden: unrated and net-negative people do not render.
    if (verdict === "hidden") continue;

    const payload = JSON.parse(message.payload);
    const row = document.createElement("div");
    row.className = `msg ${verdict}`;

    const who = document.createElement("span");
    who.className = "who";
    who.textContent = message.author === state.me.pubkey ? state.me.username || "you" : "someone";

    const fp = document.createElement("span");
    fp.className = "fp";
    fp.textContent = fingerprint(message.author);

    const body = document.createElement("div");
    body.textContent = payload.body; // textContent, never innerHTML

    row.append(who, fp, body);
    list.append(row);
  }

  list.scrollTop = list.scrollHeight;
}

async function send(event) {
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

// --- boot ---------------------------------------------------------------

async function boot() {
  state.config = await api("/api/defaults");
  state.reputation = new Reputation(state.config);
  await seed.loadWordlist();

  $("seed").addEventListener("input", refreshSeedField);
  $("unlock").addEventListener("click", unlock);
  $("create").addEventListener("click", () => createAccount().catch((e) => status($("seed-status"), e.message, "error")));
  $("logout").addEventListener("click", logOff);
  $("composer").addEventListener("submit", send);

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

export { toNumber };
