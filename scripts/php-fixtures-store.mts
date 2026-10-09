// The store, across implementations. With no arguments, builds a SQLite database with the TypeScript SDK
// (sites, visits from the tracker, events with properties, goals, funnels, short links and their clicks, AI
// fetches, shares, tokens, reports, settings, and days rolled up, with some left unbuilt) into
// packages/php/tests/fixtures/store.db, and writes what a wide set of SqlStore reads answer over it to
// packages/php/tests/fixtures/store.json. The PHP port opens a copy of the same file and must answer the same.
// It also writes packages/php/tests/fixtures/goals.json: goalFrom, funnelFrom, pagePattern, and clickRules
// over a set of dashboard inputs.
//
// With `read <database> <calls.json>`, opens a SQLite database (one PHP wrote) with the TypeScript store, runs
// the calls listed in the JSON file, and prints their answers as JSON, so PHP can check the other direction.
// With `migrate <url>`, creates the tables in a Postgres or MySQL database, for PHP to compare with its own.
//
// Run with: node --import tsx scripts/php-fixtures-store.mts
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { runlight } from "../packages/sdk/src/index.js";
import type { SqlStore } from "../packages/sdk/src/store.js";
import { sqlite } from "../packages/sdk/src/stores/sqlite.js";

/** One read: a SqlStore method and its arguments. */
type Call = { method: string; args: unknown[] };

/** A read's answer in JSON's terms: a Map as an object in its order, a Set as a sorted list. */
async function answer(store: SqlStore, call: Call): Promise<unknown> {
  const fn = (store as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>)[call.method];
  if (typeof fn !== "function") throw new Error(`no such method ${call.method}`);
  const result = await fn.apply(store, call.args);
  if (result instanceof Map) return Object.fromEntries(result);
  if (result instanceof Set) return [...result].sort();
  return result === undefined ? null : result;
}

async function answers(store: SqlStore, calls: Call[]): Promise<unknown[]> {
  const out: unknown[] = [];
  for (const call of calls) out.push(await answer(store, call));
  return out;
}

if (process.argv[2] === "migrate") {
  const url = process.argv[3]!;
  const store = /^postgres/.test(url) ? (await import("../packages/sdk/src/stores/postgres.js")).postgres({ url }) : (await import("../packages/sdk/src/stores/mysql.js")).mysql({ url });
  await store.migrate();
  await store.close();
  process.exit(0);
}

if (process.argv[2] === "read") {
  const [, , , file, callsFile] = process.argv;
  const store = sqlite({ path: file! });
  await store.migrate();
  const calls = JSON.parse(readFileSync(callsFile!, "utf8")) as Call[];
  const out = JSON.stringify(await answers(store, calls));
  await store.close();
  // Written in full before the process ends, which a pipe would otherwise cut short.
  await new Promise<void>((resolve) => process.stdout.write(out, () => resolve()));
  process.exit(0);
}

