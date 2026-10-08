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

test("a hub connects an app through its consent page and changes that site's settings there", async () => {
  // The app, with two sites, run as a real server so the hub reaches it over HTTP.
  const app = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "shop", name: "Shop", hostnames: ["shop.example.com"] }, { id: "blog", name: "Blog", hostnames: ["blog.example.com"] }] });
  const appRoutes = app.routes({ token: "app-owner" });
  const server = createServer(toNodeHandler(appRoutes.handler));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const appUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/runlight`;
  const asAppOwner = (url: string, init: RequestInit = {}) => fetch(url, { ...init, redirect: "manual", headers: { ...(init.headers as Record<string, string>), authorization: "Bearer app-owner" } });

  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
    const { handler } = hub.routes({ token: "hub-owner" });
    const call = async (method: string, path: string, body?: unknown) => {
      const answer = await handler(new Request(`http://localhost:4900/runlight${path}`, { method, headers: { authorization: "Bearer hub-owner", "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
      return { status: answer.status, headers: answer.headers, body: (await answer.json().catch(() => null)) as any };
    };

    // 1. The hub sends the owner to the app's consent page.
    const started = await call("POST", "/api/sites/connect", { url: appUrl });
    assert.equal(started.status, 200);
    const consent = new URL(started.body.authorize);
    assert.equal(consent.searchParams.get("scope"), "manage");
    const page = await (await asAppOwner(consent.toString())).text();
    assert.match(page, /change its settings/);
    assert.doesNotMatch(page, /Every site/, "changing settings is for one site");

    // 2. The owner picks the blog and allows it; the app sends them back with a code.
    const form = new URLSearchParams([...consent.searchParams.entries()]);
    form.set("site", "blog");
    form.set("decision", "allow");
    const allowed = await asAppOwner(`${appUrl}/oauth/authorize`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form.toString() });
    assert.equal(allowed.status, 303);
    const back = new URL(allowed.headers.get("location")!);
    assert.equal(back.pathname, "/runlight/api/sites/connect/done");

    // 3. Back at the hub, the code becomes a manage token for the blog only.
    const done = await handler(new Request(back.toString(), { headers: { authorization: "Bearer hub-owner" } }));
    assert.equal(done.status, 303);
    const id = new URL(done.headers.get("location")!, "http://localhost:4900").searchParams.get("site")!;
    assert.equal(hub.remote(id)?.site, "blog");
    assert.equal(hub.remote(id)?.scope, "manage");
    const listed = (await call("GET", "/api/sites")).body.sites[0];
    assert.equal(listed.manage, true);
    assert.equal(listed.name, "Blog");

    // 4. Settings changed at the hub land in the app, on the blog.
    assert.equal((await call("POST", `/api/goals?site=${id}`, { name: "Signup", kind: "event", match: "Signup" })).status, 201);
    assert.equal((await call("POST", `/api/links?site=${id}`, { url: "https://example.org/", slug: "hi" })).status, 201);
    assert.equal((await call("POST", `/api/reports?site=${id}`, { email: "me@example.com" })).status, 201);
    assert.equal((await call("PATCH", `/api/sites/${id}`, { retentionMonths: 24 })).status, 200);
    const appGoals = (await (await asAppOwner(`${appUrl}/api/goals?site=blog`)).json()) as any;
    assert.deepEqual(appGoals.goals.map((g: any) => g.name), ["Signup"]);
    assert.equal((await app.retention("blog")), 24);
    assert.equal((await app.retention("shop")), null);
    assert.equal((await call("GET", "/api/sites")).body.sites[0].retentionMonths, 24, "the hub shows the app's setting");
    assert.equal(((await (await asAppOwner(`${appUrl}/api/goals?site=shop`)).json()) as any).goals.length, 0, "the other site is untouched");
    assert.equal((await call("GET", `/api/links?site=${id}`)).body.links.length, 1, "the Links box reads them back");

    // The app's own owner sees the hub's token and can revoke it, which stops changes at once.
    const tokens = (await (await asAppOwner(`${appUrl}/api/tokens`)).json()) as any;
    assert.equal(tokens.tokens[0].scope, "manage");
    await asAppOwner(`${appUrl}/api/tokens/${tokens.tokens[0].id}`, { method: "DELETE" });
    assert.equal((await call("POST", `/api/goals?site=${id}`, { name: "Later", kind: "event", match: "x" })).status, 502);

    // A code works once.
    const reused = await handler(new Request(back.toString(), { headers: { authorization: "Bearer hub-owner" } }));
    assert.match(reused.headers.get("location")!, /connect_error=/);
  } finally {
    server.close();
  }
});

test("connecting a site again with a manage token upgrades the same connection", async () => {
  const app = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "Shop", hostnames: ["shop.example.com"] } });
  const appRoutes = app.routes({ token: "app-owner" });
  const token = async (scope: string) => ((await (await appRoutes.POST(new Request("https://x/runlight/api/tokens", { method: "POST", headers: { authorization: "Bearer app-owner", "content-type": "application/json" }, body: JSON.stringify({ name: "Hub", scope, site: "default" }) }))).json()) as any).secret as string;
  const server = createServer(toNodeHandler(appRoutes.handler));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const appUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/runlight`;
  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
    const { POST } = hub.routes({ token: "hub-owner" });
    const add = async (secret: string) => ((await (await POST(new Request("http://localhost/runlight/api/sites", { method: "POST", headers: { authorization: "Bearer hub-owner", "content-type": "application/json" }, body: JSON.stringify({ remote: { url: appUrl, token: secret } }) }))).json()) as any).site.id as string;
    const first = await add(await token("read"));
    assert.equal(hub.remote(first)?.scope, "read");
    const second = await add(await token("manage"));
    assert.equal(second, first);
    assert.equal(hub.remote(first)?.scope, "manage");
    assert.equal(hub.sites.length, 1);
    // The old token was deleted there, and disconnecting deletes the new one too.
    const listed = async () => ((await (await appRoutes.GET(new Request("https://x/runlight/api/tokens", { headers: { authorization: "Bearer app-owner" } }))).json()) as any).tokens as Array<{ scope: string }>;
    assert.deepEqual((await listed()).map((t) => t.scope), ["manage"]);
    assert.equal((await hub.routes({ token: "hub-owner" }).handler(new Request(`http://localhost/runlight/api/sites/${first}`, { method: "DELETE", headers: { authorization: "Bearer hub-owner" } }))).status, 200);
    assert.deepEqual(await listed(), []);
  } finally {
    server.close();
  }
});

test("a hub only follows an install's own endpoints when connecting", async () => {
  const hostile = createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ authorization_endpoint: "http://127.0.0.1:1/authorize", token_endpoint: "http://169.254.169.254/token", registration_endpoint: "http://169.254.169.254/register", scopes_supported: ["read", "manage"] }));
  });
  await new Promise<void>((resolve) => hostile.listen(0, "127.0.0.1", resolve));
  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
    const { POST } = hub.routes({ token: "hub-owner" });
    const answer = await POST(new Request("http://localhost/runlight/api/sites/connect", { method: "POST", headers: { authorization: "Bearer hub-owner", "content-type": "application/json" }, body: JSON.stringify({ url: `http://127.0.0.1:${(hostile.address() as AddressInfo).port}` }) }));
    assert.equal(answer.status, 400);
    assert.match(((await answer.json()) as any).error, /named endpoints on another address/);
  } finally {
    hostile.close();
  }
});
