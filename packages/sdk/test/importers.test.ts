import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { importStep } from "../src/importers/index.js";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Answers requests from a table of URL patterns, recording what was asked. */
function serve(routes: Array<[RegExp, (url: URL, init: RequestInit) => { status?: number; body: unknown }]>) {
  const calls: string[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    calls.push(`${init.method ?? "GET"} ${url.host}${url.pathname}`);
    for (const [pattern, answer] of routes) {
      if (pattern.test(url.href)) {
        const { status = 200, body } = answer(url, init);
        return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
      }
    }
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  return calls;
}

async function runAll(source: string, credentials: Record<string, string>) {
  const rl = runlight({ store: sqlite({ path: ":memory:" }) });
  let cursor: string | null = null;
  let done = 0;
  const totals = { links: 0, clicks: 0, skipped: 0, failed: [] as Array<{ slug: string; reason: string }> };
  do {
    const step = await importStep(rl, "default", source, credentials, cursor, done);
    cursor = step.cursor;
    done = step.done;
    totals.links += step.links;
    totals.clicks += step.clicks;
    totals.skipped += step.skipped;
    totals.failed.push(...step.failed);
  } while (cursor);
  return { rl, totals, done };
}

test("Dub: every click where the plan allows", async () => {
  serve([
    [/api\.dub\.co\/links\?.*startingAfter=l2/, () => ({ body: [] })],
    [/api\.dub\.co\/links\?/, () => ({ body: [
      { id: "l1", domain: "dub.sh", key: "launch", url: "https://a.com/launch", title: "Launch", createdAt: "2026-01-02T00:00:00Z" },
      { id: "l2", domain: "go.brand.com", key: "sale", url: "https://a.com/sale", title: null, createdAt: "2026-02-03T00:00:00Z" },
    ] })],
    [/\/events\?.*linkId=l1/, () => ({ body: [
      { timestamp: "2026-03-01T10:00:00Z", click: { id: "c1", country: "CA", city: "Toronto", device: "Mobile", browser: "Chrome", os: "iOS", referer: "instagram.com", refererUrl: "https://instagram.com/" } },
      { timestamp: "2026-03-02T10:00:00Z", click: { id: "c2", country: "US", device: "Desktop", browser: "Safari", os: "Mac OS", referer: "(direct)" } },
    ] })],
    [/\/events\?.*linkId=l2/, () => ({ body: [] })],
  ]);
  const { rl, totals } = await runAll("dub", { apiKey: "dub_test" });
  assert.equal(totals.links, 2);
  assert.equal(totals.clicks, 2);
  const links = await rl.store.links("default", 0, Date.now() + 1);
  assert.equal(links.find((l) => l.slug === "launch")!.domain, "", "dub.sh stays behind; the link moves to /go");
  assert.equal(links.find((l) => l.slug === "sale")!.domain, "go.brand.com", "branded domains come across");
  const [session] = await rl.store.db.all<{ country: string; source: string; device: string }>("SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1");
  assert.deepEqual(session, { country: "CA", source: "Instagram", device: "mobile" });
});

test("Dub: daily counts when the plan has no events API", async () => {
  serve([
    [/api\.dub\.co\/links\?/, () => ({ body: [{ id: "l1", domain: "dub.sh", key: "x", url: "https://a.com", title: "X", createdAt: "2026-01-02T00:00:00Z" }] })],
    [/\/events\?/, () => ({ status: 403, body: { error: { message: "Business plan required" } } })],
    [/\/analytics\?/, () => ({ body: [{ start: "2026-03-01T00:00:00.000Z", clicks: 3 }, { start: "2026-03-02T00:00:00.000Z", clicks: 0 }] })],
  ]);
  const { rl, totals } = await runAll("dub", { apiKey: "dub_test" });
  assert.equal(totals.clicks, 3);
  const [row] = await rl.store.links("default", 0, Date.now() + 1);
  assert.equal(row!.clicks, 3);
  assert.equal(row!.visitors, 0, "daily counts add clicks, not made-up visitors");
});

test("Bitly: every group, custom back-halves, daily counts", async () => {
  serve([
    [/\/v4\/groups$/, () => ({ body: { groups: [{ guid: "G1" }, { guid: "G2" }] } })],
    [/\/groups\/G1\/bitlinks/, () => ({ body: { links: [
      { id: "bit.ly/3abc", link: "https://bit.ly/3abc", long_url: "https://a.com/1", title: "One", created_at: "2026-01-01T00:00:00+0000", custom_bitlinks: ["https://t.brand.com/one"] },
      { id: "bit.ly/gone", link: "https://bit.ly/gone", long_url: "https://a.com/x", title: "Gone", created_at: "2026-01-01T00:00:00+0000", is_deleted: true },
    ], pagination: { search_after: "" } } })],
    [/\/groups\/G2\/bitlinks/, () => ({ body: { links: [{ id: "bit.ly/4def", link: "https://bit.ly/4def", long_url: "https://a.com/2", title: null, created_at: "2026-02-01T00:00:00+0000" }], pagination: {} } })],
    [/\/bitlinks\/bit\.ly%2F3abc\/clicks/, () => ({ body: { link_clicks: [{ clicks: 5, date: "2026-03-01T00:00:00+0000" }, { clicks: 2, date: "2026-03-02T00:00:00+0000" }] } })],
    [/\/bitlinks\/bit\.ly%2F4def\/clicks/, () => ({ status: 402, body: { message: "UPGRADE_REQUIRED" } })],
  ]);
  const { rl, totals } = await runAll("bitly", { token: "bitly_test" });
  assert.equal(totals.links, 2, "the deleted link is skipped");
  assert.equal(totals.clicks, 7);
  const links = await rl.store.links("default", 0, Date.now() + 1);
  assert.deepEqual(links.map((l) => [l.domain, l.slug]).sort(), [["", "4def"], ["t.brand.com", "one"]]);
});

test("Short.io: every domain, paged, with daily counts in either shape", async () => {
  serve([
    [/api\.short\.io\/api\/domains/, () => ({ body: [{ id: 7, hostname: "s.brand.com" }] })],
    [/api\/links\?.*pageToken=P2/, () => ({ body: { links: [{ idString: "lnk2", id: 2, path: "two", originalURL: "https://a.com/2", createdAt: "2026-02-01T00:00:00Z" }], nextPageToken: null } })],
    [/api\/links\?domain_id=7/, () => ({ body: { links: [{ idString: "lnk1", id: 1, path: "one", originalURL: "https://a.com/1", title: "One", createdAt: "2026-01-01T00:00:00Z" }], nextPageToken: "P2" } })],
    [/statistics\/link\/lnk1\/by_interval/, () => ({ body: { clickStatistics: [{ x: "2026-03-01T00:00:00Z", y: 4 }] } })],
    [/statistics\/link\/lnk2\/by_interval/, () => ({ body: { clickStatistics: { datasets: [{ data: [{ x: Date.UTC(2026, 2, 2), y: 1 }] }] } } })],
  ]);
  const { totals } = await runAll("shortio", { apiKey: "sk_test" });
  assert.equal(totals.links, 2);
  assert.equal(totals.clicks, 5);
});

test("Rebrandly: links only, paged by the last id", async () => {
  const page = (from: number, n: number) =>
    Array.from({ length: n }, (_, i) => ({ id: `r${from + i}`, slashtag: `s${from + i}`, destination: `https://a.com/${from + i}`, domain: { fullName: "rebrand.ly" }, createdAt: "2026-01-01T00:00:00Z" }));
  serve([
    [/\/links\?.*last=r24/, () => ({ body: page(25, 3) })],
    [/rebrandly\.com\/v1\/links\?/, () => ({ body: page(0, 25) })],
  ]);
  const { rl, totals } = await runAll("rebrandly", { apiKey: "rb_test" });
  assert.equal(totals.links, 28);
  assert.equal(totals.clicks, 0);
  assert.equal((await rl.store.links("default", 0, Date.now() + 1))[0]!.domain, "", "rebrand.ly stays behind");
});

test("Umami: signs in with a username and password, and re-runs skip what is there", async () => {
  const calls = serve([
    [/\/api\/auth\/login/, (_u, init) => ({ body: JSON.parse(String(init.body)).password === "pw" ? { token: "tok" } : {} })],
    [/\/api\/links\?/, () => ({ body: { data: [{ id: "u-1", name: "Golden", url: "https://a.com", slug: "golden", createdAt: "2026-01-01T00:00:00Z", deletedAt: null, customDomain: { domain: "t.brand.com" } }], count: 1 } })],
    [/\/websites\/u-1\/events/, () => ({ body: { data: [{ sessionId: "s1", createdAt: "2026-03-01T00:00:00Z", urlPath: "/golden", urlQuery: "utm_source=newsletter", referrerDomain: "", referrerPath: "", country: "GB", city: "London", device: "mobile", os: "iOS", browser: "ios" }], count: 1 } })],
    [/\/websites\/u-1\/sessions/, () => ({ body: { data: [{ id: "s1", screen: "390x844", language: "en-GB", region: "ENG" }], count: 1 } })],
  ]);
  const rl = runlight({ store: sqlite({ path: ":memory:" }) });
  const creds = { url: "https://stats.example.com/", username: "jon", password: "pw" };
  const first = await importStep(rl, "default", "umami", creds, null, 0);
  assert.equal(first.links, 1);
  assert.equal(first.clicks, 1);
  assert.ok(calls[0]!.startsWith("POST stats.example.com/api/auth/login"));
  const [s] = await rl.store.db.all<{ region: string; source: string; browser: string }>("SELECT region, source, browser FROM rl_sessions");
  assert.deepEqual(s, { region: "GB-ENG", source: "Newsletter", browser: "Safari" });
  const again = await importStep(rl, "default", "umami", creds, null, 0);
  assert.equal(again.skipped, 1);
  await assert.rejects(importStep(rl, "default", "umami", { url: "nope" }, null, 0), /Umami address/);
  await assert.rejects(importStep(rl, "default", "nowhere", {}, null, 0), /cannot import/);
});

test("Umami: a link already here with the same slug and destination is skipped before its history is fetched", async () => {
  const calls = serve([
    [/\/api\/links\?/, () => ({ body: { data: [{ id: "u-9", name: "Golden", url: "https://a.com/", slug: "golden", createdAt: "2026-01-01T00:00:00Z", deletedAt: null }], count: 1 } })],
    [/\/websites\/u-9\//, () => ({ body: { data: [], count: 0 } })],
  ]);
  const rl = runlight({ store: sqlite({ path: ":memory:" }) });
  await rl.init();
  // Brought in earlier some other way, such as a CSV, so it has no Umami id.
  await rl.links.create("default", { url: "https://a.com", slug: "golden", name: "Golden" });
  const step = await importStep(rl, "default", "umami", { url: "https://stats.example.com/", apiKey: "k" }, null, 0);
  assert.equal(step.skipped, 1);
  assert.equal(step.links, 0);
  assert.ok(!calls.some((c) => c.includes("/websites/u-9/")), "no history was fetched for it");
});
