import assert from "node:assert/strict";
import { test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

/** An app with two sites and an owner token, as a hub would connect to. */
async function app() {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "blog", hostnames: ["blog.example.com"] }, { id: "shop", hostnames: ["shop.example.com"] }] });
  const routes = rl.routes({ token: "owner" });
  const call = async (method: string, path: string, auth: string, body?: unknown) => {
    const answer = await routes.handler(new Request(`https://app.example.com/runlight${path}`, {
      method,
      headers: { authorization: `Bearer ${auth}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }));
    return { status: answer.status, body: (await answer.json().catch(() => null)) as any };
  };
  const make = async (scope: string, site: string) => (await call("POST", "/api/tokens", "owner", { name: "Hub", scope, site })).body.secret as string;
  return { rl, call, make };
}

test("a manage token changes its own site's settings and nothing else", async () => {
  const { call, make } = await app();
  assert.equal((await call("POST", "/api/tokens", "owner", { name: "Hub", scope: "manage" })).status, 400, "a manage token is for one site");
  const manage = await make("manage", "blog");

  assert.deepEqual((await call("GET", "/api/token", manage)).body, { scope: "manage", site: "blog" });
  const goal = await call("POST", "/api/goals?site=blog", manage, { name: "Signup", kind: "event", match: "Signup" });
  assert.equal(goal.status, 201);
  assert.equal((await call("POST", "/api/goals", manage, { name: "No site given", kind: "event", match: "x" })).status, 201, "its site is assumed");
  assert.equal((await call("GET", "/api/goals?site=blog", "owner")).body.goals.length, 2);
  assert.equal((await call("POST", "/api/goals?site=shop", manage, { name: "Elsewhere", kind: "event", match: "x" })).status, 404, "never another site");
  assert.equal((await call("GET", "/api/goals?site=shop", "owner")).body.goals.length, 0);

  const link = await call("POST", "/api/links?site=blog", manage, { url: "https://example.org/", slug: "hello" });
  assert.equal(link.status, 201);
  assert.equal((await call("GET", "/api/links?site=blog", manage)).body.links.length, 1);
  assert.equal((await call("POST", "/api/reports?site=blog", manage, { email: "me@example.com" })).status, 201);
  assert.equal((await call("PATCH", "/api/sites/blog", manage, { name: "The blog", retentionMonths: 12 })).status, 200);
  assert.equal((await call("PATCH", "/api/sites/shop", manage, { name: "Mine now" })).status, 404);
  assert.equal((await call("PATCH", "/api/sites/blog", manage, { hostnames: "evil.example" })).status, 403);

  // Everything beyond one site's settings stays the owner's.
  assert.equal((await call("GET", "/api/tokens", manage)).status, 401);
  assert.equal((await call("POST", "/api/tokens", manage, { name: "More", site: "blog" })).status, 401);
  assert.equal((await call("PUT", "/api/mail", manage, { service: "webhook" })).status, 401);
  assert.equal((await call("GET", "/api/mail?site=blog", manage)).status, 200, "it can see which mail service sends reports");
  const share = await call("POST", "/api/shares?site=blog", manage, { name: "For the team" });
  assert.equal(share.status, 201, "share links for its site are its to make");
  assert.equal((await call("POST", "/api/shares?site=shop", manage, { name: "x" })).status, 404);
  assert.equal((await call("DELETE", "/api/sites/blog", manage)).status, 401);
  assert.equal((await call("POST", "/api/links/import?site=blog", manage, { rows: [] })).status, 401);
});

test("a read token still only reads", async () => {
  const { call, make } = await app();
  const read = await make("read", "blog");
  assert.deepEqual((await call("GET", "/api/token", read)).body, { scope: "read", site: "blog" });
  assert.equal((await call("POST", "/api/goals?site=blog", read, { name: "Signup", kind: "event", match: "Signup" })).status, 401);
  assert.equal((await call("GET", "/api/stats?site=blog&period=today", read)).status, 200);
});

test("a link domain can never be where the dashboard or a counted site lives", async () => {
  const { call } = await app();
  assert.equal((await call("POST", "/api/link-domains?site=blog", "owner", { domain: "app.example.com" })).status, 400, "the dashboard's own host");
  assert.equal((await call("POST", "/api/link-domains?site=blog", "owner", { domain: "shop.example.com" })).status, 400, "a site's domain");
  assert.equal((await call("POST", "/api/link-domains?site=blog", "owner", { domain: "go.example.com" })).status, 201);
});

test("link domains stay off the configured address and the names people signed in from, whatever Host a request names", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "blog", hostnames: ["blog.example.com"] }] });
  const routes = rl.routes({ token: "owner", origin: "https://stats.example.com", ownHosts: async () => ["dash.example.net:443"] });
  const call = (method: string, path: string, auth = "owner", body?: unknown) =>
    routes.handler(new Request(`https://decoy.example.org/runlight${path}`, { method, headers: { authorization: `Bearer ${auth}`, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const add = async (domain: string) => (await call("POST", "/api/link-domains?site=blog", "owner", { domain })).status;
  for (const taken of ["stats.example.com", "stats.example.com.", "www.stats.example.com", "dash.example.net", "decoy.example.org"]) assert.equal(await add(taken), 400, taken);
  // Names inside private networks, which the check would make the install fetch.
  for (const inside of ["metadata.google.internal", "db.corp", "printer.local", "nas.home.arpa", "router.lan", "10.0.0.5.nip.io", "app.localhost"]) assert.equal(await add(inside), 400, inside);
  assert.equal(await add("go.example.org"), 201);
  // One saved before that rule is never fetched.
  await rl.store.addLinkDomain("db.internal", "blog", Date.now());
  assert.deepEqual(await (await call("GET", "/api/link-domains/db.internal/check?site=blog")).json(), { domain: "db.internal", working: false, reason: "is not a public domain name" });

  // A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
  const manage = ((await (await call("POST", "/api/tokens", "owner", { name: "Hub", scope: "manage", site: "blog" })).json()) as any).secret as string;
  const first = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "a@example.com" })).json()) as any).report;
  const second = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "b@example.com" })).json()) as any).report;
  assert.deepEqual((await rl.store.reports("blog")).map((r) => r.origin), ["https://stats.example.com/runlight", "https://stats.example.com/runlight"]);
  assert.notEqual((await call("POST", `/api/reports/${first.id}/send?site=blog`, manage)).status, 429);
  assert.equal((await call("POST", `/api/reports/${second.id}/send?site=blog`, manage)).status, 429, "another report waits too");
  await call("DELETE", `/api/reports/${second.id}?site=blog`, manage);
  const again = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "b@example.com" })).json()) as any).report;
  assert.equal((await call("POST", `/api/reports/${again.id}/send?site=blog`, manage)).status, 429, "and so does one added again");
});

