import assert from "node:assert/strict";
import { test } from "node:test";
import { csvFormat, rowTime } from "../src/importers/csvvisits.js";
import { importCsvVisits } from "../src/importers/visits.js";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const site = { hostnames: ["blog.example.com"], timezone: "UTC" };
const range = "from=2026-03-01&to=2026-03-03&compare=off";

function make(now = Date.parse("2026-03-04T00:00:00Z")) {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site, now: () => now });
  const { GET, POST } = rl.routes({ token: null });
  const get = async (path: string) => (await GET(new Request(`https://x.com/runlight${path}`))).json() as Promise<any>;
  return { rl, get, POST };
}

// Runlight's own columns: two pageviews and a signup in one visit, then a direct visit the next day.
const runlightRows = [
  { time: "2026-03-01T10:00:00Z", url: "https://blog.example.com/?utm_campaign=spring", referrer: "www.google.com", visitor: "a", country: "CA", region: "CA-ON", city: "Toronto", browser: "Safari", os: "iOS", device: "mobile", title: "Home" },
  { time: "2026-03-01T10:02:00Z", url: "https://blog.example.com/pricing", visitor: "a", country: "CA", browser: "Safari", os: "iOS", device: "mobile" },
  { time: "2026-03-01T10:03:00Z", url: "https://blog.example.com/pricing", event: "Signup", visitor: "a" },
  { time: "1772442000", path: "/", hostname: "blog.example.com", visitor: "b", country: "GB", browser: "Chrome", os: "macOS", device: "desktop" },
  // Not a time at all.
  { time: "yesterday", path: "/x", visitor: "c" },
];

test("CSV in Runlight's format: rows become visits with sources, places, devices, and events", async () => {
  const { rl, get } = make();
  const step = await importCsvVisits(rl, "default", runlightRows);
  assert.deepEqual(step, { pageviews: 3, events: 1, visits: 2, skipped: 1 });
  const stats = (await get(`/api/stats?${range}`)).stats;
  assert.equal(stats.pageviews, 3);
  assert.equal(stats.visits, 2);
  assert.equal(stats.visitors, 2);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=source`)).rows.map((r: any) => r.value), ["Google"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=utm_campaign`)).rows.map((r: any) => r.value), ["spring"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=event`)).rows.map((r: any) => r.value), ["Signup"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=device`)).rows.map((r: any) => r.value).sort(), ["desktop", "mobile"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=region`)).rows.map((r: any) => r.value), ["CA-ON"]);

  // The same file again replaces what it brought in, so nothing doubles.
  await importCsvVisits(rl, "default", runlightRows);
  assert.equal((await get(`/api/stats?${range}`)).stats.pageviews, 3);
  assert.equal((await get(`/api/stats?${range}`)).stats.visits, 2);
});

test("CSV in Runlight's format without a visitor column: every row is its own visit", async () => {
  const { rl, get } = make();
  const rows = [
    { time: "2026-03-01 10:00:00", path: "/a" },
    { time: "2026-03-01 10:01:00", path: "/b?ref=x" },
  ];
  assert.equal((await importCsvVisits(rl, "default", rows)).visits, 2);
  await importCsvVisits(rl, "default", rows);
  assert.equal((await get(`/api/stats?${range}`)).stats.visits, 2, "the same rows get the same ids the second time");
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=page`)).rows.map((r: any) => r.value).sort(), ["/a", "/b"]);
});

// Umami's data export: snake case columns, times without a zone, event types by number.
const umamiRows = [
  { website_id: "w1", session_id: "s1", created_at: "2026-03-01 10:00:00", hostname: "blog.example.com", url_path: "/", url_query: "", referrer_domain: "news.ycombinator.com", page_title: "Home", event_type: "1", country: "CA", subdivision1: "ON", city: "Toronto", browser: "ios", os: "iOS", device: "mobile", screen: "390x844", language: "en-CA" },
  { website_id: "w1", session_id: "s1", created_at: "2026-03-01 10:03:00", hostname: "blog.example.com", url_path: "/pricing", event_type: "2", event_name: "Signup" },
  { website_id: "w1", session_id: "s1", created_at: "2026-03-01 10:03:01", hostname: "blog.example.com", url_path: "/pricing", event_type: "5" },
  { website_id: "w1", session_id: "s2", created_at: "2026-03-02T09:00:00.000Z", hostname: "blog.example.com", url_path: "/blog", event_type: "1", country: "GB", browser: "chrome", os: "Mac OS", device: "desktop" },
];

test("CSV from Umami's export: pageviews and named events come across, other event types do not", async () => {
  const { rl, get } = make();
  assert.deepEqual(await importCsvVisits(rl, "default", umamiRows), { pageviews: 2, events: 1, visits: 2, skipped: 1 });
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=source`)).rows.map((r: any) => r.value), ["Hacker News"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=region`)).rows.map((r: any) => r.value), ["CA-ON"]);
  assert.deepEqual((await get(`/api/breakdown?${range}&dimension=browser`)).rows.map((r: any) => r.value).sort(), ["Chrome", "Safari"]);
});

test("CSV rows from after Runlight's own first visit are left to Runlight", async () => {
  const { rl, get, POST } = make(Date.parse("2026-03-01T23:00:00Z"));
  await POST(new Request("https://x.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.9" }, body: JSON.stringify({ k: "pageview", u: "https://blog.example.com/" }) }));
  const step = await importCsvVisits(rl, "default", runlightRows.slice(0, 4));
  assert.equal(step.pageviews, 2, "March 2nd is left to Runlight");
  assert.equal(step.skipped, 1);
  void get;
});

test("the CSV route refuses a file it cannot read and a batch that is too big", async () => {
  const { POST } = make();
  const send = (rows: unknown) => POST(new Request("https://x.com/runlight/api/import/csv/visits", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ rows }) }));
  const unknown = await send([{ date: "2026-03-01", visitors: "12" }]);
  assert.equal(unknown.status, 400);
  assert.equal(((await unknown.json()) as any).code, "import_csv_format");
  const big = await send(Array.from({ length: 2001 }, () => runlightRows[0]));
  assert.equal(((await big.json()) as any).code, "import_csv_batch");
  const ok = await send(runlightRows);
  assert.equal(ok.status, 200);
  assert.equal(((await ok.json()) as any).visits, 2);
});

test("CSV times and formats", () => {
  assert.equal(csvFormat(["created_at", "url_path", "session_id"]), "umami");
  assert.equal(csvFormat(["time", "url"]), "runlight");
  assert.equal(csvFormat(["date", "visitors"]), null);
  const iso = Date.parse("2026-03-01T10:00:00Z");
  assert.equal(rowTime({ time: "2026-03-01 10:00:00" }, "runlight"), iso, "no zone reads as UTC");
  assert.equal(rowTime({ time: "2026-03-01T12:00:00+02:00" }, "runlight"), iso);
  assert.equal(rowTime({ time: String(iso / 1000) }, "runlight"), iso, "Unix seconds");
  assert.equal(rowTime({ time: String(iso) }, "runlight"), iso, "Unix milliseconds");
  assert.equal(rowTime({ created_at: "2026-03-01 10:00:00" }, "umami"), iso);
  assert.ok(Number.isNaN(rowTime({ time: "" }, "runlight")));
});
