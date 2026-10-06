// Validates docs/project/rules/v0.001-examples.md against the rules it is an
// example of, printing one line per problem and nothing when clean. The last
// lines report what the chain contains, so the Ruby side can assert on it.
// See spec/examples_spec.rb.
import { readFileSync } from "node:fs";
import { createHash, webcrypto as wc } from "node:crypto";

const FILE = process.argv[2] ?? new URL("../docs/project/rules/v0.001-examples.md", import.meta.url);
const text = readFileSync(FILE, "utf8");
const problems = [];
const say = (m) => problems.push(m);
const short = (h) => h.slice(0, 8);

// --- the keys, re-derived from the formula the file states --------------------

const SPKI = new Uint8Array([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00]);
const b64u = (b) => Buffer.from(b).toString("base64url");
const PKCS8 = new Uint8Array([0x30,0x2e,0x02,0x01,0x00,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x04,0x22,0x04,0x20]);

const names = {};                                   // public key -> example name
for (const [, name, pub] of text.matchAll(/^\| ([a-z0-9-]+) \| `([A-Za-z0-9_-]{43})` \|$/gm)) {
  const seed = createHash("sha256").update(`reputablechat example key: ${name}`).digest();
  const pkcs8 = new Uint8Array(48); pkcs8.set(PKCS8, 0); pkcs8.set(seed, 16);
  const priv = await wc.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, ["sign"]);
  const derived = (await wc.subtle.exportKey("jwk", priv)).x;
  if (derived !== pub) say(`key ${name} does not re-derive: table says ${pub}, formula gives ${derived}`);
  names[pub] = name;
}

// --- the records, in the order the file lists them ----------------------------

