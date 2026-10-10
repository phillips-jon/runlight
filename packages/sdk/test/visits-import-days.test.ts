import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { importUmamiVisits } from "../src/importers/visits.js";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";
import { publicFetchThroughGlobal } from "../src/safefetch.js";

// Fetches go to the stand-in fetch below; an address written as an IP is still refused.
publicFetchThroughGlobal(true);

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

type Row = { sessionId: string; createdAt: string; hostname: string; urlPath: string; eventType: number; eventName?: string };

/** A stand-in Umami that answers with these events, and an install that imports them. */
function umami(events: Row[], now: string) {
  globalThis.fetch = (async (input: string | URL | Request) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const reply = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
    if (url.pathname === "/api/websites/w1") return reply({ id: "w1", createdAt: "2026-03-01T00:00:00.000Z" });
    const from = Number(url.searchParams.get("startAt"));
    const to = Number(url.searchParams.get("endAt"));
    if (url.pathname === "/api/websites/w1/events") {
      const rows = events.filter((e) => Date.parse(e.createdAt) >= from && Date.parse(e.createdAt) <= to).reverse();
      return reply({ data: rows, count: rows.length });
    }
    if (url.pathname === "/api/websites/w1/sessions") return reply({ data: [], count: 0 });
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse(now) });
  const { GET } = rl.routes({ token: null });
  const get = async (path: string) => (await GET(new Request(`https://x.com/runlight${path}`))).json() as Promise<any>;
  return { rl, get, creds: { url: "https://umami.example.com", apiKey: "key" } };
}

const ev = (sessionId: string, iso: string, urlPath: string, eventName?: string): Row => ({
  sessionId,
  createdAt: new Date(iso).toISOString(),
  hostname: "blog.example.com",
  urlPath,
  eventType: eventName ? 2 : 1,
  ...(eventName ? { eventName } : {}),
});

test("an imported visit that runs past midnight keeps one visitor on all its rows", async () => {
  const { rl, get, creds } = umami(
    [ev("s1", "2026-03-01T23:50:00Z", "/a"), ev("s1", "2026-03-02T00:05:00Z", "/b"), ev("s1", "2026-03-02T00:06:00Z", "/b", "Signup"), ev("s1", "2026-03-02T10:00:00Z", "/b"), ev("s1", "2026-03-02T10:01:00Z", "/b", "Signup")],
    "2026-03-05T12:00:00Z",
  );
  let cursor: string | null = null;
  do cursor = (await importUmamiVisits(rl, "default", creds, "w1", cursor)).cursor;
  while (cursor);
  const differing = await rl.store.db.all(`SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor`);
  assert.deepEqual(differing, []);
  const read = async () => ({
    pages: (await get("/api/breakdown?from=2026-03-01&to=2026-03-02&dimension=page")).rows.map((r: any) => [r.value, r.visitors]),
    events: (await get("/api/breakdown?from=2026-03-01&to=2026-03-02&dimension=event")).rows.map((r: any) => [r.value, r.visitors]),
  });
  const raw = await read();
  while ((await rl.buildRollups()) > 0);
  assert.deepEqual(await read(), raw, "the same before and after the days are built");
  assert.deepEqual(raw.events, [["Signup", 2]]);
});

test("a visit that crosses into the next import step has its first day built again", async () => {
  const { rl, get, creds } = umami(
    [ev("s0", "2026-03-02T10:00:00Z", "/"), ev("s1", "2026-03-14T23:50:00Z", "/a"), ev("s1", "2026-03-15T00:10:00Z", "/b"), ev("s2", "2026-03-20T10:00:00Z", "/")],
    "2026-03-25T12:00:00Z",
  );
  let cursor: string | null = (await importUmamiVisits(rl, "default", creds, "w1", null)).cursor;
  // The scheduled check builds days between two steps.
  while ((await rl.buildRollups()) > 0);
  while (cursor) cursor = (await importUmamiVisits(rl, "default", creds, "w1", cursor)).cursor;
  while ((await rl.buildRollups()) > 0);
  const read = async () => ({
    stats: (await get("/api/stats?from=2026-03-14&to=2026-03-14&compare=off")).stats,
    pages: (await get("/api/breakdown?from=2026-03-14&to=2026-03-14&dimension=page")).rows.map((r: any) => [r.value, r.pageviews]),
  });
  const rolled = await read();
  await rl.store.clearRollups("default");
  assert.deepEqual(rolled, await read());
  assert.equal(rolled.stats.pageviews, 2);
});