// Goals and funnels checked from the dashboard: pure, so a fixture of inputs and answers.
{
  const { GoalError, clickRules, goalFrom, pagePattern } = await import("../packages/sdk/src/goals.js");
  const { FunnelError, funnelFrom } = await import("../packages/sdk/src/funnels.js");
  const outcome = (fn: () => Record<string, unknown>, fresh: boolean) => {
    try {
      const value = fn();
      // A new id is random; it is checked for its form instead.
      return { value: fresh && /^[0-9a-f]{24}$/.test(String(value.id)) ? { ...value, id: "<random>" } : value };
    } catch (error) {
      if (error instanceof GoalError || error instanceof FunnelError) return { error: { message: error.message, code: error.code, params: error.params } };
      throw error;
    }
  };
  const goal = (id: string, g: Record<string, unknown>) => ({ id, site: "s", name: id, kind: "event", match: id, clickBy: "", valueMode: "none", value: 0, valueProp: "", currency: "USD", createdAt: 5, ...g });
  const existing = [goal("a".repeat(24), { name: "Signup", match: "Signup" }), goal("b".repeat(24), { name: "Buy", kind: "click", match: ".buy", clickBy: "selector" })];
  const goalInputs: unknown[] = [
    {}, { name: "  " }, { name: "X" }, { name: "signup", kind: "event", match: "Y" }, { name: "X", kind: "pageview", match: "/" },
    { name: "X", kind: "event" }, { name: "X", kind: "event", match: " Purchase " }, { name: "X", kind: "page" }, { name: "X", kind: "page", match: "https://example.com/thanks*" },
    { name: "X", kind: "page", match: "thanks" }, { name: "X", kind: "page", match: "*thanks" }, { name: "X", kind: "page", match: "/café/*" }, { name: "X", kind: "page", match: "/#/thanks" },
    { name: "X", kind: "page", match: "http://[::1" }, { name: "X", kind: "click" }, { name: "X", kind: "click", clickBy: "link" }, { name: "X", kind: "click", clickBy: "link", match: "https://buy.stripe.com/*" },
    { name: "X", kind: "click", match: "#signup" }, { name: "signup", kind: "click", match: "#signup" }, { name: "Y", kind: "event", match: "buy" },
    { name: "X", kind: "event", match: "X", valueMode: "fixed", value: 9.999 }, { name: "X", kind: "event", match: "X", valueMode: "fixed", value: "12" }, { name: "X", kind: "event", match: "X", valueMode: "fixed", value: -1 },
    { name: "X", kind: "event", match: "X", valueMode: "fixed", value: 1e9 }, { name: "X", kind: "event", match: "X", valueMode: "fixed", value: "abc" }, { name: "X", kind: "event", match: "X", valueMode: "fixed" },
    { name: "X", kind: "event", match: "X", valueMode: "prop" }, { name: "X", kind: "event", match: "X", valueMode: "prop", valueProp: "a b" }, { name: "X", kind: "event", match: "X", valueMode: "prop", valueProp: "order.total-1" },
    { name: "X", kind: "page", match: "/p", valueMode: "prop" }, { name: "X", kind: "event", match: "X", valueMode: "weird" }, { name: "X", kind: "event", match: "X", currency: "eur" }, { name: "X", kind: "event", match: "X", currency: "dollars" },
    { name: "X", kind: "event", match: "X", currency: " gbp " }, { name: "n".repeat(100), kind: "event", match: "m".repeat(600) }, { name: 42, kind: "event", match: 7 }, { name: "Émile", kind: "event", match: "É" }, { name: "ÉMILE", kind: "event", match: "x" },
  ];
  const goals = [];
  for (const input of goalInputs) {
    goals.push({ input, id: null, result: outcome(() => goalFrom(input as Record<string, unknown>, "s", existing, 1000) as never, true) });
    goals.push({ input, id: "a".repeat(24), result: outcome(() => goalFrom(input as Record<string, unknown>, "s", existing, 1000, "a".repeat(24)) as never, false) });
  }
  const funnelInputs: unknown[] = [
    {}, { name: "F" }, { name: "F", steps: [{ kind: "page", match: "/a" }] }, { name: "F", steps: [{ kind: "page", match: "/a" }, { kind: "event", match: "Signup" }] },
    { name: "f", steps: [{ match: "a" }, { kind: "x", match: "https://example.com/b*" }, null, "x", [], { kind: "page", match: "  " }] },
    { name: "F", steps: Array.from({ length: 9 }, (_, i) => ({ kind: "event", match: `E${i}` })) }, { name: "F", steps: [{ kind: "page", match: "http://[::1" }, { kind: "page", match: "/b" }] },
    { name: "Existing", steps: [{ kind: "page", match: "/a" }, { kind: "page", match: "/b" }] }, { name: "F", steps: "nope" }, { name: "x".repeat(90), steps: [{ kind: "page", match: "/#/cart" }, { kind: "event", match: "e".repeat(600) }] },
  ];
  const funnels = [];
  const existingFunnels = [{ id: "e".repeat(24), site: "s", name: "existing", steps: [], createdAt: 7 }];
  for (const input of funnelInputs) {
    funnels.push({ input, id: null, result: outcome(() => funnelFrom(input as Record<string, unknown>, "s", existingFunnels as never, 1000) as never, true) });
    funnels.push({ input, id: "e".repeat(24), result: outcome(() => funnelFrom(input as Record<string, unknown>, "s", existingFunnels as never, 1000, "e".repeat(24)) as never, false) });
  }
  const patterns = ["/thanks", "thanks", "*thanks*", "/blog/*", "https://example.com/a b?x=1#y", "/#/route", "/café", "*", "", "http://[::1", "//evil.example/x", "/a/../b", "/%zz", "/Ünïcödé/*/x"].map((input) => ({ input, result: pagePattern(input) }));
  const rules = clickRules(
    [{ id: "s", name: "S", hostnames: ["www.example.com", "shop.example.com"], timezone: "UTC" }, { id: "t", name: "T", hostnames: [], timezone: "UTC" }, { id: "u", name: "U", hostnames: ["u.example"], timezone: "UTC" }],
    [goal("c".repeat(24), { name: "Buy", kind: "click", match: ".buy", clickBy: "selector" }), goal("d".repeat(24), { name: "Out", kind: "click", match: "https://x.example/*", clickBy: "link", site: "t" }), goal("e".repeat(24), { name: "E", kind: "event", site: "u" })] as never,
  );
  writeFileSync(
    new URL("../packages/php/tests/fixtures/goals.json", import.meta.url),
    `${JSON.stringify({ description: "goalFrom, funnelFrom, pagePattern, and clickRules as the TypeScript SDK answers them. Written by scripts/php-fixtures-store.mts.", existing, existingFunnels, goals, funnels, patterns, rules })}\n`,
  );
}

