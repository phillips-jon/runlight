import assert from "node:assert/strict";
import { after, test } from "node:test";
import { JOURNEY_VISITS } from "../src/store.js";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

for (const kind of STORES) {
  test(`${kind}: goals, funnels, and event properties count visits by when they started, with or without a filter`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    // Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the 6th.
    t.advance(-12 * HOUR - 10 * MIN);
    for (const ip of ["203.0.113.1", "203.0.113.2"]) await t.send({ k: "pageview", u: "https://example.com/signup", i: `p${ip.split(".").pop()}` }, { ip });
    t.advance(20 * MIN);
    for (const ip of ["203.0.113.1", "203.0.113.2"]) await t.send({ k: "event", u: "https://example.com/signup", n: "Signup", i: `p${ip.split(".").pop()}`, p: { plan: "pro" } }, { ip });
    t.advance(HOUR);
    await t.send({ k: "pageview", u: "https://example.com/", i: "q" }, { ip: "203.0.113.3" });
    t.advance(11 * HOUR);
    await t.rl.store.saveGoal({ id: "a".repeat(24), site: "default", name: "Signup", kind: "event", match: "Signup", clickBy: "", valueMode: "none", value: 0, valueProp: "", currency: "USD", createdAt: 0 });
    await t.rl.store.saveFunnel({ id: "b".repeat(24), site: "default", name: "Signup", steps: [{ kind: "page", match: "/signup" }, { kind: "event", match: "Signup" }], createdAt: 0 });

    for (const filter of ["", "&filter=country:not:ZZ", "&filter=page:contains:/"]) {
      const day = async (date: string) => {
        const range = `from=${date}&to=${date}${filter}`;
        const goal = (await t.get(`/api/goals?${range}`)).goals[0];
        const funnel = (await t.get(`/api/funnels?${range}`)).funnels[0].steps.map((s: { visits: number }) => s.visits);
        const props = (await t.get(`/api/event-props?${range}&event=Signup`)).keys ?? [];
        const events = (await t.get(`/api/breakdown?${range}&dimension=event`)).rows;
        return { conversions: goal.conversions, rate: goal.rate, funnel, props: props.length, events: events.map((r: { value: string; events: number }) => `${r.value}:${r.events}`) };
      };
      assert.deepEqual(await day("2026-10-05"), { conversions: 2, rate: 1, funnel: [2, 2], props: 1, events: ["Signup:2"] }, `the visits that started on the 5th${filter}`);
      assert.deepEqual(await day("2026-10-06"), { conversions: 0, rate: 0, funnel: [0, 0], props: 0, events: [] }, `nothing that started on the 6th converted${filter}`);
    }
  });

  test(`${kind}: "contains" finds capitals beyond ASCII, and two page filters count both pages`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    await t.send({ k: "pageview", u: "https://example.com/a?utm_campaign=Über", i: "a" });
    t.advance(MIN);
    await t.send({ k: "pageview", u: "https://example.com/b", i: "b" });
    t.advance(HOUR);
    for (const value of ["über", "Über", "ÜBER", "ber"]) {
      const stats = (await t.get(`/api/stats?period=today&compare=off&filter=utm_campaign:contains:${encodeURIComponent(value)}`)).stats;
      assert.equal(stats.visits, 1, `contains ${value}`);
    }
    const both = (await t.get("/api/stats?period=today&compare=off&filter=page:is:/a&filter=page:is:/b")).stats;
    assert.deepEqual([both.visits, both.pageviews], [1, 2]);
  });

  test(`${kind}: a page goal, funnel, or filter written in plain letters matches the encoded path`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    await t.send({ k: "pageview", u: "https://example.com/café", i: "a" });
    t.advance(HOUR);
    const made = await t.routes.POST(
      new Request("https://example.com/runlight/api/goals", { method: "POST", headers: { authorization: "Bearer secret", "content-type": "application/json" }, body: JSON.stringify({ name: "Café", kind: "page", match: "/café" }) }),
    );
    assert.equal(made.status, 201);
    assert.equal((await t.get("/api/goals?period=today")).goals[0].conversions, 1);
    assert.equal((await t.get(`/api/stats?period=today&compare=off&filter=${encodeURIComponent("page:is:/café")}`)).stats.visits, 1);
  });

  test(`${kind}: a late event counts in its visit without reopening it, and one days later starts its own`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-6 * HOUR);
    await t.send({ k: "pageview", u: "https://example.com/", i: "p1" });
    t.advance(2 * HOUR);
    await t.send({ k: "event", u: "https://example.com/", n: "Late", i: "p1" });
    t.advance(5 * MIN);
    await t.send({ k: "pageview", u: "https://example.com/next", i: "p2" });
    t.advance(4 * HOUR);
    const stats = (await t.get("/api/stats?period=today&compare=off")).stats;
    assert.equal(stats.visits, 2, "two hours idle ends a visit, whatever arrives late");
    const events = (await t.get("/api/breakdown?period=today&dimension=event")).rows;
    assert.deepEqual(events.map((r: { value: string; events: number }) => [r.value, r.events]), [["Late", 1]]);

    // A ping three days on is past where reports look, so it is let go on every path.
    await t.send({ k: "pageview", u: "https://example.com/old", i: "o1" });
    t.advance(3 * DAY);
    await t.send({ k: "engagement", u: "https://example.com/old", i: "o1", e: 30_000 });
    const raw = (await t.get(`/api/breakdown?period=7d&dimension=page`)).rows.find((r: { value: string }) => r.value === "/old");
    assert.equal(raw.timeOnPage, 0);
  });

  test(`${kind}: time on page is over every pageview, counting quick ones as none`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    for (let i = 0; i < 4; i++) await t.send({ k: "pageview", u: "https://example.com/a", i: `v${i}` }, { ip: `203.0.113.${i + 1}` });
    await t.send({ k: "engagement", u: "https://example.com/a", i: "v0", e: 60_000, d: 50 }, { ip: "203.0.113.1" });
    t.advance(HOUR);
    const row = (await t.get("/api/breakdown?period=today&dimension=page")).rows[0];
    assert.deepEqual([row.timeOnPage, row.scrollDepth], [15_000, 50]);
  });
}

