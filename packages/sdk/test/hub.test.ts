import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { runlight } from "../src/index.js";
import { toNodeHandler } from "../src/node.js";
import { sqlite } from "../src/stores/sqlite.js";

test("a standalone server reads a connected app install through its API, and changes nothing there", async () => {
  // The app, with Runlight inside and one visit.
  const app = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "Shop", hostnames: ["shop.example.com"], timezone: "Europe/Paris" } });
  const appRoutes = app.routes({ token: "app-owner" });
  await appRoutes.POST(new Request("https://shop.example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.7" }, body: JSON.stringify({ k: "pageview", u: "https://shop.example.com/cart" }) }));
  const made = await appRoutes.POST(new Request("https://shop.example.com/runlight/api/tokens", { method: "POST", headers: { authorization: "Bearer app-owner", "content-type": "application/json" }, body: JSON.stringify({ name: "Hub" }) }));
  const { secret } = (await made.json()) as { secret: string };
  const server = createServer(toNodeHandler(appRoutes.handler));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const appUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/runlight`;

  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
    const { GET, POST, PATCH } = hub.routes({ token: "hub-owner" });
    const auth = { authorization: "Bearer hub-owner", "content-type": "application/json" };
    const call = (handler: typeof GET, method: string, path: string, body?: unknown) =>
      handler(new Request(`https://stats.example.com/runlight${path}`, { method, headers: auth, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

    assert.equal((await call(POST, "POST", "/api/sites", { remote: { url: appUrl, token: "rl_wrong" } })).status, 400);
    const added = await call(POST, "POST", "/api/sites", { remote: { url: appUrl, token: secret } });
    assert.equal(added.status, 201);
    const { site } = (await added.json()) as { site: { id: string; name: string; hostnames: string[]; timezone: string } };
    assert.deepEqual({ name: site.name, hostnames: site.hostnames, timezone: site.timezone }, { name: "Shop", hostnames: [], timezone: "Europe/Paris" });

    const sites = (await (await call(GET, "GET", "/api/sites")).json()) as any;
    assert.equal(sites.sites[0].remote, appUrl);
    assert.ok(sites.sites[0].lastSeen, "the app's last visit shows here");

    const stats = (await (await call(GET, "GET", `/api/stats?site=${site.id}&period=today`)).json()) as any;
    assert.equal(stats.stats.pageviews, 1, "the numbers come from the app");
    const pages = (await (await call(GET, "GET", `/api/breakdown?site=${site.id}&period=today&dimension=page`)).json()) as any;
    assert.deepEqual(pages.rows.map((r: any) => r.value), ["/cart"]);

    // Nothing about the app can be changed from the hub, and hits never land on it here.
    assert.equal((await call(POST, "POST", `/api/goals?site=${site.id}`, { name: "X", kind: "event", match: "X" })).status, 400);
    await hub.routes({ token: null }).POST(new Request("https://stats.example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36" }, body: JSON.stringify({ k: "pageview", u: "https://shop.example.com/", s: site.id }) }));
    const local = await hub.store.db.all(`SELECT COUNT(*) AS n FROM rl_events`);
    assert.equal(Number(local[0]!.n), 0);
    assert.equal((await call(PATCH, "PATCH", `/api/sites/${site.id}`, { name: "The shop" })).status, 200, "its name here is the hub's own");

    // A restart reads the connection back, and removing it leaves the app's data alone.
    const again = runlight({ store: hub.store, managedSites: true, secret: "k".repeat(32) });
    await again.init();
    assert.equal(again.remote(site.id)?.url, appUrl);
    assert.equal((await call(hub.routes({ token: "hub-owner" }).DELETE, "DELETE", `/api/sites/${site.id}`)).status, 200);
    assert.equal(((await (await appRoutes.GET(new Request("https://shop.example.com/runlight/api/stats?period=today", { headers: { authorization: "Bearer app-owner" } }))).json()) as any).stats.pageviews, 1);
    assert.deepEqual(await hub.store.settingsStartingWith("remote:"), []);
  } finally {
    server.close();
  }
});