const DAY = 86_400_000;
const HOUR = 3_600_000;
const MIN = 60_000;
const CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
const SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const FIREFOX = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0";
const PAGES = ["/", "/blog/one", "/blog/two", "/pricing", "/about", "/Über-uns", "/café", "/#/cart", "/signup", "/thanks/pro"];
const REFERRERS = ["https://www.google.com/", "https://news.ycombinator.com/", "", "https://chatgpt.com/", "https://t.co/x", "https://example.org/page"];
const COUNTRIES = ["GB", "US", "DE", "CA", "FR"];
const CAMPAIGNS = ["alpha", "Zeta", "beta", "Gamma", "émile", "Émile", "_x", "a-b", "ab", "Über"];

const dir = path.join(tmpdir(), `runlight-store-${process.pid}`);
mkdirSync(dir, { recursive: true });
const file = path.join(dir, "store.db");
rmSync(file, { force: true });

let now = Date.UTC(2026, 9, 6, 12, 0);
const SITE = { id: "default", name: "Example", hostnames: ["example.com", "docs.example.com"], timezone: "America/Toronto" };
const rl = runlight({ store: sqlite({ path: file }), site: SITE, now: () => now });
const routes = rl.routes({ token: "secret" });
await rl.init();
const store = rl.store;

const send = async (body: Record<string, unknown>, ip: string, ua: string, country: string) => {
  const response = await routes.POST(
    new Request("https://example.com/runlight/e", {
      method: "POST",
      body: JSON.stringify(body),
      headers: { "user-agent": ua, "x-forwarded-for": ip, "x-vercel-ip-country": country },
    }),
  );
  if (response.status !== 202) throw new Error(`collect answered ${response.status}`);
};

// Twelve days of visits, ending two hours ago.
const start = now;
now -= 12 * DAY;
let n = 0;
for (let day = 0; day < 12; day++) {
  for (let v = 0; v < 7; v++) {
    n++;
    const ip = `203.0.113.${n % 50}`;
    const ua = n % 3 === 0 ? SAFARI : n % 5 === 0 ? FIREFOX : CHROME;
    const country = COUNTRIES[n % COUNTRIES.length]!;
    const host = n % 4 === 0 ? "docs.example.com" : "example.com";
    const views = 1 + (n % 4);
    for (let p = 0; p < views; p++) {
      const id = `pv${n}x${p}`;
      const page = PAGES[(n + p * 3) % PAGES.length]!;
      const query = p === 0 ? `?utm_campaign=${encodeURIComponent(CAMPAIGNS[n % CAMPAIGNS.length]!)}${n % 2 ? "&utm_source=newsletter" : ""}` : "";
      await send({ k: "pageview", u: `https://${host}${page}${query}`, r: p === 0 ? REFERRERS[n % REFERRERS.length] : "", i: id, t: `Title ${page}` }, ip, ua, country);
      now += 20_000 + (n % 5) * 7_000;
      if (n % 2 === 0) await send({ k: "engagement", u: `https://${host}${page}`, i: id, e: 9_000 + n * 100, d: 40 + (n % 60) }, ip, ua, country);
      if (n % 4 === 0) await send({ k: "event", u: `https://${host}${page}`, i: id, n: "Signup", p: { plan: n % 8 ? "pro" : "team", seats: String(n % 5) } }, ip, ua, country);
      if (n % 3 === 0) await send({ k: "event", u: `https://${host}${page}`, i: id, n: "Purchase", p: { revenue: n % 6 ? String(10 + (n % 7) + 0.5) : "not a number", url: `https://github.com/x${n % 3}` } }, ip, ua, country);
      if (n % 7 === 0) await send({ k: "event", u: `https://${host}${page}`, i: id, n: "Buy button" }, ip, ua, country);
    }
    now += 3 * HOUR + (n % 7) * MIN;
  }
  now += DAY - 7 * (3 * HOUR) - 30 * MIN;
}
now = start - 2 * HOUR;
// A few in the last minutes, for realtime.
for (let i = 0; i < 4; i++) {
  await send({ k: "pageview", u: `https://example.com${PAGES[i]}`, r: REFERRERS[i], i: `rt${i}` }, `198.51.100.${i}`, CHROME, COUNTRIES[i]!);
  now += MIN;
}
now = start;