test("journeys applies a filter before its cap on visits, and says when the cap was reached", async () => {
  const t = setup("sqlite", { site: { hostnames: ["example.com"], timezone: "UTC" } });
  await t.rl.init();
  const start = Date.UTC(2026, 9, 6, 0, 0);
  // Ten visits from Britain early in the day, then more from the US than journeys reads.
  await t.rl.store.transaction(async (store) => {
    for (let i = 0; i < 10 + JOURNEY_VISITS; i++) {
      const country = i < 10 ? "GB" : "US";
      const ts = start + i;
      await store.db.run(
        `INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)`,
        [`s${i}`, `v${i}`, ts, ts, country],
      );
      await store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')`, [ts, `v${i}`, `s${i}`, `p${i}`]);
    }
  });
  const britain = await t.get("/api/journeys?period=today&filter=country:is:GB");
  assert.equal(britain.visits, 10, "every British visit, though they are older than the newest visits read");
  assert.equal(britain.sampled, undefined);
  const all = await t.get("/api/journeys?period=today");
  assert.equal(all.visits, JOURNEY_VISITS);
  assert.equal(all.sampled, JOURNEY_VISITS);
});

for (const kind of STORES) {
  test(`${kind}: a page goal or funnel step for a hash route counts that route only`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    for (let i = 0; i < 5; i++) {
      const ip = `203.0.113.${i + 1}`;
      await t.send({ k: "pageview", u: "https://example.com/", i: `h${i}` }, { ip });
      if (i < 2) {
        await t.send({ k: "pageview", u: "https://example.com/#/cart", i: `c${i}` }, { ip });
        await t.send({ k: "pageview", u: "https://example.com/#/thanks", i: `t${i}` }, { ip });
      }
    }
    t.advance(HOUR);
    const post = (path: string, body: unknown) =>
      t.routes.POST(new Request(`https://example.com/runlight${path}`, { method: "POST", headers: { authorization: "Bearer secret", "content-type": "application/json" }, body: JSON.stringify(body) }));
    assert.equal((await post("/api/goals", { name: "Thanks", kind: "page", match: "/#/thanks" })).status, 201);
    assert.equal((await post("/api/funnels", { name: "Checkout", steps: [{ kind: "page", match: "/#/cart" }, { kind: "page", match: "https://example.com/#/thanks" }] })).status, 201);
    const goal = (await t.get("/api/goals?period=today")).goals[0];
    assert.deepEqual([goal.match, goal.conversions, goal.visitors], ["/#/thanks", 2, 2]);
    const funnel = (await t.get("/api/funnels?period=today")).funnels[0];
    assert.deepEqual(funnel.steps.map((s: { match: string; visits: number }) => [s.match, s.visits]), [["/#/cart", 2], ["/#/thanks", 2]]);
  });

  test(`${kind}: page and hostname filters together count pageviews matching both`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com", "docs.example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    await t.send({ k: "pageview", u: "https://example.com/pricing", i: "a" });
    await t.send({ k: "pageview", u: "https://docs.example.com/start", i: "b" });
    await t.send({ k: "pageview", u: "https://docs.example.com/pricing", i: "c" });
    t.advance(HOUR);
    const filters = "filter=page:is:/pricing&filter=hostname:is:docs.example.com";
    assert.equal((await t.get(`/api/stats?period=today&compare=off&${filters}`)).stats.pageviews, 1);
    const pages = (await t.get(`/api/breakdown?period=today&dimension=page&${filters}`)).rows;
    assert.deepEqual(pages.map((r: { value: string; pageviews: number }) => [r.value, r.pageviews]), [["/pricing", 1]]);
  });

  test(`${kind}: contains ignores case in any mix, in paths too, and filters take paths as the browser writes them`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-HOUR);
    await t.send({ k: "pageview", u: "https://example.com/Über-uns?utm_campaign=ÉcoleÉté", i: "a" }, { ip: "203.0.113.1" });
    await t.send({ k: "pageview", u: "https://example.com/a^b", i: "b" }, { ip: "203.0.113.2" });
    await t.send({ k: "pageview", u: "https://example.com/#/x{y}", i: "c" }, { ip: "203.0.113.3" });
    t.advance(HOUR);
    const visits = async (filter: string) => (await t.get(`/api/stats?period=today&compare=off&filter=${encodeURIComponent(filter)}`)).stats.visits;
    for (const value of ["écoleété", "ÉCOLEÉTÉ", "eÉté"]) assert.equal(await visits(`utm_campaign:contains:${value}`), 1, value);
    for (const value of ["über", "ÜBER", "Über-Uns"]) assert.equal(await visits(`page:contains:${value}`), 1, value);
    assert.equal(await visits("page:is:/a^b"), 1);
    assert.equal(await visits("page:is:/#/x{y}"), 1);
  });

  test(`${kind}: time on page leaves out imported views, which can report no time`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    await t.rl.init();
    // Nine pageviews written as the Umami import writes them: no pageview id, never any engaged time.
    const day = Date.UTC(2026, 9, 5, 10);
    for (let i = 0; i < 9; i++) {
      await t.rl.store.db.run(`INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)`, [`i${i}`, `v${i}`, day + i, day + i]);
      await t.rl.store.db.run(`INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')`, [day + i, `v${i}`, `i${i}`]);
    }
    t.advance(-HOUR);
    await t.send({ k: "pageview", u: "https://example.com/pricing", i: "live" });
    await t.send({ k: "engagement", u: "https://example.com/pricing", i: "live", e: 60_000 });
    t.advance(HOUR);
    const row = async () => (await t.get("/api/breakdown?period=7d&dimension=page")).rows.find((r: { value: string }) => r.value === "/pricing");
    assert.deepEqual([(await row()).pageviews, (await row()).timeOnPage], [10, 60_000]);
    t.advance(DAY);
    while ((await t.rl.buildRollups()) > 0);
    assert.equal((await row()).timeOnPage, 60_000, "the same once the days are built");
  });

  test(`${kind}: a day built by another process while it is being cleared is never left marked built without its numbers`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-3 * DAY);
    for (let i = 0; i < 4; i++) await t.send({ k: "pageview", u: "https://example.com/", i: `p${i}` }, { ip: `203.0.113.${i + 1}` });
    t.advance(3 * DAY);
    while ((await t.rl.buildRollups()) > 0);
    const before = (await t.get("/api/stats?period=7d&compare=off")).stats;
    // Another process builds the day right after its mark is deleted.
    const db = t.rl.store.db;
    const run = db.run.bind(db);
    let raced = false;
    db.run = (async (sql: string, params?: unknown[]) => {
      await run(sql, params);
      if (!raced && sql.startsWith("DELETE FROM rl_rollup_days WHERE site = ? AND start_at")) {
        raced = true;
        db.run = run;
        while ((await t.rl.buildRollups()) > 0);
      }
    }) as typeof db.run;
    await t.rl.store.clearRollups("default", { from: t.now - 4 * DAY, to: t.now });
    db.run = run;
    assert.ok(raced);
    assert.deepEqual((await t.get("/api/stats?period=7d&compare=off")).stats, before);
  });
}
