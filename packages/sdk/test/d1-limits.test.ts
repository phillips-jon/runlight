import assert from "node:assert/strict";
import { test } from "node:test";
import { setup } from "./helpers.js";

const DAY = 86_400_000;

test("no statement binds more than 100 parameters, as Cloudflare D1 requires", async () => {
  const t = setup("sqlite", { site: { hostnames: ["example.com"], timezone: "UTC" } });
  // A visit a day for a year, so a year of days can be built.
  t.advance(-365 * DAY);
  for (let d = 0; d < 365; d += 3) {
    await t.send({ k: "pageview", u: `https://example.com/p${d % 40}`, i: `y${d}` }, { ip: `203.0.113.${d % 200}` });
    await t.send({ k: "event", u: `https://example.com/p${d % 40}`, i: `y${d}`, n: `Goal${d % 30}`, p: { amount: d } }, { ip: `203.0.113.${d % 200}` });
    t.advance(3 * DAY);
  }
  t.advance(365 * DAY - Math.floor(365 / 3 + 1) * 3 * DAY);
  while ((await t.rl.buildRollups()) > 0);
  for (let g = 0; g < 30; g++) {
    await t.rl.store.saveGoal({ id: `g${String(g).padStart(22, "0")}`, site: "default", name: `Goal ${g}`, kind: "event", match: `Goal${g}`, clickBy: "", valueMode: g % 2 ? "prop" : "fixed", value: 5, valueProp: "amount", currency: "USD", createdAt: 0 } as any);
  }

  // Every statement from here on is checked.
  let most = 0;
  const db = t.rl.store.db;
  const check = (params?: unknown[]) => {
    most = Math.max(most, params?.length ?? 0);
    if ((params?.length ?? 0) > 100) throw new Error(`a statement bound ${params!.length} parameters`);
  };
  const all = db.all.bind(db);
  const run = db.run.bind(db);
  db.all = ((sql: string, params?: unknown[]) => (check(params), all(sql, params))) as typeof db.all;
  db.run = ((sql: string, params?: unknown[]) => (check(params), run(sql, params))) as typeof db.run;

  for (const range of ["period=12mo", "period=all", "period=90d", "period=7d&interval=hour"]) {
    await t.get(`/api/stats?${range}`);
    await t.get(`/api/series?${range}`);
    await t.get(`/api/rhythm?${range}`);
    await t.get(`/api/breakdown?${range}&dimension=page&limit=1000`);
    await t.get(`/api/breakdown?${range}&dimension=source&limit=1000&filter=page:contains:/p`);
    await t.get(`/api/breakdown?${range}&dimension=page&limit=1000&filter=country:not:XX`);
  }
  const goals = await t.get("/api/goals?period=12mo");
  assert.equal(goals.goals.length, 30, "the goals report answers for all thirty");
  assert.ok(most <= 100, `largest statement: ${most} parameters`);
});