// Imported history: visits with no pageview id and no engaged time, and a session a short link click opened alone.
const old = start - 8 * DAY;
for (let i = 0; i < 5; i++) {
  await store.db.run(
    `INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported, source, channel, country) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1, 'Umami', 'Direct', 'NL')`,
    [`imp${i}`, `iv${i}`, old + i * MIN, old + i * MIN + 30_000],
  );
  await store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')`, [old + i * MIN, `iv${i}`, `imp${i}`]);
}

// Goals and funnels.
const goal = (id: string, g: Record<string, unknown>) => store.saveGoal({ id, site: "default", clickBy: "", valueMode: "none", value: 0, valueProp: "", currency: "USD", createdAt: start, ...g } as never);
await goal("a".repeat(24), { name: "Signup", kind: "event", match: "Signup" });
await goal("b".repeat(24), { name: "Purchase", kind: "event", match: "Purchase", valueMode: "prop", valueProp: "revenue", currency: "EUR" });
await goal("c".repeat(24), { name: "Thank you page", kind: "page", match: "/thanks*", valueMode: "fixed", value: 9.99 });
await goal("d".repeat(24), { name: "Buy button", kind: "click", clickBy: "selector", match: ".buy" });
await goal("e".repeat(24), { name: "Blog", kind: "page", match: "/blog/*" });
await goal("f".repeat(24), { name: "Café", kind: "page", match: "/caf%C3%A9" });
await store.saveFunnel({ id: "1".repeat(24), site: "default", name: "Checkout", steps: [{ kind: "page", match: "/pricing" }, { kind: "event", match: "Signup" }, { kind: "page", match: "/thanks*" }], createdAt: start });
await store.saveFunnel({ id: "2".repeat(24), site: "default", name: "Blog to buy", steps: [{ kind: "page", match: "/blog/*" }, { kind: "event", match: "Purchase" }], createdAt: start + 1 });

// Short links, their domain, and clicks: some from visitors, some imported as counts with none.
await store.addLinkDomain("go.example.com", "default", start);
await store.insertLink({ id: "l".repeat(24), site: "default", domain: "", slug: "launch", name: "Launch", url: "https://example.com/launch", createdAt: start - 9 * DAY, updatedAt: start - 9 * DAY });
await store.insertLink({ id: "m".repeat(24), site: "default", domain: "go.example.com", slug: "docs", name: "", url: "https://docs.example.com/", createdAt: start - 5 * DAY, updatedAt: start - 4 * DAY });
await store.insertLink({ id: "n".repeat(24), site: "default", domain: "", slug: "gone", name: "Gone", url: "https://example.com/gone", createdAt: start - 3 * DAY, updatedAt: start - 3 * DAY });
await store.deleteLink("n".repeat(24), start - DAY);
for (let i = 0; i < 12; i++) {
  const ts = start - (i + 1) * 17 * HOUR;
  const session = `click${i}`;
  await store.insertSession({
    id: session, site: "default", visitor: `cv${i % 5}`, startedAt: ts, hostname: "example.com", referrerHost: i % 2 ? "t.co" : "", referrerPath: "", source: i % 2 ? "Twitter" : "",
    channel: i % 2 ? "Social" : "Direct", utmSource: "", utmMedium: "", utmCampaign: "", utmTerm: "", utmContent: "", country: COUNTRIES[i % 5]!, region: "", city: "", browser: "Chrome",
    browserVersion: "129", os: "macOS", osVersion: "", device: i % 3 ? "Desktop" : "Mobile", screen: "", language: "en",
  });
  await store.insertEvent({ site: "default", ts, kind: "click", visitor: `cv${i % 5}`, session, pageview: "", path: "", hostname: "example.com", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: i % 3 ? "l".repeat(24) : "m".repeat(24) });
  await store.touchSession(session, ts, "click", "");
}
for (let i = 0; i < 3; i++) {
  await store.insertEvent({ site: "default", ts: start - (i + 2) * DAY, kind: "click", visitor: "", session: "", pageview: "", path: "", hostname: "", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: "l".repeat(24) });
}

