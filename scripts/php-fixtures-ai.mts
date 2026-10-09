// Writes the PHP port's parity fixtures for accounts' crypto and pages, the
// translator, journeys, the MCP server, and the assistant: what the TypeScript
// SDK answers for a set of inputs, so packages/php/tests can require the very
// same answers byte for byte. Run with node --import tsx.
import { createCipheriv, createHash, pbkdf2Sync, scryptSync } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import * as crypto from "../packages/sdk/src/accounts/crypto.ts";
import { base32, otpauthUri, totp } from "../packages/sdk/src/accounts/auth.ts";
import * as pages from "../packages/sdk/src/accounts/pages.ts";
import { languages, translator } from "../packages/sdk/src/messages.ts";
import { journeys } from "../packages/sdk/src/journeys.ts";
import { TOOLS, callTool, mcpResponse } from "../packages/sdk/src/mcp.ts";
import { AssistantError, acknowledgement, chat, listModels } from "../packages/sdk/src/assistant.ts";

const dir = new URL("../packages/php/tests/fixtures/", import.meta.url);
mkdirSync(dir, { recursive: true });
const save = (name: string, data: unknown) => writeFileSync(new URL(name, dir), `${JSON.stringify(data)}\n`);

// A small seeded generator, so the fixtures only change when the TypeScript does.
let seed = 20261008;
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const pick = <T,>(items: readonly T[]): T => items[Math.floor(random() * items.length)]!;
const bytes = (n: number) => Uint8Array.from({ length: n }, () => Math.floor(random() * 256));
const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64url");
const hexOf = (b: Uint8Array) => Buffer.from(b).toString("hex");
const outcome = async (fn: () => unknown) => {
  try {
    return { value: await fn() };
  } catch (error) {
    return { throws: (error as Error).name };
  }
};

// ---- Crypto ----

const passwords = ["a long password", "", "pässwörd ✓ 🙂", "x".repeat(200), "correct horse battery staple", "\u0000nul"];
const scrypt: unknown[] = [];
for (const password of passwords) {
  const salt = bytes(16);
  scrypt.push({ password, salt: b64(salt), N: 16384, r: 8, p: 1, length: 32, key: scryptSync(password, salt, 32, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }).toString("hex") });
}
for (let i = 0; i < 40; i++) {
  const N = 2 ** (1 + Math.floor(random() * 10));
  const r = 1 + Math.floor(random() * 4);
  const p = 1 + Math.floor(random() * 3);
  const length = 1 + Math.floor(random() * 100);
  const salt = bytes(Math.floor(random() * 40));
  const password = pick(passwords) + String(i);
  scrypt.push({ password, salt: b64(salt), N, r, p, length, key: scryptSync(password, salt, length, { N, r, p, maxmem: 256 * 1024 * 1024 }).toString("hex") });
}

const hashes: unknown[] = [];
for (const password of ["a long password", "pässwörd ✓ 🙂", ""]) hashes.push({ password, hash: await crypto.hashPassword(password) });

const salt = bytes(16);
const pbkdf2Key = (password: string, rounds: number, length = 32) => b64(pbkdf2Sync(password, salt, rounds, length, "sha256"));
const stored = [
  `pbkdf2$100000$${b64(salt)}$${pbkdf2Key("a long password", 100_000)}`,
  `pbkdf2$1000$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$1e3$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$ 1000 $${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$0x3e8$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$1000.0$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$1000.5$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$-5$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$$${b64(salt)}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$99999999999$a$b`,
  `pbkdf2$1000$${b64(salt)}$${pbkdf2Key("a long password", 1000, 16)}`,
  `pbkdf2$1000$${Buffer.from(salt).toString("base64")}$${pbkdf2Key("a long password", 1000)}`,
  `pbkdf2$1000$!!$abc`,
  `pbkdf2$1000$${b64(salt)}`,
  `scrypt$abc`,
  `scrypt$a$b$c`,
  `md5$abc$def`,
  ``,
  `scrypt$${b64(salt)}$`,
  `pbkdf2$1000$${b64(salt)}$`,
  `scrypt$${b64(salt)}$a`,
];
const checks: unknown[] = [];
for (const s of stored) {
  for (const password of ["a long password", "a long passwore"]) checks.push({ password, stored: s, ...(await outcome(() => crypto.checkPassword(password, s))) });
}

