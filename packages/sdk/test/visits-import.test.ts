import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { importUmamiVisits, umamiWebsites } from "../src/importers/visits.js";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const DAY = 86_400_000;
const at = (iso: string) => new Date(iso).toISOString();

/** A small Umami: one website, two days of events, answering by time window like the real API. */
function fakeUmami() {
  const events = [
    // Visit 1: Google, two pages and a signup, in Toronto on a phone.
    { sessionId: "s1", createdAt: at("2026-03-01T10:00:00Z"), hostname: "blog.example.com", urlPath: "/", urlQuery: "utm_campaign=spring", referrerDomain: "www.google.com", referrerPath: "/", pageTitle: "Home", eventType: 1, country: "CA", city: "Toronto", device: "mobile", os: "iOS", browser: "ios" },
    { sessionId: "s1", createdAt: at("2026-03-01T10:02:00Z"), hostname: "blog.example.com", urlPath: "/pricing", pageTitle: "Pricing", eventType: 1, country: "CA", city: "Toronto", device: "mobile", os: "iOS", browser: "ios" },
    { sessionId: "s1", createdAt: at("2026-03-01T10:03:00Z"), hostname: "blog.example.com", urlPath: "/pricing", eventType: 2, eventName: "Signup", country: "CA", city: "Toronto", device: "mobile", os: "iOS", browser: "ios" },
    // The same Umami session two hours later is a second visit.
    { sessionId: "s1", createdAt: at("2026-03-01T12:30:00Z"), hostname: "blog.example.com", urlPath: "/blog", eventType: 1, country: "CA", city: "Toronto", device: "mobile", os: "iOS", browser: "ios" },
    // Visit 3: direct, desktop, the next day.
    { sessionId: "s2", createdAt: at("2026-03-02T09:00:00Z"), hostname: "blog.example.com", urlPath: "/", eventType: 1, country: "GB", city: "London", device: "desktop", os: "Mac OS", browser: "chrome" },
    // A performance event is not a visit.
    { sessionId: "s2", createdAt: at("2026-03-02T09:00:01Z"), hostname: "blog.example.com", urlPath: "/", eventType: 5, country: "GB", city: "London", device: "desktop", os: "Mac OS", browser: "chrome" },
  ];
  const sessions = [
    { id: "s1", screen: "390x844", language: "en-CA", region: "CA-ON" },
    { id: "s2", screen: "1440x900", language: "en-GB", region: "GB-ENG" },
  ];
  const asked: string[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    asked.push(url.pathname);
    assert.equal(new Headers(init.headers).get("authorization"), "Bearer key", "every request carries the key");
    const reply = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
    if (url.pathname === "/api/websites") return reply({ data: [{ id: "w1", name: "Blog", domain: "blog.example.com" }], count: 1 });
    if (url.pathname === "/api/websites/w1") return reply({ id: "w1", createdAt: at("2026-03-01T08:00:00Z") });
    const from = Number(url.searchParams.get("startAt"));
    const to = Number(url.searchParams.get("endAt"));
    const inside = (iso: string) => Date.parse(iso) >= from && Date.parse(iso) <= to;
    if (url.pathname === "/api/websites/w1/events") {
      // Umami answers newest first.
      const rows = events.filter((e) => inside(e.createdAt)).reverse();
      return reply({ data: rows, count: rows.length });
    }
    if (url.pathname === "/api/websites/w1/sessions") return reply({ data: sessions, count: sessions.length });
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  return asked;
}

test("Umami visit history: pageviews and events become visits, with sources, places, and devices", async () => {
  fakeUmami();
  const credentials = { url: "https://umami.example.com", apiKey: "key" };
  assert.deepEqual(await umamiWebsites(credentials), [{ id: "w1", name: "Blog", domain: "blog.example.com" }]);

  let now = Date.parse("2026-03-04T00:00:00Z");
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => now });
  let cursor: string | null = null;
  const totals = { pageviews: 0, events: 0, visits: 0, steps: 0 };
  do {
    const step = await importUmamiVisits(rl, "default", credentials, "w1", cursor);
    cursor = step.cursor;
    totals.pageviews += step.pageviews;
    totals.events += step.events;
    totals.visits += step.visits;
    totals.steps++;
    assert.ok(step.done <= step.total);
  } while (cursor);
  assert.deepEqual({ pageviews: totals.pageviews, events: totals.events, visits: totals.visits }, { pageviews: 4, events: 1, visits: 3 });

  const { GET } = rl.routes({ token: null });
  const get = async (path: string) => (await GET(new Request(`https://x.com/runlight${path}`))).json() as Promise<any>;
  const range = "from=2026-03-01&to=2026-03-03&compare=off";
  const stats = await get(`/api/stats?${range}`);
  assert.equal(stats.stats.pageviews, 4);
  assert.equal(stats.stats.visits, 3);
  assert.equal(stats.stats.visitors, 2, "one Umami session on one day is one visitor");
  assert.ok(stats.stats.visitDuration > 0, "imported visits take their length from first to last pageview");
  const sources = await get(`/api/breakdown?${range}&dimension=source`);
  assert.deepEqual(sources.rows.map((r: any) => r.value), ["Google"]);
  const regions = await get(`/api/breakdown?${range}&dimension=region`);
  assert.deepEqual(regions.rows.map((r: any) => r.value).sort(), ["CA-ON", "GB-ENG"]);
  const browsers = await get(`/api/breakdown?${range}&dimension=browser`);
  assert.deepEqual(browsers.rows.map((r: any) => r.value).sort(), ["Chrome", "Safari"]);
  const events = await get(`/api/breakdown?${range}&dimension=event`);
  assert.deepEqual(events.rows.map((r: any) => r.value), ["Signup"]);
  const campaigns = await get(`/api/breakdown?${range}&dimension=utm_campaign`);
  assert.deepEqual(campaigns.rows.map((r: any) => r.value), ["spring"]);

  // Running it again carries on from where it stopped, so nothing doubles.
  now += DAY;
  const again = await importUmamiVisits(rl, "default", credentials, "w1", null);
  assert.equal(again.pageviews, 0);
  assert.equal((await get(`/api/stats?${range}`)).stats.pageviews, 4);

  // No imported visitor id lasts past a day.
  const ids = await rl.store.db.all<{ visitor: string; day: string }>(`SELECT DISTINCT visitor, date(ts / 1000, 'unixepoch') AS day FROM rl_events`);
  const days = new Map<string, Set<string>>();
  for (const r of ids) (days.get(r.visitor) ?? days.set(r.visitor, new Set()).get(r.visitor)!).add(r.day);
  for (const set of days.values()) assert.equal(set.size, 1);
});

