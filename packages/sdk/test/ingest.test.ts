import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { SAFARI_IPHONE, STORES, cleanup, setup as setupFor, type StoreKind } from "./helpers.js";

after(cleanup);

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
const setup = (options?: Parameters<typeof setupFor>[1]) => setupFor(kind, options);

const MIN = 60_000;

test("a visit: pageviews, an event, engagement, and the reports that follow", async () => {
  const t = setup();
  await t.send({ k: "pageview", u: "https://example.com/?utm_source=chatgpt.com", r: "https://chatgpt.com/", i: "pv1", t: "Home", w: 1440, h: 900, l: "en-GB" }, {
    headers: { "x-vercel-ip-country": "GB", "x-vercel-ip-country-region": "ENG", "x-vercel-ip-city": "London" },
  });
  t.advance(20_000);
  await t.send({ k: "engagement", u: "https://example.com/", i: "pv1", e: 18_000, d: 75 });
  await t.send({ k: "pageview", u: "https://example.com/pricing", r: "https://example.com/", i: "pv2", w: 1440, h: 900 });
  t.advance(5_000);
  await t.send({ k: "event", u: "https://example.com/pricing", i: "pv2", n: "Signup", p: { plan: "pro" } });

  // A second visitor on a phone who bounces.
  await t.send({ k: "pageview", u: "https://example.com/blog/post", r: "https://news.ycombinator.com/", i: "pv3", w: 390, h: 844 }, { ua: SAFARI_IPHONE, ip: "198.51.100.7" });
  await t.send({ k: "engagement", u: "https://example.com/blog/post", i: "pv3", e: 4_000 }, { ua: SAFARI_IPHONE, ip: "198.51.100.7" });

  const { stats, range } = await t.get("/api/stats?period=today");
  assert.equal(range.from, "2026-10-06");
  assert.deepEqual(stats, {
    visitors: 2,
    visits: 2,
    pageviews: 3,
    viewsPerVisit: 1.5,
    bounceRate: 0.5,
    visitDuration: 11_000,
  });

  const rows = async (dimension: string, extra = "") => (await t.get(`/api/breakdown?period=today&dimension=${dimension}${extra}`)).rows;
  assert.deepEqual(await rows("channel"), [
    { value: "AI", visitors: 1, visits: 1, pageviews: 2, bounceRate: 0, visitDuration: 18_000 },
    { value: "Social", visitors: 1, visits: 1, pageviews: 1, bounceRate: 1, visitDuration: 4_000 },
  ]);
  assert.deepEqual((await rows("source")).map((r: any) => r.value), ["ChatGPT", "Hacker News"]);
  assert.deepEqual((await rows("country")).map((r: any) => r.value), ["GB"]);
  assert.deepEqual((await rows("region")).map((r: any) => r.value), ["GB-ENG"]);
  assert.deepEqual((await rows("device")).map((r: any) => r.value).sort(), ["desktop", "mobile"]);
  assert.deepEqual((await rows("screen")).map((r: any) => r.value).sort(), ["1440x900", "390x844"]);
  assert.deepEqual(await rows("event"), [{ value: "Signup", visitors: 1, events: 1 }]);
  assert.deepEqual((await rows("exit")).map((r: any) => [r.value, r.visits]), [["/blog/post", 1], ["/pricing", 1]]);

  const pages = await rows("page");
  const home = pages.find((p: any) => p.value === "/");
  assert.deepEqual(home, { value: "/", visitors: 1, pageviews: 1, timeOnPage: 18_000, scrollDepth: 75 });

  const entry = await rows("entry");
  assert.equal(entry.find((r: any) => r.value === "/blog/post").bounceRate, 1);
  assert.equal(entry.find((r: any) => r.value === "/").bounceRate, 0);

  // Filters narrow everything to matching visits.
  const fromHn = await t.get("/api/stats?period=today&filter=source:is:Hacker%20News&compare=false");
  assert.equal(fromHn.stats.visitors, 1);
  assert.equal(fromHn.stats.pageviews, 1);
  assert.equal(fromHn.previous, undefined);
  const pricing = await t.get("/api/stats?period=today&filter=page:contains:pric");
  assert.equal(pricing.stats.pageviews, 1);

  const series = await t.get("/api/series?period=today");
  assert.equal(series.points.length, 24);
  assert.equal(series.points[12].pageviews, 3);
  assert.equal(series.points[12].bounceRate, 0.5);
  assert.equal(series.points[12].visitDuration, 11_000);
  assert.equal(series.points[12].viewsPerVisit, 1.5);
  assert.equal(series.points[11].bounceRate, 0);

  const rhythm = await t.get("/api/rhythm?period=today");
  assert.equal(rhythm.grid.length, 7);
  assert.equal(rhythm.grid[1][12], 2, "two visits on Tuesday at noon UTC");
  assert.equal(rhythm.grid.flat().reduce((a: number, b: number) => a + b, 0), 2);
  assert.deepEqual(rhythm.cells[1][12], { visits: 2, visitors: 2, pageviews: 3, bounceRate: 0.5 });

  const lastYear = await t.get("/api/stats?period=today&compare=year");
  assert.deepEqual(lastYear.compare, { from: "2025-10-06", to: "2025-10-06" });
  assert.equal(lastYear.previous.visitors, 0);
  const off = await t.get("/api/series?period=today&compare=off");
  assert.equal(off.previous, undefined);
  const withPrevious = await t.get("/api/series?period=today");
  assert.equal(withPrevious.previous.length, 24);
  await assert.rejects(t.get("/api/stats?period=today&compare=custom"));
  await assert.rejects(t.get("/api/stats?period=today&compare=sideways"));

  const live = await t.get("/api/realtime");
  assert.equal(live.visitors, 2);
  assert.equal(live.minutes.length, 30);
  assert.equal(live.minutes.reduce((a: number, b: number) => a + b, 0), 3);
  assert.ok(Array.isArray(live.countries));
  assert.equal(live.recent.length, 4, "three pageviews and an event");
  assert.ok(live.recent[0].ts >= live.recent[3].ts, "newest first");
  for (const r of live.recent) {
    assert.deepEqual(Object.keys(r).sort(), ["city", "country", "device", "kind", "name", "path", "source", "ts"], "what happened, never who");
  }
});

