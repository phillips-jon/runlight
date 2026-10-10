import assert from "node:assert/strict";
import { test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

/** An app with two sites and an owner token, as a hub would connect to. */
async function app() {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "blog", hostnames: ["blog.example.com"] }, { id: "shop", hostnames: ["shop.example.com"] }] });
  const routes = rl.routes({ token: "owner", origin: "https://app.example.com" });
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
  assert.equal((await call("POST", "/api/tokens", manage, { name: "More", site: "blog" })).status, 403);
  assert.equal((await call("PUT", "/api/mail", manage, { service: "webhook" })).status, 403);
  assert.equal((await call("GET", "/api/mail?site=blog", manage)).status, 200, "it can see which mail service sends reports");
  const share = await call("POST", "/api/shares?site=blog", manage, { name: "For the team" });
  assert.equal(share.status, 201, "share links for its site are its to make");
  assert.equal((await call("POST", "/api/shares?site=shop", manage, { name: "x" })).status, 404);
  assert.equal((await call("DELETE", "/api/sites/blog", manage)).status, 403);
  assert.equal((await call("POST", "/api/links/import?site=blog", manage, { rows: [] })).status, 403);
});

test("a read token still only reads", async () => {
  const { call, make } = await app();
  const read = await make("read", "blog");
  assert.deepEqual((await call("GET", "/api/token", read)).body, { scope: "read", site: "blog" });
  assert.equal((await call("POST", "/api/goals?site=blog", read, { name: "Signup", kind: "event", match: "Signup" })).status, 403);
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
  const { target, ...stored } = (await (await call("GET", "/api/link-domains/db.internal/check?site=blog")).json()) as Record<string, unknown>;
  assert.deepEqual(stored, { domain: "db.internal", working: false, reason: "is not a public domain name", code: "check_not_public" });
  assert.ok(target, "and where a domain should point");

  // A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
  const { createServer } = await import("node:http");
  const sent: any[] = [];
  const mail = createServer((req, res) => {
    let text = "";
    req.on("data", (c) => (text += c));
    req.on("end", () => {
      sent.push(JSON.parse(text));
      res.end("ok");
    });
  });
  await new Promise<void>((resolve) => mail.listen(0, "127.0.0.1", resolve));
  try {
    await rl.saveMailSettings({ service: "webhook", url: `http://127.0.0.1:${(mail.address() as { port: number }).port}/`, from: "reports@example.com" });
    const manage = ((await (await call("POST", "/api/tokens", "owner", { name: "Hub", scope: "manage", site: "blog" })).json()) as any).secret as string;
    const first = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "a@example.com" })).json()) as any).report;
    const second = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "b@example.com" })).json()) as any).report;
    assert.deepEqual((await rl.store.reports("blog")).map((r) => r.origin), ["https://stats.example.com/runlight", "https://stats.example.com/runlight"]);
    assert.equal((await call("POST", `/api/reports/${first.id}/send?site=blog`, manage)).status, 200, "the first sample goes out");
    assert.equal(sent.length, 1);
    assert.equal(sent[0].to, "a@example.com");
    assert.ok(sent[0].text.includes("https://stats.example.com/runlight"), "its links point at the configured address");
    const waits = await call("POST", `/api/reports/${second.id}/send?site=blog`, manage);
    assert.equal(waits.status, 429, "another report waits too");
    assert.equal(((await waits.json()) as any).code, "sample_soon_hub");
    await call("DELETE", `/api/reports/${second.id}?site=blog`, manage);
    const again = ((await (await call("POST", "/api/reports?site=blog", manage, { email: "b@example.com" })).json()) as any).report;
    assert.equal((await call("POST", `/api/reports/${again.id}/send?site=blog`, manage)).status, 429, "and so does one added again");
    assert.equal(sent.length, 1);
  } finally {
    mail.close();
  }
});

