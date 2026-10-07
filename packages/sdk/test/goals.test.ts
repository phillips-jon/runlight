import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { STORES, cleanup, setup as setupFor, type StoreKind } from "./helpers.js";

after(cleanup);

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  const setup = () => {
    const t = setupFor(kind);
    const write = (method: string, path: string, body?: unknown, headers: Record<string, string> = { authorization: "Bearer secret" }) =>
      t.routes.handler(
        new Request(`https://example.com/runlight${path}`, {
          method,
          headers: { "content-type": "application/json", ...headers },
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
      );
    return { ...t, write };
  };

  test("goals count events, page patterns, and revenue, including visits from before the goal", async () => {
    const t = setup();
    // Three visitors, before any goal exists.
    await t.send({ k: "pageview", u: "https://example.com/pricing", i: "a1" }, { ip: "203.0.113.1" });
    await t.send({ k: "event", u: "https://example.com/pricing", i: "a1", n: "Purchase", p: { revenue: 49 } }, { ip: "203.0.113.1" });
    await t.send({ k: "pageview", u: "https://example.com/thanks", i: "a2" }, { ip: "203.0.113.1" });
    await t.send({ k: "pageview", u: "https://example.com/pricing", i: "b1" }, { ip: "203.0.113.2" });
    await t.send({ k: "event", u: "https://example.com/pricing", i: "b1", n: "Purchase", p: { revenue: "19.50" } }, { ip: "203.0.113.2" });
    await t.send({ k: "pageview", u: "https://example.com/thanks/pro", i: "b2" }, { ip: "203.0.113.2" });
    await t.send({ k: "pageview", u: "https://example.com/", i: "c1" }, { ip: "203.0.113.3" });
    await t.send({ k: "event", u: "https://example.com/", i: "c1", n: "Purchase", p: { revenue: "not a number" } }, { ip: "203.0.113.3" });

    const made = async (body: Record<string, unknown>) => {
      const r = await t.write("POST", "/api/goals", body);
      assert.equal(r.status, 201, await r.clone().text());
      return ((await r.json()) as { goal: { id: string } }).goal.id;
    };
    const purchase = await made({ name: "Purchase", kind: "event", match: "Purchase", valueMode: "prop", valueProp: "revenue", currency: "usd" });
    await made({ name: "Thank you page", kind: "page", match: "https://example.com/thanks*", valueMode: "fixed", value: 10 });
    await made({ name: "Buy button", kind: "click", clickBy: "selector", match: ".buy" });

    const report = await t.get("/api/goals?period=today&compare=off");
    assert.equal(report.visitors, 3);
    const byName = Object.fromEntries(report.goals.map((g: { name: string }) => [g.name, g]));
    assert.equal(byName.Purchase.conversions, 3);
    assert.equal(byName.Purchase.visitors, 3);
    assert.equal(byName.Purchase.revenue, 68.5, "numbers and numeric strings add up; anything else counts as nothing");
    assert.equal(byName.Purchase.currency, "USD");
    assert.equal(byName["Thank you page"].match, "/thanks*", "a pasted URL keeps only its path");
    assert.equal(byName["Thank you page"].conversions, 2);
    assert.equal(byName["Thank you page"].revenue, 20);
    assert.ok(Math.abs(byName["Thank you page"].rate - 2 / 3) < 1e-9);
    assert.equal(byName["Buy button"].conversions, 0);

    const detail = await t.get(`/api/goals/${purchase}?period=today&compare=off`);
    assert.deepEqual(
      detail.pages.map((p: { value: string; conversions: number }) => [p.value, p.conversions]),
      [["/pricing", 2], ["/", 1]],
    );
    assert.equal(detail.totals.revenue, 68.5);
    assert.equal(detail.series.reduce((a: number, p: { conversions: number }) => a + p.conversions, 0), 3);

    // The click goal ships inside the tracker.
    const script = await (await t.routes.GET(new Request("https://example.com/runlight/s.js"))).text();
    assert.match(script, /\[\["s",".buy","Buy button"\]\]/);
    assert.ok(!script.includes("__RUNLIGHT_RULES__"));
  });

  test("goal checks, and what a share can do with goals", async () => {
    const t = setup();
    assert.equal((await t.write("POST", "/api/goals", { name: "X", kind: "event", match: "X" }, {})).status, 401);
    assert.equal((await t.write("POST", "/api/goals", { name: "X", kind: "event", match: "X" })).status, 201);
    const dup = await t.write("POST", "/api/goals", { name: "x", kind: "event", match: "Y" });
    assert.equal(dup.status, 400);
    assert.match(((await dup.json()) as { error: string }).error, /already a goal/);
    assert.equal((await t.write("POST", "/api/goals", { name: "Y", kind: "event", match: "Y", currency: "dollars" })).status, 400);
    assert.equal((await t.write("POST", "/api/goals", { name: "Z", kind: "event", match: "Z", valueMode: "fixed", value: -1 })).status, 400);
    assert.equal((await t.write("POST", "/api/goals", { name: "W", kind: "event", match: "W", valueMode: "prop", valueProp: "a b" })).status, 400);
    assert.equal((await t.write("POST", "/api/goals", { name: "P", kind: "page", match: "/p", valueMode: "prop" })).status, 400, "a page visit sends no amount");

    const share = (await (await t.write("POST", "/api/shares", { name: "Client" })).json()) as { share: { id: string } };
    const as = { "x-runlight-share": share.share.id };
    const read = await t.routes.GET(new Request("https://example.com/runlight/api/goals?period=today", { headers: as }));
    assert.equal(read.status, 200, "a share sees conversions");
    assert.equal((await t.write("POST", "/api/goals", { name: "V", kind: "event", match: "V" }, as)).status, 401, "but cannot add goals");

    const [goal] = (await t.get("/api/goals?period=today")).goals as Array<{ id: string }>;
    assert.equal((await t.write("PATCH", `/api/goals/${goal!.id}`, { name: "Renamed", kind: "event", match: "X" })).status, 200);
    assert.equal((await t.get("/api/goals?period=today")).goals[0].name, "Renamed");
    assert.equal((await t.write("DELETE", `/api/goals/${goal!.id}`)).status, 200);
    assert.equal((await t.get("/api/goals?period=today")).goals.length, 0);
  });
}
