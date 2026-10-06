import assert from "node:assert/strict";
import { test } from "node:test";
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
