import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { STORES, cleanup, setup, type StoreKind } from "./helpers.js";

after(cleanup);

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  test("a funnel counts visits that took each step in order, within one visit", async () => {
    const t = setup(kind);
    const auth = { authorization: "Bearer secret", "content-type": "application/json" };
    const write = (method: string, path: string, body?: unknown) =>
      t.routes.handler(new Request(`https://example.com/runlight${path}`, { method, headers: auth, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
    const visit = async (ip: string, steps: Array<[string, string?]>) => {
      for (const [path, event] of steps) {
        await t.send(event ? { k: "event", u: `https://example.com${path}`, n: event } : { k: "pageview", u: `https://example.com${path}` }, { ip });
        t.advance(60_000);
      }
    };
    // All three steps in order.
    await visit("203.0.113.1", [["/pricing"], ["/signup", "Signup"], ["/welcome"]]);
    // Two steps, then gone.
    await visit("203.0.113.2", [["/pricing"], ["/signup", "Signup"]]);
    // The right pages in the wrong order count only the first step.
    await visit("203.0.113.3", [["/welcome"], ["/pricing"]]);
    // Never on the pricing page.
    await visit("203.0.113.4", [["/blog"], ["/welcome"]]);

    assert.equal((await write("POST", "/api/funnels", { name: "One step", steps: [{ kind: "page", match: "/pricing" }] })).status, 400);
    const made = await write("POST", "/api/funnels", {
      name: "Signup",
      steps: [
        { kind: "page", match: "https://example.com/pricing*" },
        { kind: "event", match: "Signup" },
        { kind: "page", match: "welcome" },
      ],
    });
    assert.equal(made.status, 201);
    const { funnel } = (await made.json()) as { funnel: { id: string; steps: Array<{ match: string }> } };
    assert.deepEqual(funnel.steps.map((s) => s.match), ["/pricing*", "Signup", "/welcome"], "a pasted URL keeps its path; a bare path gains its slash");

    const report = await t.get("/api/funnels?period=today&compare=off");
    assert.deepEqual(report.funnels[0].steps.map((s: { visits: number }) => s.visits), [3, 2, 1]);

    // Filters choose which visits enter.
    const filtered = await t.get("/api/funnels?period=today&compare=off&filter=page:is:/signup");
    assert.deepEqual(filtered.funnels[0].steps.map((s: { visits: number }) => s.visits), [2, 2, 1]);

    assert.equal((await write("PATCH", `/api/funnels/${funnel.id}`, { name: "Signup flow", steps: [{ kind: "page", match: "/pricing" }, { kind: "page", match: "/welcome" }] })).status, 200);
    assert.deepEqual((await t.get("/api/funnels?period=today")).funnels[0].steps.map((s: { visits: number }) => s.visits), [3, 1]);
    assert.equal((await write("DELETE", `/api/funnels/${funnel.id}`)).status, 200);
    assert.deepEqual((await t.get("/api/funnels?period=today")).funnels, []);
  });
}
