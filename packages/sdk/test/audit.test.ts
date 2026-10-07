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

test("a click goal's selector with $' or $& leaves the tracker script valid", async () => {
  const t = setup("sqlite");
  for (const match of [".a$'", "[data-x=\"$&\"]", ".b$`"]) {
    const r = await t.routes.handler(new Request("https://example.com/runlight/api/goals", { method: "POST", headers: auth, body: JSON.stringify({ name: `G ${match}`, kind: "click", clickBy: "selector", match }) }));
    assert.equal(r.status, 201);
  }
  const script = await (await t.routes.GET(new Request("https://example.com/runlight/s.js"))).text();
  assert.doesNotThrow(() => new Function(script), "s.js still parses");
  assert.ok(script.includes(".a$'"));
});

test("filters on inherited object keys are refused, not run as SQL", async () => {
  const t = setup("sqlite");
  const r = await t.routes.GET(new Request("https://example.com/runlight/api/stats?filter=constructor:is:x", { headers: auth }));
  assert.equal(r.status, 400);
});

test("links and link domains only change from the site that owns them", async () => {
  const rl = runlight({
    store: sqlite({ path: ":memory:" }),
    sites: [
      { id: "a", hostnames: ["a.com"] },
      { id: "b", hostnames: ["b.com"] },
    ],
  });
  const { POST, PATCH, DELETE } = rl.routes({ token: "secret" });
  const call = (handler: typeof POST, method: string, path: string, body?: unknown) =>
    handler(new Request(`https://x.com/runlight${path}`, { method, headers: auth, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const made = (await (await call(POST, "POST", "/api/links?site=a", { url: "https://a.com/x" })).json()) as { link: { id: string } };
  assert.equal((await call(PATCH, "PATCH", `/api/links/${made.link.id}?site=b`, { name: "stolen" })).status, 404);
  assert.equal((await call(DELETE, "DELETE", `/api/links/${made.link.id}?site=b`)).status, 404);
  assert.equal((await call(POST, "POST", "/api/link-domains?site=a", { domain: "go.a.com" })).status, 201);
  assert.equal((await call(POST, "POST", "/api/link-domains?site=b", { domain: "go.a.com" })).status, 409);
  assert.equal((await call(DELETE, "DELETE", "/api/link-domains/go.a.com?site=b")).status, 404);
  assert.equal((await call(DELETE, "DELETE", `/api/links/${made.link.id}?site=a`)).status, 200);
});

test("a saved SMTP password is kept only while the server it goes to stays the same", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), secret: "k".repeat(32) });
  const base = { service: "smtp", host: "smtp.example.com", port: "587", security: "starttls", username: "me", from: "r@example.com" };
  await rl.saveMailSettings({ ...base, password: "hunter2-long" });
  await rl.saveMailSettings({ ...base, password: "", from: "reports@example.com" });
  assert.equal((await rl.mailSettings())?.password, "hunter2-long", "same server, blank field: kept");
  await rl.saveMailSettings({ ...base, host: "evil.example", password: "", from: "reports@example.com" });
  assert.equal((await rl.mailSettings())?.password ?? "", "", "a new host needs the password typed again");
});
