import assert from "node:assert/strict";
import { after, test } from "node:test";
import { chat } from "../src/assistant.js";
import { isPrivateAddress, PrivateAddressError, publicFetch } from "../src/net.js";
import { oneConnection } from "../src/store.js";
import { postgres } from "../src/stores/postgres.js";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

const DAY = 86_400_000;

test("private, loopback, link-local, and metadata addresses are never fetched, at any redirect", async () => {
  for (const ip of ["127.0.0.1", "10.0.0.1", "172.20.1.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "[::1]", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "::ffff:7f00:1"]) {
    assert.equal(isPrivateAddress(ip), true, ip);
  }
  for (const ip of ["93.184.215.14", "8.8.8.8", "2606:4700::1111", "172.32.0.1"]) assert.equal(isPrivateAddress(ip), false, ip);
  const real = globalThis.fetch;
  const asked: string[] = [];
  globalThis.fetch = (async (input: string | URL | Request) => {
    asked.push(String(input));
    return new Response(null, { status: 302, headers: { location: "https://169.254.169.254/latest/meta-data/" } });
  }) as typeof fetch;
  try {
    await assert.rejects(publicFetch("http://93.184.215.14/"), PrivateAddressError, "http is refused");
    await assert.rejects(publicFetch("https://127.0.0.1/"), PrivateAddressError);
    await assert.rejects(publicFetch("https://localhost/"), PrivateAddressError);
    await assert.rejects(publicFetch("https://93.184.215.14/", { redirects: 3 }), PrivateAddressError, "a redirect into a private address");
    assert.deepEqual(asked, ["https://93.184.215.14/"], "the private hop is never asked");
  } finally {
    globalThis.fetch = real;
  }
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