test("the hub never passes on an install's answer as a page, nor follows its redirects", async () => {
  const { createServer } = await import("node:http");
  const evil = createServer((req, res) => {
    if (req.url?.startsWith("/runlight/api/sites")) return res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sites: [{ id: "x", name: "X", timezone: "UTC", hostnames: ["x.example.com"] }] }));
    if (req.url?.startsWith("/runlight/api/stats")) return res.writeHead(200, { "content-type": "text/html" }).end("<script>alert(1)</script>");
    if (req.url?.startsWith("/runlight/api/series")) return res.writeHead(302, { location: "http://169.254.169.254/" }).end();
    res.writeHead(404).end("{}");
  });
  await new Promise<void>((resolve) => evil.listen(0, "127.0.0.1", resolve));
  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
    const { handler } = hub.routes({ token: "owner" });
    const call = (path: string, init: RequestInit = {}) => handler(new Request(`https://hub.example.com/runlight${path}`, { ...init, headers: { authorization: "Bearer owner", "content-type": "application/json" } }));
    const added = await call("/api/sites", { method: "POST", body: JSON.stringify({ remote: { url: `http://127.0.0.1:${(evil.address() as { port: number }).port}/runlight`, token: "rl_x" } }) });
    const id = ((await added.json()) as any).site.id;
    const page = await call(`/api/stats?site=${id}&period=today`);
    assert.match(page.headers.get("content-type")!, /^application\/json/);
    assert.equal(page.headers.get("x-content-type-options"), "nosniff");
    assert.match(page.headers.get("content-security-policy")!, /default-src 'none'/);
    assert.equal((await call(`/api/series?site=${id}&period=today`)).status, 502, "a redirect is reported, not followed");
  } finally {
    evil.close();
  }
});