test("without its own address, an app gives a hub no link domains or reports, and a link domain leaves the dashboard alone", async () => {
  // As the quickstart sets it up: one site, no origin, and the app answers on more names than the site's.
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "example.com", hostnames: ["example.com"] } });
  const routes = rl.routes({ token: "owner" });
  const call = async (host: string, method: string, path: string, auth: string, body?: unknown) => {
    const answer = await routes.handler(new Request(`https://${host}/runlight${path}`, { method, headers: { host, authorization: `Bearer ${auth}`, ...(body === undefined ? {} : { "content-type": "application/json" }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
    return { status: answer.status, body: (await answer.json().catch(() => null)) as any };
  };
  const manage = (await call("app.example.com", "POST", "/api/tokens", "owner", { name: "Hub", site: "default", scope: "manage" })).body.secret as string;
  // From the deployment's other name, where the app's own name is not the request's Host.
  const add = await call("example-app.vercel.app", "POST", "/api/link-domains", manage, { domain: "app.example.com" });
  assert.equal(add.status, 400);
  assert.equal(add.body.code, "origin_needed");
  assert.equal((await call("example-app.vercel.app", "POST", "/api/reports", manage, { email: "cfo@example.com" })).body.code, "origin_needed");
  assert.equal((await call("app.example.com", "POST", "/api/link-domains", "owner", { domain: "go.example.com" })).status, 201, "the owner still adds them");
  // On a link domain the dashboard's paths pass to the app, so the owner can always reach it there.
  for (const path of ["/runlight", "/runlight/api/sites"]) assert.equal(await rl.linkDomainResponse(new Request(`https://go.example.com${path}`, { headers: { host: "go.example.com" } })), null, path);
  assert.equal((await rl.linkDomainResponse(new Request("https://go.example.com/nothing", { headers: { host: "go.example.com" } })))?.status, 404);
  // Middleware that never made the routes leaves the default path alone too.
  const apart = runlight({ store: rl.store, site: { name: "example.com", hostnames: ["example.com"] } });
  assert.equal(await apart.linkDomainResponse(new Request("https://go.example.com/runlight", { headers: { host: "go.example.com" } })), null);
});

test("the hub never passes on an install's answer as a page, nor follows its redirects", async () => {
  const { createServer } = await import("node:http");
  const evil = createServer((req, res) => {
    if (req.url?.startsWith("/runlight/api/sites")) return res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sites: [{ id: "x", name: "X", timezone: "UTC", hostnames: ["x.example.com"] }] }));
    if (req.url?.startsWith("/runlight/api/stats")) return res.writeHead(200, { "content-type": "text/html" }).end("<script>alert(1)</script>");
    if (req.url?.startsWith("/runlight/api/series")) return res.writeHead(302, { location: "http://169.254.169.254/" }).end();
    if (req.url?.startsWith("/runlight/api/rhythm")) return res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: `Your session ended. Sign in again at https://evil.example/login ${"x".repeat(1000)}`, code: "link_taken", params: { slug: "a", n: 5 } }));
    res.writeHead(404).end("{}");
  });
  await new Promise<void>((resolve) => evil.listen(0, "127.0.0.1", resolve));
  try {
    const hub = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32), localInstalls: true });
    const { handler } = hub.routes({ token: "owner" });
    const call = (path: string, init: RequestInit = {}) => handler(new Request(`https://hub.example.com/runlight${path}`, { ...init, headers: { authorization: "Bearer owner", "content-type": "application/json" } }));
    const added = await call("/api/sites", { method: "POST", body: JSON.stringify({ remote: { url: `http://127.0.0.1:${(evil.address() as { port: number }).port}/runlight`, token: "rl_x" } }) });
    const id = ((await added.json()) as any).site.id;
    const page = await call(`/api/stats?site=${id}&period=today`);
    assert.match(page.headers.get("content-type")!, /^application\/json/);
    assert.equal(page.headers.get("x-content-type-options"), "nosniff");
    assert.match(page.headers.get("content-security-policy")!, /default-src 'none'/);
    assert.equal((await call(`/api/series?site=${id}&period=today`)).status, 502, "a redirect is reported, not followed");
    // An install's error says where it came from, short, with only its code and string params.
    const said = (await (await call(`/api/rhythm?site=${id}&period=today`)).json()) as any;
    assert.match(said.error, /^127\.0\.0\.1:\d+: Your session ended/);
    assert.ok(said.error.length < 340);
    assert.equal(said.code, "link_taken");
    assert.deepEqual(said.params, { slug: "a" });
  } finally {
    evil.close();
  }
});