// AI agent fetches.
for (let i = 0; i < 9; i++) {
  await store.insertEvent({
    site: "default", ts: start - i * 5 * HOUR, kind: "fetch", visitor: "", session: "", pageview: "", path: PAGES[i % 4]!, hostname: "example.com", title: "",
    name: ["GPTBot", "ClaudeBot", "PerplexityBot"][i % 3]!, props: { company: "X", kind: "crawler" }, engagedMs: 0, scroll: null, link: "",
  });
}

// Shares, tokens, reports, settings, and a second site with its overrides.
await store.insertShare({ id: "s".repeat(24), site: "default", name: "Client", createdAt: start - DAY });
await store.insertShare({ id: "t".repeat(24), site: "default", name: "", createdAt: start - 2 * DAY });
await store.insertToken({ id: "k".repeat(24), name: "Script", site: "", scope: "read", hash: "h".repeat(64), hint: "abcd", createdAt: start - DAY, lastUsedAt: null });
await store.insertToken({ id: "j".repeat(24), name: "Hub", site: "default", scope: "manage", hash: "g".repeat(64), hint: "wxyz", createdAt: start - DAY, lastUsedAt: start - HOUR });
await store.insertReport({ id: "r".repeat(24), site: "default", email: "a@example.com", frequency: "weekly", lang: "en", token: "q".repeat(32), origin: "https://example.com/runlight", lastPeriod: "w:2026-09-28", lastSentAt: start - 3 * DAY, createdAt: start - 9 * DAY });
await store.insertReport({ id: "p".repeat(24), site: "default", email: "b@example.com", frequency: "monthly", lang: "de", token: "o".repeat(32), origin: "", lastPeriod: "", lastSentAt: null, createdAt: start - 9 * DAY });
await store.setSetting("mail", JSON.stringify({ transport: "smtp" }));
await store.setSetting("remote:one", "1");
await store.setSetting("remote:two", "2");
await store.setSetting("remote_x", "3");
await store.upsertSite({ id: "second", name: "Second", hostnames: [], timezone: "Asia/Kolkata" }, start);
await store.setSiteOverrides("second", { name: "Renamed", timezone: "Europe/Paris" });

// Days rolled up, with a few scattered through left unbuilt, as late engagement leaves them.
while ((await rl.buildRollups()) > 0);
for (const d of [3, 7]) await store.clearRollups("default", { from: start - d * DAY, to: start - d * DAY + 1 });

// The reads.
const site = "default";
const days = [...(await store.rollupDays(site))].sort();
const filters: Array<Array<{ dimension: string; op: string; value: string }>> = [
  [],
  [{ dimension: "country", op: "is", value: "GB" }],
  [{ dimension: "country", op: "not", value: "GB" }],
  [{ dimension: "page", op: "is", value: "/pricing" }],
  [{ dimension: "page", op: "contains", value: "blog" }],
  [{ dimension: "page", op: "contains", value: "über" }],
  [{ dimension: "page", op: "is", value: "/café" }],
  [{ dimension: "event", op: "is", value: "Signup" }],
  [{ dimension: "event", op: "not", value: "Signup" }],
  [{ dimension: "utm_campaign", op: "contains", value: "émile" }],
  [{ dimension: "hostname", op: "is", value: "docs.example.com" }, { dimension: "page", op: "contains", value: "/" }],
  [{ dimension: "page", op: "is", value: "/pricing" }, { dimension: "page", op: "is", value: "/about" }, { dimension: "source", op: "not", value: "Google" }],
  [{ dimension: "entry", op: "contains", value: "BLOG" }, { dimension: "browser", op: "is", value: "Safari" }],
];
const ranges: Array<[number, number]> = [
  [start - 7 * DAY, start],
  [start - 30 * DAY, start + DAY],
  [start - 5 * DAY - 7 * HOUR, start - 2 * DAY + 3 * HOUR],
  [start - 12 * HOUR, start + HOUR],
  [0, start + DAY],
];
const dims = ["page", "hostname", "event", "entry", "exit", "referrer", "source", "channel", "utm_source", "utm_campaign", "country", "browser", "os", "device", "language", "ai_agent", "ai_page"];
const calls: Call[] = [];
const add = (method: string, ...args: unknown[]) => calls.push({ method, args });
const dayBuckets = (from: number, count: number, size: number) => Array.from({ length: count }, (_, i) => ({ start: from + i * size, end: from + (i + 1) * size }));

