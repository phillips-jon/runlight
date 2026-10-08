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
