import assert from "node:assert/strict";
import { after, test } from "node:test";
import { chat } from "../src/assistant.js";
import { PrivateAddressError, publicAddress, publicFetch } from "../src/safefetch.js";
import { oneConnection } from "../src/store.js";
import { postgres } from "../src/stores/postgres.js";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

const DAY = 86_400_000;

test("private, loopback, link-local, and metadata addresses are never fetched, at any redirect", async () => {
  for (const ip of ["127.0.0.1", "10.0.0.1", "172.20.1.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "[::1]", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "::ffff:7f00:1"]) {
    assert.equal(publicAddress(ip), false, ip);
  }
  for (const ip of ["93.184.215.14", "8.8.8.8", "2606:4700::1111", "172.32.0.1"]) assert.equal(publicAddress(ip), true, ip);
  // A runtime's own fetch, as on Workers: every hop is still checked before it is asked.
  const asked: string[] = [];
  const fetch = (async (input: string | URL | Request) => {
    asked.push(String(input));
    return new Response(null, { status: 302, headers: { location: "https://169.254.169.254/latest/meta-data/" } });
  }) as typeof globalThis.fetch;
  await assert.rejects(publicFetch("http://93.184.215.14/", { timeoutMs: 2000, fetch }), PrivateAddressError, "http is refused");
  await assert.rejects(publicFetch("https://127.0.0.1/", { timeoutMs: 2000, fetch }), PrivateAddressError);
  await assert.rejects(publicFetch("https://localhost/", { timeoutMs: 2000, fetch }), PrivateAddressError);
  await assert.rejects(publicFetch("https://93.184.215.14/", { timeoutMs: 2000, redirects: 3, fetch }), PrivateAddressError, "a redirect into a private address");
  assert.deepEqual(asked, ["https://93.184.215.14/"], "the private hop is never asked");
});

test("a question ends when the person leaves, before the model or any tool is asked", async () => {
  const stop = new AbortController();
  stop.abort();
  let asked = 0;
  await assert.rejects(
    chat(
      { provider: "anthropic", model: "m", baseUrl: "https://93.184.215.14/v1", key: "k" },
      [{ role: "user", content: "How many visitors?" }],
      { site: { id: "default", name: "Site", timezone: "UTC" }, today: "2026-10-06", view: "today", language: "en" },
      async () => {
        asked++;
        return new Response("{}");
      },
      stop.signal,
    ),
    /cancelled/,
  );
  assert.equal(asked, 0);
});

test("a Postgres pool of one connection is refused, since settings changes need two", () => {
  assert.throws(() => postgres({ url: "postgres://127.0.0.1:1/none", max: 1 }), /at least 2 connections/);
});

test("statements on one shared connection let other work run between them", async () => {
  const order: string[] = [];
  const db = oneConnection({
    dialect: "sqlite",
    async all() {
      order.push("statement");
      return [];
    },
    async run() {},
  });
  const timer = new Promise<void>((resolve) => setImmediate(() => (order.push("other work"), resolve())));
  await Promise.all([db.all("SELECT 1"), db.all("SELECT 2"), timer]);
  assert.deepEqual(order, ["other work", "statement", "statement"]);
});

for (const kind of STORES) {
  test(`${kind}: a check still running is shared, and planner statistics are gathered once a day`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    await t.rl.init();
    let gathered = 0;
    const optimize = t.rl.store.optimize.bind(t.rl.store);
    t.rl.store.optimize = async () => {
      gathered++;
      return optimize();
    };
    const [a, b] = [t.rl.check(), t.rl.check()];
    assert.equal(a, b, "one run, shared");
    await a;
    await t.rl.check();
    assert.equal(gathered, 1, "not again the same day");
    t.advance(DAY);
    await t.rl.check();
    assert.equal(gathered, 2);
    if (kind === "sqlite") assert.ok((await t.rl.store.db.all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'")).length, "statistics written");
  });

  test(`${kind}: events left behind by an older version, whose visit retention removed, are swept once`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    await t.rl.init();
    const old = t.now - 400 * DAY;
    await t.rl.store.db.run(`INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)`, [old, old]);
    await t.rl.store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', 'v1', 's1', 'p1', '/', 'example.com')`, [old]);
    // An event that joined the visit long after it started, as older versions allowed.
    await t.rl.store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, name, path, hostname) VALUES ('default', ?, 'event', 'v1', 's1', 'Late', '/', 'example.com')`, [t.now - 30 * DAY]);
    await t.rl.setRetention("default", 6);
    await t.rl.idle();
    await t.rl.check();
    assert.deepEqual(await t.rl.store.db.all(`SELECT name FROM rl_events WHERE site = 'default'`), []);
    assert.equal(await t.rl.store.setting("orphans-swept:default"), "1");
  });
}

test("a tracker hit that finds the database busy is tried again, at the time it arrived", async () => {
  const t = setup("sqlite", { site: { hostnames: ["example.com"], timezone: "UTC" } });
  await t.rl.init();
  const db = t.rl.store.db;
  const all = db.all.bind(db);
  let refused = 0;
  db.all = (async (sql: string, params?: unknown[]) => {
    if (refused < 2 && sql.includes("FROM rl_sessions WHERE site = ? AND visitor IN")) {
      refused++;
      throw new Error("timeout exceeded when trying to connect");
    }
    return all(sql, params);
  }) as typeof db.all;
  await t.send({ k: "pageview", u: "https://example.com/", i: "busy" });
  db.all = all;
  assert.equal(refused, 2);
  assert.equal((await t.get("/api/stats?period=today&compare=off")).stats.pageviews, 1);
});

test("on Cloudflare D1 a check sends a modest number of statements, and one stray old row costs no more", async () => {
  const t = setup("d1", { site: { hostnames: ["example.com"], timezone: "UTC" } });
  await t.rl.init();
  t.advance(-20 * DAY);
  for (let d = 0; d < 20; d++) {
    for (let p = 0; p < 30; p++) await t.send({ k: "pageview", u: `https://example.com/p${p}`, i: `d${d}p${p}` }, { ip: `203.0.113.${p + 1}` });
    await t.send({ k: "engagement", u: "https://example.com/p1", i: `d${d}p1`, e: 5000 }, { ip: "203.0.113.2" });
    t.advance(DAY);
  }
  // A row from 1970, as a bad import might leave.
  await t.rl.store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, path, hostname) VALUES ('default', 1000, 'pageview', 'old', 'old', '/', 'example.com')`);
  const db = t.rl.store.db;
  const run = db.run.bind(db);
  const all = db.all.bind(db);
  let statements = 0;
  db.run = ((sql: string, params?: unknown[]) => (statements++, run(sql, params))) as typeof db.run;
  db.all = ((sql: string, params?: unknown[]) => (statements++, all(sql, params))) as typeof db.all;
  await t.rl.check();
  assert.ok(statements < 120, `one check sent ${statements} statements`);
  statements = 0;
  await t.rl.store.deleteSite("default");
  assert.ok(statements < 200, `deleting the site sent ${statements} statements`);
});

test("a link domain's check says where the domain should point, for its setup steps", async () => {
  const t = setup("sqlite", { site: { hostnames: ["example.com"] } });
  await t.rl.init();
  await t.rl.store.addLinkDomain("go.example.net", "default", t.now);
  const real = globalThis.fetch;
  globalThis.fetch = (async () => new Response("no", { status: 404 })) as typeof fetch;
  try {
    const check = await t.get("/api/link-domains/go.example.net/check");
    assert.equal(check.target.host, "example.com", "this dashboard's own name, for a CNAME");
    assert.ok(Array.isArray(check.target.addresses));
  } finally {
    globalThis.fetch = real;
  }
});

test("a proxy's x-forwarded-host is only believed when proxy headers are trusted", async () => {
  const CLAUDE = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)";
  const ask = (rl: ReturnType<typeof setup>["rl"]) =>
    rl.observe(new Request("https://elsewhere.example/blog", { headers: { "user-agent": CLAUDE, host: "elsewhere.example", "x-forwarded-host": "example.com" } }));
  const site = { hostnames: ["example.com"] };
  assert.equal(await ask(setup("sqlite", { site, trustProxy: false }).rl), false, "an untrusted header cannot claim the site");
  assert.equal(await ask(setup("sqlite", { site }).rl), true, "behind a trusted proxy, its header names the host");
});

test("with trustProxy left at its default, a public address with no proxy header is warned about once", () => {
  const warn = console.warn;
  const said: string[] = [];
  console.warn = (message: string) => void said.push(message);
  try {
    const bare = new Request("https://example.com/e");
    const forwarded = new Request("https://example.com/e", { headers: { "x-forwarded-for": "8.8.4.4" } });
    const quiet = setup("sqlite", { site: { hostnames: ["example.com"] }, trustProxy: true }).rl;
    assert.equal(quiet.clientIp(bare, { ip: "8.8.8.8" }), "8.8.8.8");
    assert.deepEqual(said, [], "trustProxy set on purpose is never second-guessed");

    const rl = setup("sqlite", { site: { hostnames: ["example.com"] } }).rl;
    rl.clientIp(forwarded, { ip: "10.0.0.2" });
    rl.clientIp(bare, { ip: "127.0.0.1" });
    rl.clientIp(bare, { ip: "192.168.1.5" });
    assert.deepEqual(said, [], "a proxy's header, or a private or loopback address, says nothing");
    assert.equal(rl.clientIp(bare, { ip: "8.8.8.8" }), "8.8.8.8");
    rl.clientIp(bare, { ip: "1.1.1.1" });
    assert.equal(said.length, 1, "said once");
    assert.match(said[0]!, /trustProxy: false/);
  } finally {
    console.warn = warn;
  }
});