add("sites");
add("siteOverrides");
add("lastSeen", site);
add("lastSeen", "nowhere");
add("firstSeen", site);
add("firstOwnVisit", site);
add("rollupDays", site);
for (const [from, to] of ranges) {
  for (const f of filters) {
    const query = { site, from, to, filters: f };
    add("stats", query);
    add("visitors", query);
    add("hourly", query);
    for (const dimension of dims) add("breakdown", query, dimension, 4, 0);
    add("goalTotalsAll", query, await store.goals(site));
    add("funnelCounts", query, (await store.funnels(site))[0]);
    add("journeyPages", query, 4);
    add("eventPropKeys", query, "Signup");
    add("eventPropValues", query, "Purchase", "revenue", 5);
  }
  const query = { site, from, to, filters: [] };
  for (const dimension of dims) add("breakdown", query, dimension, 3, 2);
  for (const g of await store.goals(site)) {
    add("goalTotals", query, g);
    for (const by of ["source", "channel", "path"]) add("goalBreakdown", query, g, by, 5);
  }
  add("funnelCounts", query, (await store.funnels(site))[1]);
  add("eventPropValues", query, "Signup", "plan", 10);
  add("eventPropValues", query, "Signup", "seats", 10);
  add("eventPropValues", query, "Purchase", "url", 10);
  add("links", site, from, to);
  for (const dimension of ["source", "channel", "country", "device"]) add("linkBreakdown", site, "l".repeat(24), from, to, dimension, 5);
}
const daily = dayBuckets(start - 14 * DAY, 15, DAY);
const hourly = dayBuckets(start - 2 * DAY, 48, HOUR);
const local = days.length ? dayBuckets(start - 12 * DAY - 6 * HOUR + 4 * HOUR, 13, DAY) : daily;
for (const f of filters.slice(0, 6)) {
  const q = { site, filters: f };
  add("series", q, daily);
  add("series", q, hourly);
  add("series", q, local);
  for (const g of (await store.goals(site)).slice(0, 3)) add("goalSeries", q, g, daily);
}
add("linkSeries", site, "l".repeat(24), daily);
add("linkSeries", site, "m".repeat(24), hourly);
add("realtime", site, start);
add("realtime", site, start - 2 * HOUR + 3 * MIN);
add("goals", site);
add("goals");
add("goalById", "b".repeat(24));
add("goalById", "nothing");
add("funnels", site);
add("linkBySlug", "launch");
add("linkBySlug", "gone");
add("linkById", "m".repeat(24));
add("linkDomains");
add("shares", site);
add("shareById", "s".repeat(24));
add("shareById", "x");
add("tokens");
add("tokenByHash", "g".repeat(64));
add("tokenByHash", "nope");
add("reports");
add("reports", site);
add("reportBy", "token", "q".repeat(32));
add("reportBy", "id", "p".repeat(24));
add("setting", "mail");
add("setting", "absent");
add("settingsStartingWith", "remote:");
add("settingsStartingWith", "remote_");
const [pv] = await store.db.all<{ pageview: string }>(`SELECT pageview FROM rl_events WHERE kind = 'pageview' AND pageview <> '' ORDER BY ts LIMIT 1`);
add("pageview", site, pv!.pageview);
add("pageview", site, "missing");
const [open] = await store.db.all<{ visitor: string; last_at: number }>(`SELECT visitor, last_at FROM rl_sessions WHERE site = 'default' AND imported = 0 ORDER BY last_at DESC, id LIMIT 1`);
add("openSession", site, [open!.visitor, "other"], Number(open!.last_at) - HOUR);
add("openSession", site, [], 0);
const [salt] = await store.db.all<{ day: string }>(`SELECT day FROM rl_salts ORDER BY day LIMIT 1`);
add("saltIfExists", salt!.day);
add("saltIfExists", "1999-01-01");

const results = await answers(store, calls);
await store.db.run("PRAGMA journal_mode = DELETE");
await store.close();
const fixtures = new URL("../packages/php/tests/fixtures/", import.meta.url);
copyFileSync(file, new URL("store.db", fixtures));
writeFileSync(
  new URL("store.json", fixtures),
  `${JSON.stringify({ description: "SqlStore reads over store.db, as the TypeScript SDK answers them. Written by scripts/php-fixtures-store.mts.", now: start, calls: calls.map((call, i) => ({ ...call, result: results[i] })) })}\n`,
);
rmSync(dir, { recursive: true, force: true });
console.log(`${calls.length} reads over ${days.length} built days`);
