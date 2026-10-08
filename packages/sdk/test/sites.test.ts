import assert from "node:assert/strict";
import { after, test } from "node:test";
import { runlight } from "../src/index.js";
import { STORES, cleanup, freshStore } from "./helpers.js";

after(cleanup);

for (const kind of STORES) {
  test(`${kind}: managed sites are added, changed, and deleted in the dashboard, and outlive a restart`, async () => {
    const store = freshStore(kind);
    const rl = runlight({ store, managedSites: true, site: { name: "Ignored" } });
    const { GET, POST, PATCH, DELETE } = rl.routes({ token: "secret" });
    const auth = { authorization: "Bearer secret", "content-type": "application/json" };
    const url = (path: string) => `https://stats.example.com/runlight${path}`;
    const call = async (method: string, path: string, body?: unknown) => {
      const handler = { GET, POST, PATCH, DELETE }[method as "GET"]!;
      const answer = await handler(new Request(url(path), { method, headers: auth, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
      return { status: answer.status, body: (await answer.json()) as any };
    };

    const empty = await call("GET", "/api/sites");
    assert.deepEqual(empty.body, { sites: [], managed: true }, "no sites until one is added; the site in code is ignored");

    assert.equal((await call("POST", "/api/sites", { name: "Blog" })).status, 400, "a site needs its domain");
    assert.equal((await call("POST", "/api/sites", { hostnames: "not a domain" })).status, 400);
    const blog = await call("POST", "/api/sites", { name: "Blog", hostnames: "https://www.blog.example.com/path", timezone: "Europe/London" });
    assert.equal(blog.status, 201);
    assert.deepEqual(blog.body.site, { id: "blog.example.com", name: "Blog", hostnames: ["blog.example.com"], timezone: "Europe/London" });
    const shop = await call("POST", "/api/sites", { hostnames: ["shop.example.com", "store.example.com"] });
    assert.equal(shop.body.site.name, "shop.example.com", "the name defaults to the domain");
    assert.match((await call("POST", "/api/sites", { hostnames: "store.example.com" })).body.error, /already belongs to shop\.example\.com/);

    // Visits reach the right site by hostname, across origins.
    const send = (page: string, ip: string) =>
      POST(new Request(url("/e"), { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": ip }, body: JSON.stringify({ k: "pageview", u: page }) }));
    await send("https://blog.example.com/hello", "203.0.113.1");
    await send("https://store.example.com/", "203.0.113.2");
    await send("https://elsewhere.example/", "203.0.113.3");
    const blogStats = await call("GET", "/api/stats?site=blog.example.com&period=today");
    assert.equal(blogStats.body.stats.pageviews, 1);
    assert.equal((await call("GET", "/api/stats?site=shop.example.com&period=today")).body.stats.pageviews, 1);

    const renamed = await call("PATCH", "/api/sites/shop.example.com", { name: "Shop", hostnames: "shop.example.com" });
    assert.deepEqual(renamed.body.site.hostnames, ["shop.example.com"]);
    assert.equal((await call("PATCH", "/api/sites/shop.example.com", { hostnames: "blog.example.com" })).status, 400, "hostnames stay unique");

    // A restart reads the sites back from the database.
    const again = runlight({ store, managedSites: true });
    await again.init();
    assert.deepEqual(again.sites.map((s) => [s.id, s.name]), [["blog.example.com", "Blog"], ["shop.example.com", "Shop"]]);

    assert.equal((await call("DELETE", "/api/sites/shop.example.com")).status, 200);
    assert.equal((await call("DELETE", "/api/sites/shop.example.com")).status, 404);
    assert.deepEqual((await call("GET", "/api/sites")).body.sites.map((s: any) => s.id), ["blog.example.com"]);
    const left = await store.db.all(`SELECT COUNT(*) AS n FROM rl_events WHERE site = ?`, ["shop.example.com"]);
    assert.equal(Number(left[0]!.n), 0, "a deleted site's visits go with it");
  });
}

test("sites set in code cannot be added or deleted from the dashboard", async () => {
  const rl = runlight({ store: freshStore("sqlite"), site: { name: "Code" } });
  const { GET, POST, DELETE } = rl.routes({ token: "secret" });
  const auth = { authorization: "Bearer secret", "content-type": "application/json" };
  assert.equal((await POST(new Request("https://x.com/runlight/api/sites", { method: "POST", headers: auth, body: JSON.stringify({ hostnames: "a.com" }) }))).status, 400);
  assert.equal((await DELETE(new Request("https://x.com/runlight/api/sites/default", { method: "DELETE", headers: auth }))).status, 400);
  const listed = (await (await GET(new Request("https://x.com/runlight/api/sites", { headers: auth }))).json()) as any;
  assert.equal(listed.managed, false);
});

test("a second server process on the same database sees new sites and connected installs at its next check", async () => {
  const { sqlite } = await import("../src/stores/sqlite.js");
  const store = sqlite({ path: ":memory:" });
  const one = runlight({ store, managedSites: true, secret: "k".repeat(32) });
  const two = runlight({ store, managedSites: true, secret: "k".repeat(32) });
  await one.init();
  await two.init();
  await one.addSite({ hostnames: "new.example.com" });
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response(JSON.stringify({ sites: [{ id: "default", name: "App", timezone: "UTC", hostnames: ["app.example.com"] }] }), { headers: { "content-type": "application/json" } })) as typeof fetch;
  try {
    await one.addSite({ remote: { url: "https://app.example.com/runlight", token: "rl_x" } });
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(two.sites.map((s) => s.id), [], "not yet");
  await two.check();
  assert.deepEqual(two.sites.map((s) => s.id).sort(), ["app.example.com", "new.example.com"]);
  assert.equal(two.remote("app.example.com")?.url, "https://app.example.com/runlight");
});

for (const kind of STORES) {
  test(`${kind}: a site's retention setting deletes visits older than it allows`, async () => {
    const store = freshStore(kind);
    let now = Date.UTC(2026, 9, 6, 12, 0, 0);
    const rl = runlight({ store, site: { hostnames: ["example.com"] }, now: () => now });
    const { GET, POST, PATCH } = rl.routes({ token: "t" });
    const auth = { authorization: "Bearer t", "content-type": "application/json" };
    const hit = (ip: string) =>
      POST(new Request("https://example.com/runlight/e", {
        method: "POST",
        headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": ip },
        body: JSON.stringify({ k: "pageview", u: "https://example.com/" }),
      }));
    const visits = async () => ((await (await GET(new Request("https://example.com/runlight/api/stats?period=all", { headers: auth }))).json()) as any).stats.visits;
    const listed = async () => ((await (await GET(new Request("https://example.com/runlight/api/sites", { headers: auth }))).json()) as any).sites[0].retentionMonths;

    now = Date.UTC(2025, 9, 1);
    await hit("203.0.113.1");
    now = Date.UTC(2026, 6, 1);
    await hit("203.0.113.2");
    now = Date.UTC(2026, 9, 6, 12);
    await hit("203.0.113.3");
    assert.equal(await visits(), 3);
    assert.equal(await listed(), null, "everything is kept by default");

    const patch = (body: unknown) => PATCH(new Request("https://example.com/runlight/api/sites/default", { method: "PATCH", headers: auth, body: JSON.stringify(body) }));
    assert.equal((await patch({ retentionMonths: 7 })).status, 400);
    assert.equal((await patch({ retentionMonths: 6 })).status, 200);
    assert.equal(await listed(), 6);
    assert.equal(await visits(), 2, "the visit from a year ago is gone at once");

    now = Date.UTC(2027, 1, 1);
    await rl.check();
    assert.equal(await visits(), 1, "the scheduled check keeps trimming");
    assert.equal((await patch({ retentionMonths: null })).status, 200);
    assert.equal(await listed(), null);
  });
}