const secrets = ["s".repeat(64), "another secret", "", "ünïcode 🔑"];
const sealedByTs: unknown[] = [];
const texts = ["JBSWY3DPEHPK3PXP", "", "two-factor ✓ 🙂", "x".repeat(1000)];
for (const text of texts) for (const secret of secrets) sealedByTs.push({ text, secret, sealed: await crypto.sealText(text, secret) });
const sealKey = (secret: string) => createHash("sha256").update(`totp:${secret}`).digest();
const nodeSeal = (plain: Buffer, secret: string, iv: Uint8Array) => {
  const cipher = createCipheriv("aes-256-gcm", sealKey(secret), iv);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  return `${b64(iv)}.${b64(body)}.${b64(cipher.getAuthTag())}`;
};
const sealedWithIv: unknown[] = [];
for (const text of texts) for (const secret of secrets) {
  const iv = bytes(12);
  sealedWithIv.push({ text, secret, iv: b64(iv), sealed: nodeSeal(Buffer.from(text, "utf8"), secret, iv) });
}
const secret = "s".repeat(64);
const good = nodeSeal(Buffer.from("JBSWY3DPEHPK3PXP"), secret, bytes(12));
const [gi, gb, gt] = good.split(".") as [string, string, string];
const joined = Buffer.concat([Buffer.from(gb, "base64url"), Buffer.from(gt, "base64url")]);
const unsealInputs = [
  good,
  `${good}.extra`,
  `${gi}.${b64(joined.subarray(0, 4))}.${b64(joined.subarray(4))}`,
  `${gi}..${b64(joined)}`,
  `${gi}.${b64(joined)}.`,
  `.${gb}.${gt}`,
  `${gi}.${gb}`,
  `${gi}`,
  ``,
  `${gi}.${gb}.${gt.slice(0, -2)}AA`,
  `${gi}.${gb}.!!`,
  `${gi}.${gb}.${b64(Buffer.from(gt, "base64url").subarray(0, 8))}`,
  nodeSeal(Buffer.from([0x61, 0xff, 0x62, 0xc3, 0x28, 0xe2, 0x82]), secret, bytes(12)),
  nodeSeal(Buffer.from([0xef, 0xbb, 0xbf, 0x61]), secret, bytes(12)),
  nodeSeal(Buffer.from("sixteen byte iv"), secret, bytes(16)),
  nodeSeal(Buffer.from("eight byte iv"), secret, bytes(8)),
  nodeSeal(Buffer.from("eleven byte iv"), secret, bytes(11)),
  nodeSeal(Buffer.from("long iv"), secret, bytes(100)),
  `${gi}=.${gb}.${gt}`,
  Buffer.from(gi, "base64url").toString("base64") + `.${gb}.${gt}`,
];
const unseal: unknown[] = [];
for (const sealed of unsealInputs) {
  for (const s of [secret, "another secret"]) unseal.push({ sealed, secret: s, result: await crypto.unsealText(sealed, s) });
}

const base64Inputs = ["", "QQ", "QQ=", "QQ==", "QUI", "QUJD", "Q", "Q===", "QU JD", "QU\nJD", "a-_b", "a+/b", "ab=c", "####", "QUJD====", "Zm9vYmFy", "Zm9vYmE", "Zm9vYg"];
const base64: unknown[] = [];
for (const text of base64Inputs) {
  const result = await outcome(() => hexOf(crypto.fromBase64url(text)));
  base64.push({ text, ...result });
}
const encode: unknown[] = [];
for (let n = 0; n < 40; n++) {
  const b = bytes(n);
  encode.push({ hex: hexOf(b), base64url: crypto.base64url(b), base32: base32(b) });
}

const totpSecrets = ["JBSWY3DPEHPK3PXP", "jbswy3dpehpk3pxp", "JBSW Y3DP EHPK 3PXP", "JBSWY3DPEHPK3PXP====", "JBSW-Y3DP-EHPK-3PXP", "GEZDGNBVGY3TQOJQ", "MZXW6===", "ßtraße", "A", "", "0189", "aé1b2c"];
for (let i = 0; i < 6; i++) totpSecrets.push(base32(bytes(20)));
const steps = [0, 1, 2, 59, 1_000_000_000 / 30, 57_000_000, 2 ** 32 + 5, 2 ** 40, 2 ** 53 - 1];
const totps: unknown[] = [];
for (const s of totpSecrets) for (const step of steps) totps.push({ secret: s, step, ...(await outcome(() => totp(s, Math.floor(step)))) });

const uris: unknown[] = [];
for (const [s, email, host] of [
  ["JBSWY3DPEHPK3PXP", "jon@example.com", "stats.example.com"],
  ["ABC", "a+b@ex.com", "localhost:3000"],
  ["ABC", "émile@exämple.com", "x.com"],
  ["ABC", "q'uote(s)!*~@x.com", "h/o?s#t&="],
]) uris.push({ secret: s, email, host, uri: otpauthUri(s!, email!, host!) });

const signatures: unknown[] = [];
for (const [key, body, hash] of [
  ["k".repeat(64), "abc.1700000000000", "scrypt$salt$key"],
  ["secret", "device.u1", ""],
  ["ünï", "login.u.1", "pbkdf2$1$a$b"],
]) signatures.push({ secret: key, body, hash, signature: crypto.base64url(await crypto.hmac("SHA-256", key!, `${body}.${hash}`)) });

const recovery: unknown[] = [];
for (const code of ["k7dq-2mfa", "K7DQ 2MFA", "k7dq2mfa", "  k7-dq-2m-fa  ", "ünï-k7dq", ""]) {
  recovery.push({ code, hash: crypto.hex(await crypto.sha256(code.replace(/[^a-z0-9]/gi, "").toLowerCase())) });
}

const same: unknown[] = [];
for (const [a, b] of [["", ""], ["a", "a"], ["a", "b"], ["abc", "ab"], ["é", "e"], ["ab", "abc"]]) same.push({ a, b, same: crypto.sameText(a!, b!) });

