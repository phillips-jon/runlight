// Regressions for what the October 2026 audit found and confirmed.
import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";
import { STORES, cleanup, freshStore, setup, type StoreKind } from "./helpers.js";

after(cleanup);

const auth = { authorization: "Bearer secret", "content-type": "application/json" };

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  const write = (t: ReturnType<typeof setup>, method: string, path: string, body?: unknown, headers: Record<string, string> = auth) =>
    t.routes.handler(new Request(`https://example.com/runlight${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

  test("a visitor's pageview and event arriving together make one session", async () => {
    const t = setup(kind);
    await Promise.all([
      t.send({ k: "pageview", u: "https://example.com/", i: "p1" }),
      t.send({ k: "event", u: "https://example.com/", n: "Signup", i: "p1" }),
      t.send({ k: "event", u: "https://example.com/", n: "Clicked" }),
    ]);
    const stats = await t.get("/api/stats?period=today&compare=off");
    assert.equal(stats.stats.visits, 1);
    assert.equal(stats.stats.visitors, 1);
  });

  test("renaming a click goal keeps its history, and click and event goals cannot share a name", async () => {
    const t = setup(kind);
    const made = await write(t, "POST", "/api/goals", { name: "Buy", kind: "click", clickBy: "selector", match: ".buy" });
    const { goal } = (await made.json()) as { goal: { id: string } };
    await t.send({ k: "event", u: "https://example.com/", n: "Buy" });
    assert.equal((await write(t, "PATCH", `/api/goals/${goal.id}`, { name: "Purchase button", kind: "click", clickBy: "selector", match: ".buy" })).status, 200);
    const report = await t.get("/api/goals?period=today&compare=off");
    assert.equal(report.goals[0].name, "Purchase button");
    assert.equal(report.goals[0].conversions, 1, "the click made under the old name still counts");
    const clash = await write(t, "POST", "/api/goals", { name: "Signup", kind: "event", match: "Purchase button" });
    assert.equal(clash.status, 400);
  });

  test("a JSON body must be JSON by its media type, so a no-cors text/plain post cannot pass", async () => {
    const t = setup(kind);
    const sneaky = await write(t, "POST", "/api/goals", { name: "X", kind: "event", match: "X" }, { authorization: "Bearer secret", "content-type": "text/plain; application/json" });
    assert.equal(sneaky.status, 415);
    const fine = await write(t, "POST", "/api/goals", { name: "X", kind: "event", match: "X" }, { authorization: "Bearer secret", "content-type": "application/json; charset=utf-8" });
    assert.equal(fine.status, 201);
  });

  test("a managed install counts the first hit it gets, before anything else has loaded its sites", async () => {
    const store = freshStore(kind);
    const first = runlight({ store, managedSites: true });
    await first.addSite({ hostnames: "blog.example.com" });
    const cold = runlight({ store, managedSites: true });
    const { POST, GET } = cold.routes({ token: "secret" });
    await POST(new Request("https://stats.example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.4" }, body: JSON.stringify({ k: "pageview", u: "https://blog.example.com/" }) }));
    const stats = (await (await GET(new Request("https://stats.example.com/runlight/api/stats?period=today", { headers: auth }))).json()) as any;
    assert.equal(stats.stats.pageviews, 1);
  });
}

test("on SQLite, a write made while a transaction is open is never rolled back with it", async () => {
  const store = sqlite({ path: ":memory:" });
  await store.migrate();
  const event = (path: string) => ({ site: "s", ts: 1, kind: "pageview" as const, visitor: "v", session: "x", pageview: "", path, hostname: "", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: "" });
  let release!: () => void;
  const open = store
    .transaction(async (tx) => {
      await tx.insertEvent(event("/inside"));
      await new Promise<void>((resolve) => (release = resolve));
      throw new Error("roll back");
    })
    .catch(() => "rolled back");
  // Live traffic during the import.
  const live = store.insertEvent(event("/live"));
  const second = store.transaction(async (tx) => tx.insertEvent(event("/second")));
  await new Promise((resolve) => setTimeout(resolve, 10));
  release();
  assert.equal(await open, "rolled back");
  await live;
  await second;
  const paths = (await store.db.all<{ path: string }>(`SELECT path FROM rl_events ORDER BY path`)).map((r) => r.path);
  assert.deepEqual(paths, ["/live", "/second"]);
});