test("thirty idle minutes start a new session; a new day is a new visitor", async () => {
  const t = setup();
  await t.send({ k: "pageview", u: "https://example.com/", i: "a1" });
  t.advance(29 * MIN);
  await t.send({ k: "pageview", u: "https://example.com/a", i: "a2" });
  t.advance(31 * MIN);
  await t.send({ k: "pageview", u: "https://example.com/b", i: "a3" });
  let { stats } = await t.get("/api/stats?period=today");
  assert.equal(stats.visits, 2);
  assert.equal(stats.visitors, 1);

  t.advance(24 * 60 * MIN);
  await t.send({ k: "pageview", u: "https://example.com/", i: "a4" });
  ({ stats } = await t.get("/api/stats?period=7d"));
  assert.equal(stats.visitors, 2, "the same person on another day is counted again");
});

test("a session that runs past midnight UTC stays one session", async () => {
  const t = setup();
  t.advance(11 * 60 * MIN + 50 * MIN); // 23:50 UTC
  await t.send({ k: "pageview", u: "https://example.com/", i: "m1" });
  t.advance(20 * MIN); // 00:10 the next day
  await t.send({ k: "pageview", u: "https://example.com/next", i: "m2" });
  const { stats } = await t.get("/api/stats?period=7d");
  assert.equal(stats.visits, 1);
  assert.equal(stats.pageviews, 2);
});

test("a salt is deleted once its day has ended everywhere", async () => {
  const t = setup();
  await t.send({ k: "pageview", u: "https://example.com/", i: "s1" });
  for (let i = 0; i < 3; i++) {
    t.advance(24 * 60 * MIN);
    await t.send({ k: "pageview", u: "https://example.com/", i: `s${i + 2}` });
  }
  await t.rl.check();
  // October 9th at noon UTC: the earliest timezone is on the 8th and still needs the 7th.
  const salts = await t.rl.store.db.all<{ day: string }>("SELECT day FROM rl_salts ORDER BY day");
  assert.deepEqual(salts.map((s) => s.day), ["2026-10-07", "2026-10-08", "2026-10-09"]);
});

test("a visitor is one visitor for the whole of the site's own day", async () => {
  // Toronto: 11pm on the 6th and 1am on the 7th UTC are both the evening of October 6th.
  const t = setup({ site: { timezone: "America/Toronto" } });
  t.advance(11 * 60 * MIN);
  await t.send({ k: "pageview", u: "https://example.com/", i: "t1" });
  t.advance(2 * 60 * MIN);
  await t.send({ k: "pageview", u: "https://example.com/later", i: "t2" });
  const { stats } = await t.get("/api/stats?from=2026-10-06&to=2026-10-06&compare=off");
  assert.equal(stats.visits, 2, "two hours apart is two visits");
  assert.equal(stats.visitors, 1, "but one visitor, since it is the same day in Toronto");
});