save("crypto.json", { scrypt, hashes, checks, sealedByTs, sealedWithIv, unseal, base64, encode, totp: totps, uris, signatures, recovery, same });

// ---- Pages ----

const nasty = `a&b<c>"d'e é`;
const pageCases: unknown[] = [];
for (const base of ["", "/runlight", `/x"y`]) {
  pageCases.push({ fn: "loginPage", base, opts: { forgot: "https://runlight.sh/docs/accounts#forgot" }, html: pages.loginPage(base, { forgot: "https://runlight.sh/docs/accounts#forgot" }) });
  const login = { error: nasty, email: nasty, next: `${base}/?period=7d&x=<y>`, forgot: `https://x.com/?a=1&b="2"` };
  pageCases.push({ fn: "loginPage", base, opts: login, html: pages.loginPage(base, login) });
  pageCases.push({ fn: "loginPage", base, opts: { error: "", next: "", forgot: "" }, html: pages.loginPage(base, { error: "", next: "", forgot: "" }) });
  for (const code of [{ pending: "p.1.sig", next: "/" }, { pending: nasty, next: nasty, error: "Wrong code, try again." }]) pageCases.push({ fn: "codePage", base, opts: code, html: pages.codePage(base, code) });
  for (const role of ["viewer", "member", "admin", "owner", "<b>"]) {
    const invite = { code: "c0de", email: nasty, role, host: "stats.example.com", ...(role === "admin" ? { error: nasty } : {}) };
    pageCases.push({ fn: "invitePage", base, opts: invite, html: pages.invitePage(base, invite) });
  }
  pageCases.push({ fn: "inviteGonePage", base, opts: null, html: pages.inviteGonePage(base) });
  for (const setup of [{ code: "abc" }, { code: nasty, error: nasty, email: nasty, askCode: true }, { code: "", askCode: false, email: "" }]) pageCases.push({ fn: "setupPage", base, opts: setup, html: pages.setupPage(base, setup) });
  pageCases.push({ fn: "setupLockedPage", base, opts: null, html: pages.setupLockedPage(base) });
  pageCases.push({ fn: "setupNeedsTokenPage", base, opts: null, html: pages.setupNeedsTokenPage(base) });
}
const roles = ["viewer", "member", "admin", "", "Viewer"].map((role) => ({ role, text: pages.roleText(role) }));
save("pages.json", { css: pages.AUTH_CSS, js: pages.AUTH_JS, pages: pageCases, roles });

// ---- Messages ----

const numbers: Array<number | string> = [];
for (let n = 0; n <= 200; n++) numbers.push(n);
numbers.push(0.5, 1.5, 2.5, 0.1, 0.9, 1.1, 1.0004, 1.0005, 1.00049, 0.9995, 0.99949, 0.0001, 0.0005, 2.9995, 1.999, 1.25, 12.345, 12.3456);
numbers.push(1e6, 2e6, 1e6 + 0.5, 1e6 + 1, 1e7, 1.5e6, 1e9, 1e12, 123456789000000, 1e17, 1e18, 1e19, 2e18 + 2e6, 1.2345678901234568e21, 1e21, 1e22, 1.5e300, 5e-7, 1e-7, 1000001000000, 9.9995, 99.9995, 999999.9999);
numbers.push(-1, -0, -2, -1000000, -1.5, "NaN", "Infinity", "-Infinity");
const asNumber = (n: number | string) => (typeof n === "string" ? Number(n) : n);
const plural: Record<string, string[]> = {};
for (const lang of ["en", "de", "es", "fr", "pt"]) {
  const rules = new Intl.PluralRules(lang);
  plural[lang] = numbers.map((n) => rules.select(asNumber(n)));
}
const englishKeys = Object.keys(JSON.parse((await import("../packages/sdk/src/generated/dashboard.ts")).ENGLISH) as Record<string, string>);
const counted = [...new Set(englishKeys.filter((k) => k.endsWith("_other")).map((k) => k.slice(0, -6)))];
const words: unknown[] = [];
for (const lang of [...languages(), "xx", "EN", ""]) {
  const { t, tn, lang: code } = translator(lang);
  const tCases = [...englishKeys.slice(0, 40), "no.such.key", "app.confirmDelete"].map((key) => ({ key, vars: { name: "Blog <b>", n: 3, x: 1.5 }, text: t(key, { name: "Blog <b>", n: 3, x: 1.5 }) }));
  tCases.push({ key: "app.confirmDelete", vars: {} as never, text: t("app.confirmDelete") });
  const tnCases: unknown[] = [];
  for (const key of [...counted, "no.such"]) for (const n of [0, 1, 2, 5, 1.5, 1000000, 21]) tnCases.push({ key, n, text: tn(key, n, { n, name: "x" }) });
  words.push({ lang, code, t: tCases, tn: tnCases });
}
save("messages.json", { languages: languages(), numbers, plural, words });

// ---- Journeys ----

