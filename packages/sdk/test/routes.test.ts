import assert from "node:assert/strict";
import { test } from "node:test";
import { DASHBOARD_HASH, LOCALES_HASH } from "../src/generated/dashboard.js";
import { TRACKER_HASH } from "../src/generated/tracker.js";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const make = () => runlight({ store: sqlite({ path: ":memory:" }) });
const req = (path: string, init: RequestInit = {}) => new Request(`https://example.com${path}`, init);

test("the tracker is public, cached, and answers 304 to its etag", async () => {
  const { GET } = make().routes({ token: "secret" });
  const first = await GET(req("/runlight/s.js"));
  assert.equal(first.status, 200);
  assert.match(first.headers.get("content-type") ?? "", /javascript/);
  assert.match(await first.text(), /sendBeacon/);
  const again = await GET(req("/runlight/s.js", { headers: { "if-none-match": `"${TRACKER_HASH}"` } }));
  assert.equal(again.status, 304);
});

test("stats need the token, as a bearer or through the cookie", async () => {
  const { GET } = make().routes({ token: "secret" });
  assert.equal((await GET(req("/runlight/api/stats"))).status, 401);
  assert.equal((await GET(req("/runlight/api/stats", { headers: { authorization: "Bearer wrong" } }))).status, 401);
  assert.equal((await GET(req("/runlight/api/stats", { headers: { authorization: "Bearer secret" } }))).status, 200);

  const signIn = await GET(req("/runlight/?token=secret"));
  assert.equal(signIn.status, 303);
  assert.equal(signIn.headers.get("location"), "/runlight/");
  const cookie = signIn.headers.get("set-cookie") ?? "";
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /Secure/);
  assert.ok(!cookie.includes("secret"), "the cookie holds a digest, not the token");
  const value = cookie.split(";")[0]!;
  assert.equal((await GET(req("/runlight/api/stats", { headers: { cookie: value } }))).status, 200);
  assert.equal((await GET(req("/runlight/", { headers: { cookie: value } }))).status, 200);
});

test("with no token, production refuses and development is open", async () => {
  const before = process.env.NODE_ENV;
  const warn = console.warn;
  console.warn = () => {};
  try {
    process.env.NODE_ENV = "production";
    assert.equal((await make().routes({ token: undefined }).GET(req("/runlight/api/stats"))).status, 503);
    process.env.NODE_ENV = "development";
    assert.equal((await make().routes({ token: undefined }).GET(req("/runlight/api/stats"))).status, 200);
  } finally {
    process.env.NODE_ENV = before;
    console.warn = warn;
  }
});

test("authorize replaces the token", async () => {
  const { GET } = make().routes({ authorize: (r) => r.headers.get("x-admin") === "yes" });
  assert.equal((await GET(req("/runlight/api/sites"))).status, 401);
  assert.equal((await GET(req("/runlight/api/sites", { headers: { "x-admin": "yes" } }))).status, 200);
});

test("the check endpoint takes the cron secret", async () => {
  const { POST } = make().routes({ token: "secret", cronSecret: "cron" });
  assert.equal((await POST(req("/runlight/api/check", { method: "POST" }))).status, 401);
  assert.equal((await POST(req("/runlight/api/check", { method: "POST", headers: { authorization: "Bearer cron" } }))).status, 200);
  assert.equal((await POST(req("/runlight/api/check", { method: "POST", headers: { authorization: "Bearer secret" } }))).status, 200);
});

test("basePath moves everything", async () => {
  const { GET } = make().routes({ token: "secret", basePath: "/admin/runlight/" });
  assert.equal((await GET(req("/admin/runlight/s.js"))).status, 200);
  assert.equal((await GET(req("/runlight/s.js"))).status, 404);
  const info = await (await GET(req("/admin/runlight/api"))).json();
  assert.equal(info.name, "runlight");
  assert.equal(info.library, "@runlight/sdk");
});

test("bad queries are 400s with a reason", async () => {
  const { GET } = make().routes({ token: null });
  const bad = async (path: string) => {
    const response = await GET(req(path));
    assert.equal(response.status, 400, path);
    assert.ok((await response.json()).error);
  };
  await bad("/runlight/api/stats?period=forever");
  await bad("/runlight/api/stats?filter=nope");
  await bad("/runlight/api/stats?filter=page:like:x");
  await bad("/runlight/api/breakdown?dimension=shoe_size");
});