const canonical = (v) => Array.isArray(v) ? `[${v.map(canonical).join(",")}]`
  : (v && typeof v === "object")
    ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`
    : JSON.stringify(v);

const recs = [...text.matchAll(/```\npayload:   (.+?)\nsignature: (\S+)\nhash:      (\S+)\n```/gs)]
  .map(([, payload, signature, hash]) => ({ payload, signature, hash, p: JSON.parse(payload) }));
const by = new Map(recs.map((r) => [r.hash, r]));

const verifyKey = async (pub) => wc.subtle.importKey(
  "spki", Buffer.concat([SPKI, Buffer.from(pub, "base64url")]), "Ed25519", false, ["verify"]);

for (const r of recs) {
  const label = `${short(r.hash)} (${names[r.p.pubkey ?? r.p.mpubkey] ?? "unknown key"})`;
  if (canonical(r.p) !== r.payload) say(`${label} payload is not in canonical form`);

  const carried = [r.p.pubkey, r.p.mpubkey].filter(Boolean);
  if (!carried.length) say(`${label} carries neither pubkey nor mpubkey`);
  let verified = false;
  for (const pub of carried) {
    const ok = await wc.subtle.verify("Ed25519", await verifyKey(pub),
      Buffer.from(r.signature, "base64url"), Buffer.from(r.payload, "utf8"));
    if (ok) { verified = true; r.signer = pub; }
  }
  if (!verified) say(`${label} signature verifies against no key it carries`);

  const digest = createHash("sha256").update(`${r.payload}\n${r.signature}`, "utf8").digest("hex");
  if (digest !== r.hash) say(`${label} hash is ${r.hash} but the bytes give ${digest}`);
}

// --- acks, history and versions ----------------------------------------------

const version = (r) => r.p.type.split(":")[2];
const seen = new Set();
for (const [i, r] of recs.entries()) {
  const ack = r.p.ack ?? [];
  const label = short(r.hash);
  if (i === 0) {
    if (ack.length) say(`${label} is the genesis and its ack is not empty`);
  } else if (!ack.length) say(`${label} has an empty ack and is not the genesis`);

  if (JSON.stringify(ack) !== JSON.stringify([...ack].sort())) say(`${label} ack is not sorted`);
  if (new Set(ack).size !== ack.length) say(`${label} ack repeats a hash`);
  const isHeartbeat = r.p.type.startsWith("reputablechat:heartbeat:");
  const limit = isHeartbeat ? 1_048_576 : 16;
  if (isHeartbeat) {
    if (Buffer.byteLength(canonical(ack), "utf8") > limit) say(`${label} ack exceeds ${limit} bytes`);
  } else if (ack.length > limit) say(`${label} acks ${ack.length} records, over the limit of ${limit}`);

  for (const a of ack) {
    if (!seen.has(a)) { say(`${label} acks ${short(a)}, which no earlier record produced`); continue; }
    const isRelease = r.p.type.startsWith("reputablechat:release:");
    if (!isRelease && version(by.get(a)) !== version(r))
      say(`${label} is ${version(r)} and acks ${short(a)}, which is ${version(by.get(a))}`);
  }
  seen.add(r.hash);
}

const history = (r) => {                            // every record its ack reaches, itself excluded
  const out = new Set(), stack = [...(r.p.ack ?? [])];
  while (stack.length) {
    const h = stack.pop();
    if (out.has(h) || !by.has(h)) continue;
    out.add(h);
    stack.push(...(by.get(h).p.ack ?? []));
  }
  return out;
};
const account = (r) => r.p.id ?? r.hash;

for (const r of recs) {
  const first = recs.find((x) => account(x) === account(r) && !x.p.id);
  if (!first) say(`${short(r.hash)} names an account with no first declaration here`);
  else if (r.p.id && !history(r).has(first.hash))
    say(`${short(r.hash)} names an account whose declaration is not in its history`);
  for (const e of r.p.endorse ?? [])
    if (!history(r).has(e)) say(`${short(r.hash)} endorses ${short(e)}, which is not in its history`);
}

// --- the keys a record may sign with -----------------------------------------

const KEY_KINDS = ["key-change", "master-key-change"];
const contests = [];
for (const r of recs) {
  const acct = account(r), hist = history(r);
  const mine = recs.filter((x) => hist.has(x.hash) && account(x) === acct);
  const first = recs.find((x) => account(x) === acct && !x.p.id);
  let confirmed = { "key-change": first?.p.pubkey, "master-key-change": first?.p.mpubkey };
  let tentative = new Set();
  for (const x of mine) {                           // the file lists records in the order made
    if (x.p.kind === "quorum") for (const t of x.p.target ?? []) {
      const named = by.get(t);
      if (!named || account(named) !== acct || !KEY_KINDS.includes(named.p.kind)) continue;
      confirmed = { ...confirmed, [named.p.kind]: named.p.body };
      tentative = new Set();                        // a quorum voids every change tentative then
    }
    if (KEY_KINDS.includes(x.p.kind)) tentative.add(x.p.body);
  }
  const allowed = new Set([...Object.values(confirmed), ...tentative].filter(Boolean));
  if (r.signer && !allowed.has(r.signer))
    say(`${short(r.hash)} signs with ${names[r.signer]}, which is neither confirmed nor tentative`);

  // Signing with a key a change in this record's own history replaced is a contest.
  const changes = mine.filter((x) => KEY_KINDS.includes(x.p.kind));
  const replaced = changes.filter((x, i) =>
    changes.slice(i + 1).some((y) => y.p.kind === x.p.kind)).map((x) => x.p.body);
  const beforeAny = changes.length ? [first?.p.pubkey, first?.p.mpubkey].filter(Boolean) : [];
  if (r.signer && (replaced.includes(r.signer) ||
      (beforeAny.includes(r.signer) && changes.some((x) => x.p.body !== r.signer &&
        x.p.kind === (r.p.mpubkey === r.signer ? "master-key-change" : "key-change")))))
    contests.push(`${short(r.hash)} ${names[r.signer]}`);
}

// --- attestations -------------------------------------------------------------

const SCORE_LIMIT = 16_777_216;
for (const r of recs) {
  if (!r.p.scores && !r.p.derived) continue;
  const size = ["scores", "derived"].filter((k) => r.p[k])
    .reduce((n, k) => n + Buffer.byteLength(canonical(r.p[k]), "utf8"), 0);
  if (size > SCORE_LIMIT) say(`${short(r.hash)} has ${size} bytes of scores and derived`);
  for (const field of ["scores", "derived"]) for (const [id, score] of Object.entries(r.p[field] ?? {})) {
    if (!/^[0-9a-f]{64}$/.test(id)) say(`${short(r.hash)} ${field} is keyed by ${id}, not an account ID`);
    for (const name of ["reputation", "trust"]) {
      const value = score[name];
      if (value === undefined) continue;
      if (Math.abs(Number(value)) > 1) say(`${short(r.hash)} ${field} has a ${name} of ${value}`);
    }
  }
}

// --- heartbeats ---------------------------------------------------------------

const HEARTBEAT_EXTRA = new Set(["type", "id", "pubkey", "mpubkey", "ack", "body", "ts", "endorse"]);
const chains = new Map();
for (const r of recs) if (r.p.type.startsWith("reputablechat:heartbeat:")) {
  const extra = Object.keys(r.p).filter((k) => !HEARTBEAT_EXTRA.has(k));
  if (extra.length) say(`${short(r.hash)} is a heartbeat carrying ${extra.join(", ")}`);
  if (r.p.body !== "") say(`${short(r.hash)} is a heartbeat with a body`);
  const chain = chains.get(account(r)) ?? [];
  const prev = chain[chain.length - 1];
  if (prev) {
    if (!(r.p.ack ?? []).includes(prev.hash))
      say(`${short(r.hash)} does not directly ack its author's previous heartbeat`);
    if (r.p.ts - prev.p.ts < 480)
      say(`${short(r.hash)} is ${r.p.ts - prev.p.ts}s after its author's previous heartbeat`);
  }
  chains.set(account(r), [...chain, r]);
}