const sample = (visits: Record<string, string[]>) => Object.entries(visits).flatMap(([session, paths]) => paths.map((path) => ({ session, path })));
const journeyCases: unknown[] = [];
const fixed = sample({ a: ["/", "/pricing", "/signup"], b: ["/", "/pricing", "/pricing", "/docs"], c: ["/", "/blog"], d: ["/blog", "/", "/pricing"], e: ["/docs"] });
const pagesPool = ["/", "/pricing", "/signup", "/docs", "/blog", "/blog/a", "/blog/b", "/about", "/contact", "/z", "/Z", "/é", "/\u{1F600}", "/�", "/a b", "10", "2", ""];
const datasets: Array<Array<{ session: string; path: string }>> = [fixed, []];
for (let d = 0; d < 6; d++) {
  const rows: Array<{ session: string; path: string }> = [];
  const sessions = 5 + Math.floor(random() * 30);
  for (let s = 0; s < sessions; s++) {
    const length = 1 + Math.floor(random() * 12);
    const id = random() < 0.2 ? String(s) : `v${s}`;
    for (let i = 0; i < length; i++) rows.push({ session: id, path: pick(pagesPool.slice(0, 4 + d * 3)) });
  }
  // Interleave sessions a little, as rows from a store would be ordered by time.
  for (let i = rows.length - 1; i > 0; i--) if (random() < 0.1) [rows[i], rows[i - 1]] = [rows[i - 1]!, rows[i]!];
  datasets.push(rows);
}
const optionSets: Array<Record<string, unknown>> = [
  { steps: 3 },
  { steps: 2 },
  { steps: 5 },
  { steps: 8 },
  { steps: 12 },
  { steps: 0 },
  { steps: 1 },
  { steps: 3.7 },
  { steps: "NaN" },
  { steps: 3, start: "/pricing" },
  { steps: 4, end: "/signup" },
  { steps: 4, start: "/", end: "/docs" },
  { steps: 3, start: "" },
  { steps: 3, through: { step: 1, value: "/blog" } },
  { steps: 3, through: { step: 0, value: "/" } },
  { steps: 3, through: { step: 1.5, value: "/" } },
  { steps: 3, through: { step: 7, value: "/" } },
  { steps: 6, start: "/blog", through: { step: 2, value: "/pricing" } },
];
const journeyRuns: unknown[] = [];
for (const [index, rows] of datasets.entries()) {
  for (const options of optionSets) {
    const opts = { ...options, steps: options.steps === "NaN" ? NaN : options.steps } as Parameters<typeof journeys>[1];
    journeyRuns.push({ dataset: index, options, result: journeys(rows, opts) });
  }
}
save("journeys.json", { datasets, runs: journeyRuns });

// ---- MCP ----

/** Canned API answers by path, shared with the PHP replay. */
const API: Record<string, { status: number; body: string }> = {
  "/api/sites": { status: 200, body: `{"sites":[{"id":"b","name":"Site B","hostnames":["b.com"],"timezone":"UTC","lastVisit":1759900000000}]}` },
  "/api/stats": { status: 200, body: `{"site":"b","range":{"from":"2026-10-08","to":"2026-10-08"},"stats":{"visitors":2,"bounceRate":0.5,"duration":1.0,"big":1e21,"small":0.1,"neg":-0.0,"text":"a/b \\u2028 é 🙂 \\"q\\""},"previous":{},"list":[],"nested":[[],{}]}` },
  "/api/series": { status: 400, body: `{"error":5}` },
  "/api/breakdown": { status: 200, body: `{"rows":[{"value":"Hacker News","visitors":1}]}` },
  "/api/funnels": { status: 403, body: `{}` },
  "/api/event-props": { status: 200, body: `[1,2,"three"]` },
  "/api/rhythm": { status: 200, body: `{"site":"b","range":{"from":"x"},"grid":[[0,1],[2,3]],"cells":[1,2,3]}` },
  "/api/realtime": { status: 500, body: `oops, not JSON` },
  "/api/goals": { status: 200, body: `﻿{"goals":[]}` },
  "/api/journeys": { status: 400, body: `{"error":null}` },
  "/api/links": { status: 200, body: `null` },
};
const readApiFor = (log: unknown[], api: Record<string, { status: number; body: string }> = API) => async (path: string, params: [string, string][]) => {
  log.push({ path, params });
  const canned = api[path] ?? { status: 404, body: `{"error":"Not found: ${path.replace(/"/g, "")}"}` };
  return new Response(canned.body, { status: canned.status, headers: { "content-type": "application/json" } });
};