test("Umami visit history stops where Runlight's own visits begin", async () => {
  fakeUmami();
  const credentials = { url: "https://umami.example.com", apiKey: "key" };
  const now = Date.parse("2026-03-04T00:00:00Z");
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse("2026-03-01T23:00:00Z") });
  // Runlight started counting on the evening of March 1st.
  await rl.routes({ token: null }).POST(new Request("https://x.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.9" }, body: JSON.stringify({ k: "pageview", u: "https://blog.example.com/" }) }));
  void now;
  let cursor: string | null = null;
  let pageviews = 0;
  do {
    const step = await importUmamiVisits(rl, "default", credentials, "w1", cursor);
    cursor = step.cursor;
    pageviews += step.pageviews;
  } while (cursor);
  assert.equal(pageviews, 3, "March 2nd is left to Runlight");
});

test("a step that failed part way can run again without counting anything twice", async () => {
  fakeUmami();
  const credentials = { url: "https://umami.example.com", apiKey: "key" };
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse("2026-03-04T00:00:00Z") });
  // A database with no transactions fails after writing half of the first step.
  const store = rl.store;
  const realTransaction = store.transaction.bind(store);
  let failNext = true;
  store.transaction = (async (fn: (s: typeof store) => Promise<unknown>) => {
    if (!failNext) return realTransaction(fn as never);
    failNext = false;
    let writes = 0;
    const realInsert = store.insertEvent.bind(store);
    store.insertEvent = (async (row: Parameters<typeof realInsert>[0]) => {
      if (++writes > 2) throw new Error("connection lost");
      return realInsert(row);
    }) as typeof store.insertEvent;
    try {
      return await fn(store);
    } finally {
      store.insertEvent = realInsert;
    }
  }) as typeof store.transaction;
  await assert.rejects(importUmamiVisits(rl, "default", credentials, "w1", null), /connection lost/);

  let cursor: string | null = null;
  do cursor = (await importUmamiVisits(rl, "default", credentials, "w1", cursor)).cursor;
  while (cursor);
  const { GET } = rl.routes({ token: null });
  const stats = (await (await GET(new Request("https://x.com/runlight/api/stats?from=2026-03-01&to=2026-03-03&compare=off"))).json()) as any;
  assert.equal(stats.stats.pageviews, 4);
  assert.equal(stats.stats.visits, 3);
  const totals = await rl.store.db.all<{ pageviews: number; events: number }>(`SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions`);
  assert.deepEqual({ pageviews: Number(totals[0]!.pageviews), events: Number(totals[0]!.events) }, { pageviews: 4, events: 1 });
});