// --- transfers ----------------------------------------------------------------

const outputs = new Map();                          // "recordHash:account" -> {value, currency}
for (const r of recs) {
  const t = r.p.transfer;
  if (!t) continue;
  const label = short(r.hash);
  const has = (k) => Object.hasOwn(t, k);
  if (!has("in") && !has("out")) say(`${label} has a transfer with neither in nor out`);
  if (!has("currency") && has("in")) say(`${label} issues currency and still names in`);
  const currency = t.currency ?? account(r);
  if (has("out")) {
    const tos = t.out.map((o) => o.to);
    if (JSON.stringify(tos) !== JSON.stringify([...tos].sort())) say(`${label} out is not sorted by to`);
    if (new Set(tos).size !== tos.length) say(`${label} out pays one account twice`);
    if (t.out.some((o) => !o.to)) say(`${label} has an output with no to`);
    if (t.out.some((o) => !(Number(o.value) > 0))) say(`${label} has an output not greater than zero`);
  }
  let spent = 0;
  for (const i of t.in ?? []) {
    const key = `${i}:${account(r)}`;
    const held = outputs.get(key);
    if (!held) { say(`${label} spends ${short(i)}, which it does not hold`); continue; }
    if (held.currency !== currency) say(`${label} spends ${short(i)}, which is another currency`);
    if (!history(r).has(i)) say(`${label} spends ${short(i)}, not in its history`);
    spent += Number(held.value);
  }
  const made = (t.out ?? []).reduce((n, o) => n + Number(o.value), 0);
  if (has("in") && has("out") && spent !== made)
    say(`${label} spends ${spent} and makes ${made}`);
  for (const o of t.out ?? []) outputs.set(`${r.hash}:${o.to}`, { value: o.value, currency });
}

// --- what the Ruby side asserts on ------------------------------------------

for (const m of problems) console.log(`PROBLEM\t${m}`);
console.log(`RECORDS\t${recs.length}`);
console.log(`KEYS\t${Object.keys(names).length}`);
for (const c of contests) console.log(`CONTEST\t${c}`);
const kinds = {};
for (const r of recs) kinds[r.p.type.split(":")[1]] = (kinds[r.p.type.split(":")[1]] ?? 0) + 1;
for (const [kind, n] of Object.entries(kinds).sort()) console.log(`KIND\t${kind}\t${n}`);