const argSets: unknown[] = [
  {},
  { site: "b", period: "7d", from: "2026-01-01", to: "2026-01-31", filters: ["page:is:/", "channel:is:Organic Search"], compare: "custom", compare_from: "2025-01-01", compare_to: "2025-01-31", interval: "day" },
  { site: "", period: null, from: 20260101, to: true, filters: [1, null, true, "a", [2, 3], { x: 1 }, 1.5] },
  { filters: "page:is:/" },
  { dimension: "source", limit: 500, page: 2 },
  { dimension: "source", limit: "50" },
  { dimension: "source", limit: 0 },
  { dimension: "source", limit: -3 },
  { dimension: "source", limit: 2.5 },
  { dimension: "source", limit: "abc" },
  { dimension: "source", limit: null },
  { dimension: "source", limit: true },
  { dimension: "source", limit: [7] },
  { dimension: "source", limit: {} },
  { dimension: "source", limit: " 12 " },
  { dimension: "source", limit: "1e1" },
  { event: "Signup", key: "plan", limit: 1000 },
  { goal_id: "a/b c?d&é" },
  { goal_id: null },
  { goal_id: 123 },
  { goal_id: "" },
  { steps: 3, start: "/pricing", end: "/signup" },
  { site: 5 },
  { site: { id: "x" } },
  { site: [] },
  { site: 1e21 },
];
const toolCalls: unknown[] = [];
for (const tool of TOOLS) {
  for (const args of argSets) {
    const log: unknown[] = [];
    const result = await outcome(() => callTool({ name: tool.name, arguments: args as Record<string, unknown> }, readApiFor(log)));
    toolCalls.push({ params: { name: tool.name, arguments: args }, requests: log, ...result });
  }
}
for (const params of [{ name: "get_stats", arguments: null }, { name: "get_stats", arguments: ["x"] }, { name: "get_stats", arguments: "site=a" }, { name: "get_stats" }, { name: "nope" }, {}, { name: null }, { name: 5 }]) {
  const log: unknown[] = [];
  const result = await outcome(() => callTool(params as Record<string, unknown>, readApiFor(log)));
  toolCalls.push({ params, requests: log, ...result, ...("throws" in result ? { message: await callTool(params as Record<string, unknown>, readApiFor([])).catch((e: Error) => e.message) } : {}) });
}

const rpc = (message: unknown) => JSON.stringify(message);
const bodies: string[] = [
  rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } }),
  rpc({ jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "1999-01-01" } }),
  rpc({ jsonrpc: "2.0", id: 3, method: "initialize" }),
  rpc({ jsonrpc: "2.0", id: "s", method: "initialize", params: { protocolVersion: 20250618 } }),
  rpc({ jsonrpc: "2.0", id: 4, method: "ping" }),
  rpc({ jsonrpc: "2.0", id: 5, method: "tools/list" }),
  rpc({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "get_stats", arguments: { period: "today" } } }),
  rpc({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "get_visit_times", arguments: {} } }),
  rpc({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "drop_tables" } }),
  rpc({ jsonrpc: "2.0", id: 9, method: "tools/call" }),
  rpc({ jsonrpc: "2.0", id: 10, method: "tools/call", params: ["get_stats"] }),
  rpc({ jsonrpc: "2.0", id: 11, method: "resources/list" }),
  rpc({ jsonrpc: "2.0", method: "notifications/initialized" }),
  rpc({ jsonrpc: "2.0", method: "tools/call", params: { name: "nope" } }),
  rpc({ jsonrpc: "2.0", method: "ping" }),
  rpc({ jsonrpc: "1.0", id: 12, method: "ping" }),
  rpc({ jsonrpc: "2.0", id: 13, method: 5 }),
  rpc({ jsonrpc: "2.0", id: null, method: "ping" }),
  rpc({ jsonrpc: "2.0", id: { a: [1] }, method: "ping" }),
  rpc({ jsonrpc: "2.0", id: 1.5, method: "ping" }),
  rpc({ id: 14 }),
  rpc({}),
  rpc([]),
  rpc([{ jsonrpc: "2.0", id: 1, method: "ping" }, { jsonrpc: "2.0", method: "notifications/initialized" }, 5, "x", [], { jsonrpc: "2.0", id: 2, method: "nope" }]),
  rpc([{ jsonrpc: "2.0", method: "notifications/initialized" }]),
  rpc([null]),
  rpc({ jsonrpc: "2.0", id: 15, method: "tools/call", params: { name: "get_realtime" } }),
  rpc({ jsonrpc: "2.0", id: 16, method: "tools/call", params: { name: "list_links" } }),
  rpc({ jsonrpc: "2.0", id: 17, method: "tools/call", params: { name: "get_goal", arguments: { goal_id: "x" } } }),
  rpc({ jsonrpc: "2.0", id: 18, method: "tools/call", params: { name: "list_funnels" } }),
  rpc({ jsonrpc: "2.0", id: 19, method: "tools/call", params: { name: "get_event_properties", arguments: { event: "x" } } }),
  rpc({ jsonrpc: "2.0", id: 20, method: "tools/call", params: { name: "list_goals" } }),
  rpc({ jsonrpc: "2.0", id: 21, method: "tools/call", params: { name: "get_journeys" } }),
  rpc({ jsonrpc: "2.0", id: 22, method: "tools/call", params: { name: "get_timeseries" } }),
  `﻿${rpc({ jsonrpc: "2.0", id: 23, method: "ping" })}`,
  "",
  "not json",
  "null",
  "5",
  `"text"`,
  "true",
  `{"jsonrpc":"2.0","id":24,"method":"ping","id":25}`,
];
const rpcs: unknown[] = [];
for (const body of bodies) {
  const log: unknown[] = [];
  try {
    const answer = await mcpResponse(new Request("https://example.com/runlight/mcp", { method: "POST", body }), readApiFor(log));
    rpcs.push({ body, requests: log, status: answer.status, headers: Object.fromEntries(answer.headers), text: await answer.text() });
  } catch (error) {
    rpcs.push({ body, requests: log, throws: (error as Error).name });
  }
}
// A body that is not UTF-8, which Request.json() reads with U+FFFD in place.
const latin = Buffer.concat([Buffer.from(`{"jsonrpc":"2.0","id":"`), Buffer.from([0xe9, 0xff]), Buffer.from(`","method":"ping"}`)]);
{
  const answer = await mcpResponse(new Request("https://example.com/runlight/mcp", { method: "POST", body: latin }), readApiFor([]));
  rpcs.push({ bodyHex: latin.toString("hex"), requests: [], status: answer.status, headers: Object.fromEntries(answer.headers), text: await answer.text() });
}
save("mcp.json", { api: API, tools: TOOLS.map((t) => t.name), calls: toolCalls, rpcs });