test("the dashboard page loads its hashed assets under a strict CSP", async () => {
  const { GET } = make().routes({ token: "secret", basePath: "/admin/runlight" });
  const page = await GET(req("/admin/runlight/"));
  assert.equal(page.status, 200, "the shell holds no data, so it loads signed out");
  assert.match(page.headers.get("content-security-policy") ?? "", /script-src 'self'/);
  const html = await page.text();
  assert.ok(html.includes(`/admin/runlight/assets/app.${DASHBOARD_HASH}.js`));
  assert.ok(html.includes('data-base="/admin/runlight"'));
  const js = await GET(req(`/admin/runlight/assets/app.${DASHBOARD_HASH}.js`));
  assert.equal(js.status, 200);
  assert.match(js.headers.get("cache-control") ?? "", /immutable/);
  assert.equal((await GET(req(`/admin/runlight/assets/app.${DASHBOARD_HASH}.css`))).status, 200);
  assert.equal((await GET(req("/admin/runlight/assets/app.old.js"))).status, 404);
  assert.ok(html.includes(`/admin/runlight/assets/locale.fr.${LOCALES_HASH}.json`), "the page lists its languages");
  const french = await GET(req(`/admin/runlight/assets/locale.fr.${LOCALES_HASH}.json`));
  assert.equal(french.status, 200);
  assert.equal((await french.json())["filter.button"], "Filtrer");
  assert.equal((await GET(req(`/admin/runlight/assets/locale.xx.${LOCALES_HASH}.json`))).status, 404);
  assert.equal((await GET(req("/admin/runlight/api/stats"))).status, 401, "the data stays behind the token");
});

test("icon links are ranked: touch icon, then SVG, then PNG, then anything", async () => {
  const { iconLinks } = await import("../src/icon.js");
  const html = `<link rel="icon" href="/favicon.ico"><link rel=icon type="image/png" href="/i.png">
    <link href='/i.svg' rel="icon" type="image/svg+xml"><link rel="apple-touch-icon" href="https://cdn.example.com/t.png">
    <link rel="stylesheet" href="/s.css"><link rel="icon" href="javascript:alert(1)">`;
  assert.deepEqual(iconLinks(html, "https://example.com/"), [
    "https://cdn.example.com/t.png",
    "https://example.com/i.svg",
    "https://example.com/i.png",
    "https://example.com/favicon.ico",
  ]);
});

test("a site's name and timezone can be changed, and survive a restart", async () => {
  const store = sqlite({ path: ":memory:" });
  const first = runlight({ store, site: { name: "From code", timezone: "UTC" } });
  const { PATCH, GET } = first.routes({ token: null });
  const patch = (body: unknown, type = "application/json") =>
    PATCH(req("/runlight/api/sites/default", { method: "PATCH", body: JSON.stringify(body), headers: { "content-type": type } }));
  assert.equal((await patch({ name: "Jon's site", timezone: "America/Toronto" })).status, 200);
  assert.equal((await patch({ timezone: "Mars/Olympus" })).status, 400);
  assert.equal((await patch({ name: "" })).status, 400);
  assert.equal((await patch({ name: "x" }, "text/plain")).status, 415);
  assert.equal((await PATCH(req("/runlight/api/sites/nope", { method: "PATCH", body: "{}", headers: { "content-type": "application/json" } }))).status, 404);
  const listed = await (await GET(req("/runlight/api/sites"))).json();
  assert.equal(listed.sites[0].name, "Jon's site");
  assert.equal(listed.sites[0].lastSeen, null);

  // Code still says "From code"; the dashboard's change wins after a restart.
  const again = runlight({ store, site: { name: "From code", timezone: "UTC" } });
  await again.init();
  assert.equal(again.site("default")!.name, "Jon's site");
  assert.equal(again.site("default")!.timezone, "America/Toronto");
});

test("a version 1 database upgrades to the current schema", async () => {
  const store = sqlite({ path: ":memory:" });
  await store.db.run("CREATE TABLE rl_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  await store.db.run("INSERT INTO rl_meta (key, value) VALUES ('schema', '1')");
  await store.db.run("CREATE TABLE rl_sites (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', hostnames TEXT NOT NULL DEFAULT '[]', timezone TEXT NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL)");
  const rl = runlight({ store });
  await rl.updateSite("default", { name: "Upgraded" });
  assert.equal(rl.site("default")!.name, "Upgraded");
  const [meta] = await store.db.all<{ value: string }>("SELECT value FROM rl_meta WHERE key = 'schema'");
  assert.equal(meta!.value, "3");
});