test("Umami visit history skips days older than the site keeps", async () => {
  fakeUmami();
  const credentials = { url: "https://umami.example.com", apiKey: "key" };
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse("2026-09-01T12:00:00Z") });
  await rl.init();
  // Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
  await rl.setRetention("default", 6);
  let cursor: string | null = null;
  let pageviews = 0;
  do {
    const step = await importUmamiVisits(rl, "default", credentials, "w1", cursor);
    cursor = step.cursor;
    pageviews += step.pageviews;
  } while (cursor);
  assert.equal(pageviews, 1, "only March 2nd comes in");
});

test("an imported visit across UTC midnight is one visit on the site's own day", async () => {
  const events = [
    { sessionId: "n1", createdAt: "2026-03-02T23:55:00.000Z", hostname: "blog.example.com", urlPath: "/", eventType: 1, country: "CA", device: "desktop", os: "Mac OS", browser: "chrome" },
    { sessionId: "n1", createdAt: "2026-03-03T00:05:00.000Z", hostname: "blog.example.com", urlPath: "/about", eventType: 1, country: "CA", device: "desktop", os: "Mac OS", browser: "chrome" },
  ];
  globalThis.fetch = (async (input: string | URL | Request) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const reply = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
    if (url.pathname === "/api/websites/w1") return reply({ id: "w1", createdAt: "2026-03-02T00:00:00Z" });
    const from = Number(url.searchParams.get("startAt"));
    const to = Number(url.searchParams.get("endAt"));
    if (url.pathname === "/api/websites/w1/events") {
      const rows = events.filter((e) => Date.parse(e.createdAt) >= from && Date.parse(e.createdAt) <= to);
      return reply({ data: rows, count: rows.length });
    }
    if (url.pathname === "/api/websites/w1/sessions") return reply({ data: [{ id: "n1" }], count: 1 });
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "America/Toronto" }, now: () => Date.parse("2026-03-10T00:00:00Z") });
  let cursor: string | null = null;
  do {
    cursor = (await importUmamiVisits(rl, "default", { url: "https://umami.example.com", apiKey: "key" }, "w1", cursor)).cursor;
  } while (cursor);
  const stats = (await (await rl.routes({ token: "t" }).GET(new Request("https://x/runlight/api/stats?from=2026-03-02&to=2026-03-02&compare=off", { headers: { authorization: "Bearer t" } }))).json()) as any;
  assert.deepEqual([stats.stats.visits, stats.stats.visitors, stats.stats.pageviews], [1, 1, 2]);
});

test("Umami visit history: an unreadable saved progress setting starts as if there were none", async () => {
  fakeUmami();
  const credentials = { url: "https://umami.example.com", apiKey: "key" };
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse("2026-03-04T00:00:00Z") });
  await rl.init();
  await rl.store.setSetting("import:umami-visits:default:w1", "not a number");
  let cursor: string | null = null;
  let pageviews = 0;
  do {
    const step = await importUmamiVisits(rl, "default", credentials, "w1", cursor);
    assert.ok(Number.isFinite(step.done) && Number.isFinite(step.total), "progress is a number");
    cursor = step.cursor;
    pageviews += step.pageviews;
  } while (cursor);
  assert.equal(pageviews, 4, "every day is read from the website's start");
});