// ---- Assistant ----

type Canned = { status: number; body: string } | { throws: "timeout" | "network" };
interface Scenario {
  name: string;
  call: "chat" | "listModels";
  settings: Record<string, string>;
  messages?: Array<{ role: string; content: unknown }>;
  context?: unknown;
  responses: Canned[];
}
const context = { site: { id: "default", name: "Blog \"quoted\"", timezone: "Europe/London" }, today: "2026-10-08", view: "today, 8 October", language: "en" };
const json = (value: unknown, status = 200): Canned => ({ status, body: JSON.stringify(value) });
const anthropicTool = (calls: Array<Record<string, unknown>>, text = "Looking.") => json({ id: "msg", stop_reason: "tool_use", content: [{ type: "text", text }, ...calls.map((c) => ({ type: "tool_use", ...c }))], usage: { input_tokens: 1.0 } });
const anthropicText = (...texts: string[]) => json({ stop_reason: "end_turn", content: texts.map((text) => ({ type: "text", text })) });
const openaiTool = (calls: Array<Record<string, unknown>>, content: unknown = null) => json({ choices: [{ message: { role: "assistant", content, tool_calls: calls } }] });
const openaiText = (content: unknown) => json({ choices: [{ index: 0, message: { role: "assistant", content } }] });

const long = `${"é".repeat(5000)}${"a".repeat(4000)}`;
const history: Array<{ role: string; content: unknown }> = [{ role: "assistant", content: "Hello, I am the assistant." }];
for (let i = 0; i < 12; i++) history.push({ role: "user", content: `Question ${i}` }, { role: "assistant", content: `Answer ${i}` });
history.push({ role: "user", content: "First half" }, { role: "user", content: long }, { role: "user", content: "How many visitors today?" });