test("nothing identifying is stored", async () => {
  const t = setup();
  await t.send({ k: "pageview", u: "https://example.com/?email=jane@example.org&utm_campaign=x", i: "p1" }, { ip: "192.0.2.55" });
  const dump = JSON.stringify([
    await t.rl.store.db.all("SELECT * FROM rl_sessions"),
    await t.rl.store.db.all("SELECT * FROM rl_events"),
  ]);
  assert.ok(!dump.includes("192.0.2.55"), "no IP");
  assert.ok(!dump.includes("jane@example.org"), "no query string");
  assert.ok(!dump.includes("AppleWebKit"), "no user agent");
});

test("bots, AI agents, junk, and other sites are dropped quietly", async () => {
  const t = setup({ site: { hostnames: ["example.com"] } });
  await t.send({ k: "pageview", u: "https://example.com/", i: "b1" }, { ua: "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" });
  await t.send({ k: "pageview", u: "https://example.com/", i: "b2" }, { ua: "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)" });
  await t.send({ k: "pageview", u: "https://elsewhere.net/", i: "b3" });
  await t.send({ k: "pageview", u: "javascript:alert(1)" });
  await t.send({ k: "nonsense", u: "https://example.com/" });
  await t.send({ k: "event", u: "https://example.com/" });
  const response = await t.routes.POST(new Request("https://example.com/runlight/e", { method: "POST", body: "{not json" }));
  assert.equal(response.status, 202);
  const { stats } = await t.get("/api/stats?period=today");
  assert.equal(stats.pageviews, 0);
});

test("AI agents are recorded as fetches by observe()", async () => {
  const t = setup();
  const fetch = (path: string, ua: string) => t.rl.observe(new Request(`https://example.com${path}`, { headers: { "user-agent": ua, host: "example.com" } }));
  await fetch("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot");
  await fetch("/blog/post", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)");
  await fetch("/logo.png", "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)");
  await fetch("/", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36");
  const agents = (await t.get("/api/breakdown?period=today&dimension=ai_agent")).rows;
  assert.deepEqual(agents, [
    { value: "ChatGPT-User", visitors: 0, fetches: 1 },
    { value: "ClaudeBot", visitors: 0, fetches: 1 },
  ]);
  const pages = (await t.get("/api/breakdown?period=today&dimension=ai_page")).rows;
  assert.deepEqual(pages, [{ value: "/blog/post", visitors: 0, fetches: 2 }]);
  const { stats } = await t.get("/api/stats?period=today");
  assert.equal(stats.visitors, 0, "fetches are not visits");
});

test("several sites in one install, told apart by hostname", async () => {
  const t = setup({
    sites: [
      { id: "brand-a", hostnames: ["brand-a.com"] },
      { id: "brand-b", hostnames: ["brand-b.com"], timezone: "America/Toronto" },
    ],
  });
  await t.send({ k: "pageview", u: "https://www.brand-a.com/", i: "x1" });
  await t.send({ k: "pageview", u: "https://brand-b.com/", i: "x2" });
  await t.send({ k: "pageview", u: "https://brand-b.com/two", i: "x3" });
  assert.equal((await t.get("/api/stats?period=today&site=brand-a")).stats.pageviews, 1);
  assert.equal((await t.get("/api/stats?period=today&site=brand-b")).stats.pageviews, 2);
  assert.equal((await t.get("/api/sites")).sites.length, 2);
  await assert.rejects(t.get("/api/stats?site=brand-c"));
});
}

test("a region name from a location database is kept readable, and a code stays a code", async () => {
  const { runlight } = await import("../src/index.js");
  const { sqlite } = await import("../src/stores/sqlite.js");
  const names: Record<string, { country: string; region: string; city: string }> = {
    "203.0.113.1": { country: "ca", region: "Ontario", city: "Toronto" },
    "203.0.113.2": { country: "GB", region: "ENG", city: "London" },
  };
  const rl = runlight({ store: sqlite({ path: ":memory:" }), geo: (ip) => names[ip] ?? null });
  const { GET, POST } = rl.routes({ token: null });
  for (const ip of Object.keys(names)) {
    await POST(new Request("https://x.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": ip }, body: JSON.stringify({ k: "pageview", u: "https://x.com/" }) }));
  }
  const rows = (await (await GET(new Request("https://x.com/runlight/api/breakdown?period=today&dimension=region"))).json()) as any;
  assert.deepEqual(rows.rows.map((r: any) => r.value).sort(), ["CA-Ontario", "GB-ENG"]);
});