const scenarios: Scenario[] = [
  {
    name: "anthropic answers through a tool",
    call: "chat",
    settings: { provider: "anthropic", model: "", baseUrl: "https://api.example.com/v1//", key: "sk-ant-secret" },
    messages: [{ role: "user", content: "How many visitors today?" }],
    context,
    responses: [anthropicTool([{ id: "t1", name: "get_stats", input: { period: "today", filters: ["page:is:/"] } }]), anthropicText("You had 2 visitors today.")],
  },
  {
    name: "anthropic with a long history, several tools, and odd blocks",
    call: "chat",
    settings: { provider: "anthropic", model: "claude-opus-5-5", baseUrl: "", key: "k" },
    messages: history,
    context: { ...context, language: "fr" },
    responses: [
      anthropicTool([
        { id: "t1", name: "get_visit_times", input: {} },
        { id: "t2", name: "drop_tables", input: { x: 1 } },
        { name: "get_realtime", input: null },
        { id: "t4", input: [] },
        { id: "t5", name: "get_breakdown", input: { dimension: "source", limit: "7" } },
      ]),
      anthropicTool([{ id: "t6", name: "list_links", input: "not an object" }], ""),
      json({ stop_reason: "end_turn", content: [{ type: "text", text: "  First.  " }, { type: "thinking", thinking: "..." }, { type: "text" }, { type: "text", text: "Second.\n" }] }),
    ],
  },
  {
    name: "anthropic stops for a tool but names none",
    call: "chat",
    settings: { provider: "anthropic", model: "m", baseUrl: "", key: "k" },
    messages: [{ role: "user", content: "Hi there, what is new?" }],
    context,
    responses: [json({ stop_reason: "tool_use", content: [{ type: "text", text: "Nothing to look up." }] })],
  },
  {
    name: "anthropic answers with no content",
    call: "chat",
    settings: { provider: "anthropic", model: "m", baseUrl: "", key: "k" },
    messages: [{ role: "user", content: "Hello?" }],
    context,
    responses: [json({ stop_reason: "end_turn" })],
  },
  {
    name: "openai with tool arguments of every kind",
    call: "chat",
    settings: { provider: "openai", model: "gpt-5", baseUrl: "", key: "sk-openai" },
    messages: [{ role: "assistant", content: "Hi" }, { role: "user", content: "Which pages?" }],
    context,
    responses: [
      openaiTool(
        [
          { id: "c1", type: "function", function: { name: "get_breakdown", arguments: '{"dimension":"page","limit":5}' } },
          { id: "c2", type: "function", function: { name: "get_stats", arguments: "not json" } },
          { id: "c3", type: "function", function: { name: "get_stats", arguments: "" } },
          { type: "function", function: { name: "get_stats" } },
          { id: "c5", type: "function", function: { name: "get_stats", arguments: "[1,2]" } },
          { id: "c6", type: "function", function: { name: "nope", arguments: "{}" } },
        ],
        "Let me look.",
      ),
      openaiText("  The top page is /.  "),
    ],
  },
  { name: "gemini answers at once", call: "chat", settings: { provider: "gemini", model: "gemini-3-pro", baseUrl: "", key: "g" }, messages: [{ role: "user", content: "Bounce rate?" }], context, responses: [openaiText("About 50%.")] },
  { name: "openrouter answers at once", call: "chat", settings: { provider: "openrouter", model: "x/y", baseUrl: "", key: "or" }, messages: [{ role: "user", content: "Bounce rate?" }], context, responses: [openaiText(null)] },
  { name: "ollama needs no key", call: "chat", settings: { provider: "ollama", model: "llama", baseUrl: "", key: "" }, messages: [{ role: "user", content: "Bounce rate?" }], context, responses: [json({ choices: [] })] },
  { name: "lm studio with its own address", call: "chat", settings: { provider: "lmstudio", model: "qwen", baseUrl: "http://10.0.0.2:1234/v1/", key: "" }, messages: [{ role: "user", content: "Bounce rate?" }], context, responses: [json({})] },
  { name: "custom service with a key", call: "chat", settings: { provider: "custom", model: "m", baseUrl: "https://llm.example.com/api", key: "k-secret" }, messages: [{ role: "user", content: "Bounce rate?" }], context, responses: [openaiText(42)] },
  { name: "a refusal with the service's message", call: "chat", settings: { provider: "anthropic", model: "m", baseUrl: "", key: "bad" }, messages: [{ role: "user", content: "How many?" }], context, responses: [json({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }, 401)] },
  { name: "a refusal as plain text", call: "chat", settings: { provider: "custom", model: "m", baseUrl: "https://llm.example.com:8443/v1", key: "k" }, messages: [{ role: "user", content: "How many?" }], context, responses: [json({ error: "no such model" }, 404)] },
  { name: "a long refusal is cut", call: "chat", settings: { provider: "openai", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "How many?" }], context, responses: [json({ error: { message: `${"é".repeat(250)}${"x".repeat(200)}` } }, 429)] },
  { name: "an error without words", call: "chat", settings: { provider: "openai", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "How many?" }], context, responses: [{ status: 502, body: "<html>Bad gateway</html>" }] },
  { name: "an error with an empty message", call: "chat", settings: { provider: "openai", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "How many?" }], context, responses: [json({ error: { message: "" } }, 500)] },
  { name: "a timeout", call: "chat", settings: { provider: "openai", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "How many?" }], context, responses: [{ throws: "timeout" }] },
  { name: "no connection", call: "chat", settings: { provider: "ollama", model: "m", baseUrl: "", key: "" }, messages: [{ role: "user", content: "How many?" }], context, responses: [{ throws: "network" }] },
  {
    name: "too many steps",
    call: "chat",
    settings: { provider: "anthropic", model: "m", baseUrl: "", key: "k" },
    messages: [{ role: "user", content: "Everything, please" }],
    context,
    responses: Array.from({ length: 8 }, (_, i) => anthropicTool([{ id: `t${i}`, name: "list_sites", input: {} }])),
  },
  {
    name: "too many steps on openai",
    call: "chat",
    settings: { provider: "openrouter", model: "m", baseUrl: "", key: "k" },
    messages: [{ role: "user", content: "Everything, please" }],
    context,
    responses: Array.from({ length: 8 }, (_, i) => openaiTool([{ id: `c${i}`, type: "function", function: { name: "list_sites", arguments: "{}" } }])),
  },
  { name: "thanks needs no model", call: "chat", settings: { provider: "anthropic", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "How many?" }, { role: "assistant", content: "Two." }, { role: "user", content: "Merci beaucoup !" }], context: { ...context, language: "fr" }, responses: [] },
  { name: "no messages", call: "chat", settings: { provider: "anthropic", model: "m", baseUrl: "", key: "k" }, messages: [], context, responses: [anthropicText("Hello.")] },
  { name: "only answers", call: "chat", settings: { provider: "openai", model: "m", baseUrl: "", key: "k" }, messages: [{ role: "assistant", content: "Hi" }], context, responses: [openaiText("Hello.")] },
  { name: "an unknown provider", call: "chat", settings: { provider: "nope", model: "m", baseUrl: "", key: "" }, messages: [{ role: "user", content: "Hi?" }], context, responses: [] },
  { name: "custom without an address", call: "chat", settings: { provider: "custom", model: "m", baseUrl: "", key: "" }, messages: [{ role: "user", content: "Hi?" }], context, responses: [] },
  { name: "openai without a model", call: "chat", settings: { provider: "openai", model: "", baseUrl: "", key: "k" }, messages: [{ role: "user", content: "Hi?" }], context, responses: [] },
  { name: "anthropic models", call: "listModels", settings: { provider: "anthropic", baseUrl: "", key: "sk-ant" }, responses: [json({ data: [{ id: "claude-opus-5-5", display_name: "Claude Opus 5.5" }, { id: "claude-sonnet-5-5", display_name: "Claude Sonnet 5.5" }, { id: "b-first" }, { id: "" }, { id: 5 }, { display_name: "no id" }] })] },
  { name: "anthropic models refused", call: "listModels", settings: { provider: "anthropic", baseUrl: "", key: "wrong" }, responses: [json({ error: { message: "invalid x-api-key" } }, 401)] },
  {
    name: "ollama models sorted",
    call: "listModels",
    settings: { provider: "ollama", baseUrl: "http://127.0.0.1:11434/v1", key: "" },
    responses: [
      json({
        data: ["models/zeta", "alpha", "gpt-4o", "GPT-4", "gpt-4.1", "gpt-4o-mini", "o1", "chatgpt-4o-latest", "a_b", "a-b", "ab", "a b", "Zeta", "é", "e", "f", "10", "9", "llama3:8b", "llama3.1:8b", "llama3-8b", "models/models/x", "Ab", "aB", "a.b", "a:b", "a/b"].map((id) => ({ id, object: "model" })),
      }),
    ],
  },
  { name: "gemini models", call: "listModels", settings: { provider: "gemini", baseUrl: "", key: "g" }, responses: [json({ data: [{ id: "models/gemini-3-pro", display_name: "Gemini 3 Pro" }, { id: "models/gemini-3-flash" }] })] },
  { name: "openai models without a key", call: "listModels", settings: { provider: "openai", baseUrl: "", key: "" }, responses: [] },
  { name: "custom models without a key", call: "listModels", settings: { provider: "custom", baseUrl: "https://llm.example.com/v1", key: "" }, responses: [json({ data: [] })] },
  { name: "custom without an address lists nothing", call: "listModels", settings: { provider: "custom", baseUrl: "", key: "" }, responses: [] },
  { name: "unknown provider lists nothing", call: "listModels", settings: { provider: "x", baseUrl: "", key: "" }, responses: [] },
  { name: "models unreachable", call: "listModels", settings: { provider: "lmstudio", baseUrl: "", key: "" }, responses: [{ throws: "network" }] },
  { name: "models answer without words", call: "listModels", settings: { provider: "openrouter", baseUrl: "", key: "k" }, responses: [{ status: 500, body: "" }] },
  { name: "models answer null", call: "listModels", settings: { provider: "openrouter", baseUrl: "", key: "k" }, responses: [{ status: 200, body: "null" }] },
];

const realFetch = globalThis.fetch;
const assistantRuns: unknown[] = [];
for (const scenario of scenarios) {
  const requests: unknown[] = [];
  const tools: unknown[] = [];
  const queue = [...scenario.responses];
  globalThis.fetch = (async (url: string, init: RequestInit = {}) => {
    // Each body as its SHA-256 (every one carries the tools and the system text), which keeps the fixture small and the comparison exact.
    const body = init.body === undefined || init.body === null ? null : String(init.body);
    requests.push({ url: String(url), method: init.method ?? "GET", headers: init.headers ?? {}, bodySha256: body === null ? null : createHash("sha256").update(body).digest("hex") });
    const next = queue.shift();
    if (!next) throw new Error("No canned answer left");
    if ("throws" in next) {
      if (next.throws === "timeout") throw new DOMException("The operation timed out.", "TimeoutError");
      throw new TypeError("fetch failed");
    }
    return new Response(next.body, { status: next.status, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  try {
    const result =
      scenario.call === "chat"
        ? await chat(scenario.settings as never, scenario.messages as never, scenario.context as never, readApiFor(tools))
        : await listModels(scenario.settings as never);
    assistantRuns.push({ ...scenario, requests, tools, result });
  } catch (error) {
    if (!(error instanceof AssistantError)) throw error;
    assistantRuns.push({ ...scenario, requests, tools, error: { message: error.message, code: error.code, params: error.params } });
  } finally {
    globalThis.fetch = realFetch;
  }
}

const acknowledgements: unknown[] = [];
const ackTexts = [
  "Thanks!", "thank you", "Thanks!! 🙏", "ok", "Great, thanks.", "👍", "👍🏽", "❤️", "🙏🙏", "merci beaucoup", "Danke schön!", "DANKE SCHÖN", "valeu", "ótimo", "ÓTIMO",
  "Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?", "", "   ", " thanks ", "thanks ", "﻿ok", "ok​",
  "thx.", "ty!", "cheers mate", "d'accord", "D'ACCORD", "got it, thanks!", "okay okay", "thanks\nthanks", "perfecto, gracias", "alles klar.", "vielen dank!!!", "obrigada", "beleza", "nice 😀",
  "THANK YOU SO MUCH", "thank  you", "ok　", "ſuper", "SUPER",
];
for (const text of ackTexts) for (const language of ["en", "fr", "es", "de", "pt", "xx"]) acknowledgements.push({ text, language, reply: acknowledgement(text, language) });

save("assistant.json", { api: API, scenarios: assistantRuns, acknowledgements });
console.log("Wrote fixtures to packages/php/tests/fixtures/");
