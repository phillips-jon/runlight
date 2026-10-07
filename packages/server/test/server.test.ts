import assert from "node:assert/strict";
import { test } from "node:test";
import { sqlite } from "@runlight/sdk/sqlite";
import { createServer } from "../src/server.js";

const origin = "https://stats.example.com";
const req = (path: string, init: RequestInit & { host?: string } = {}) => new Request(`${init.host ? `https://${init.host}` : origin}${path}`, init);
const form = (fields: Record<string, string>) => ({ method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(fields).toString() });
const cookieOf = (response: Response) => (response.headers.get("set-cookie") ?? "").split(";")[0]!;

function make(token?: string) {
  let now = Date.UTC(2026, 9, 7, 12);
  const server = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), now: () => now, ...(token ? { token } : {}) });
  return { server, handle: server.handler, advance: (ms: number) => (now += ms) };
}

test("a new server is locked until the setup link's code makes the first account", async () => {
  const { server, handle } = make();
  assert.equal((await handle(req("/"))).status, 403, "the dashboard waits for setup");
  assert.match(await (await handle(req("/"))).text(), /setup link printed in the server/);
  assert.equal((await handle(req("/setup?code=wrong"))).status, 403);
  assert.equal((await handle(req("/setup", form({ code: "wrong", email: "a@b.co", password: "long enough pw" })))).status, 403);
  assert.equal((await handle(req(`/setup?code=${server.setupCode}`))).status, 200);
  assert.equal((await handle(req("/setup", form({ code: server.setupCode, email: "a@b.co", password: "short" })))).status, 400);

  const made = await handle(req("/setup", form({ code: server.setupCode, email: "Jon@Example.com", password: "a long password" })));
  assert.equal(made.status, 303);
  assert.equal(made.headers.get("location"), "/");
  assert.match(made.headers.get("set-cookie") ?? "", /HttpOnly; SameSite=Lax; Max-Age=2592000; Secure/);
  assert.equal((await handle(req("/", { headers: { cookie: cookieOf(made) } }))).status, 200, "signed straight in");
  assert.equal((await handle(req(`/setup?code=${server.setupCode}`))).headers.get("location"), "/login", "setup closes once an account exists");
});

test("sign in, sign out, wrong passwords, throttling, and sessions that end with a password change", async () => {
  const { server, handle, advance } = make();
  await server.accounts.setPassword("jon@example.com", "a long password", Date.now());

  const away = await handle(req("/?period=7d"));
  assert.equal(away.status, 303);
  assert.equal(away.headers.get("location"), `/login?next=${encodeURIComponent("/?period=7d")}`);
  assert.equal((await handle(req("/api/sites"))).status, 401);

  const wrong = await handle(req("/login", form({ email: "jon@example.com", password: "nope nope nope" })));
  assert.equal(wrong.status, 401);
  assert.match(await wrong.text(), /do not match an account/);

  const ok = await handle(req("/login", form({ email: "JON@example.com", password: "a long password", next: "//evil.example" })));
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.get("location"), "/", "a next address off this server is ignored");
  for (const next of ["/\t/evil.example", "/\\evil.example", "/\n/evil.example", "https://evil.example"]) {
    const bounced = await handle(req("/login", form({ email: "jon@example.com", password: "a long password", next })));
    assert.equal(bounced.headers.get("location"), "/", `next=${JSON.stringify(next)} stays on this server`);
  }
  const deep = await handle(req("/login", form({ email: "jon@example.com", password: "a long password", next: "/?site=blog&period=7d" })));
  assert.equal(deep.headers.get("location"), "/?site=blog&period=7d");
  const cookie = cookieOf(ok);
  assert.equal((await handle(req("/api/sites", { headers: { cookie } }))).status, 200);
  assert.match(await (await handle(req("/", { headers: { cookie } }))).text(), /data-sign-out="\/logout"/);

  const out = await handle(req("/logout"));
  assert.match(out.headers.get("set-cookie") ?? "", /Max-Age=0/);

  // A new password signs out every browser that had the old one.
  await server.accounts.setPassword("jon@example.com", "another long password", Date.now());
  assert.equal((await handle(req("/api/sites", { headers: { cookie } }))).status, 401);

  // Ten wrong tries from one address, then a wait.
  const from = { "x-forwarded-for": "198.51.100.7" };
  for (let i = 0; i < 10; i++) await handle(req("/login", { ...form({ email: "jon@example.com", password: "wrong wrong" }), headers: { ...form({}).headers, ...from } }));
  const blocked = await handle(req("/login", { ...form({ email: "jon@example.com", password: "another long password" }), headers: { ...form({}).headers, ...from } }));
  assert.equal(blocked.status, 429);
  advance(16 * 60_000);
  const later = await handle(req("/login", { ...form({ email: "jon@example.com", password: "another long password" }), headers: { ...form({}).headers, ...from } }));
  assert.equal(later.status, 303);

  // Inventing a new address for every try does not escape the per-account limit.
  let throttled = 0;
  for (let i = 0; i < 60; i++) {
    const r = await handle(req("/login", { ...form({ email: "jon@example.com", password: "wrong wrong" }), headers: { ...form({}).headers, "cf-connecting-ip": `10.0.${i}.1` } }));
    if (r.status === 429) throttled++;
  }
  assert.ok(throttled >= 10, `rotating addresses were throttled ${throttled} times`);
  advance(16 * 60_000);

  // Sessions run out after thirty days.
  const expiring = cookieOf(later);
  advance(31 * 86_400_000);
  assert.equal((await handle(req("/api/sites", { headers: { cookie: expiring } }))).status, 401);
});

test("sites are added in the dashboard, counted across origins, and short links answer on their own domains", async () => {
  const { server, handle } = make("script-token");
  await server.accounts.setPassword("jon@example.com", "a long password", Date.now());
  const auth = { authorization: "Bearer script-token", "content-type": "application/json" };

  const added = await handle(req("/api/sites", { method: "POST", headers: auth, body: JSON.stringify({ name: "Blog", hostnames: "blog.example.com" }) }));
  assert.equal(added.status, 201);

  // The tracker lives on the server's domain and is loaded by the site's pages.
  const script = await handle(req("/s.js"));
  assert.equal(script.status, 200);
  const hit = await handle(
    req("/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": "203.0.113.9" }, body: JSON.stringify({ k: "pageview", u: "https://blog.example.com/post", s: "blog.example.com" }) }),
  );
  assert.equal(hit.status, 202);
  const stats = (await (await handle(req("/api/stats?site=blog.example.com&period=today", { headers: auth }))).json()) as any;
  assert.equal(stats.stats.pageviews, 1);

  // A link domain pointed at this server answers at its root, with no middleware.
  assert.equal((await handle(req("/api/link-domains?site=blog.example.com", { method: "POST", headers: auth, body: JSON.stringify({ domain: "go.example.com" }) }))).status, 201);
  const made = (await (await handle(req("/api/links?site=blog.example.com", { method: "POST", headers: auth, body: JSON.stringify({ url: "https://blog.example.com/launch", slug: "launch", domain: "go.example.com" }) }))).json()) as any;
  assert.equal(made.link.slug, "launch");
  const short = await handle(req("/launch", { host: "go.example.com" }));
  assert.equal(short.status, 302);
  assert.equal(short.headers.get("location"), "https://blog.example.com/launch");
  const fallback = await handle(req("/go/launch"));
  assert.equal(fallback.status, 302, "every link also answers at /go/:slug on the server itself");

  assert.equal((await handle(req("/healthz"))).status, 200);
  assert.equal((await handle(req("/api/sites", { headers: { authorization: "Bearer wrong" } }))).status, 401);
});

test("owners add people as owners or viewers; viewers read every site and change nothing", async () => {
  const { server, handle } = make();
  await server.accounts.setPassword("owner@example.com", "a long password", Date.now());
  const signIn = async (email: string, password: string) => cookieOf(await handle(req("/login", form({ email, password }))));
  const owner = await signIn("owner@example.com", "a long password");
  const json = (cookie: string, method: string, path: string, body?: unknown) =>
    handle(req(path, { method, headers: { cookie, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

  assert.deepEqual(((await (await json(owner, "GET", "/api/account")).json()) as any).account.role, "owner");
  const added = await json(owner, "POST", "/api/people", { email: "Viewer@Example.com", role: "viewer" });
  assert.equal(added.status, 201);
  const { person, password } = (await added.json()) as any;
  assert.equal(person.email, "viewer@example.com");
  assert.match(password, /^[A-Za-z0-9_-]{16}$/);
  assert.equal((await json(owner, "POST", "/api/people", { email: "viewer@example.com", role: "viewer" })).status, 409);
  assert.equal((await handle(req("/api/people", { method: "POST", headers: { cookie: owner, "content-type": "text/plain; application/json" }, body: "{}" }))).status, 415);

  // The viewer reads and changes nothing.
  const viewer = await signIn("viewer@example.com", password);
  assert.equal((await json(owner, "POST", "/api/sites", { hostnames: "blog.example.com" })).status, 201);
  assert.equal((await json(viewer, "GET", "/api/sites")).status, 200);
  assert.equal((await json(viewer, "GET", "/api/stats?site=blog.example.com&period=today")).status, 200);
  assert.equal((await json(viewer, "POST", "/api/sites", { hostnames: "other.example.com" })).status, 401);
  assert.equal((await json(viewer, "POST", "/api/tokens", { name: "x" })).status, 401);
  assert.equal((await json(viewer, "GET", "/api/people")).status, 403);
  assert.match(await (await handle(req("/", { headers: { cookie: viewer } }))).text(), /data-accounts=""/);

  // Everyone changes their own password, and stays signed in while doing it.
  assert.equal((await json(viewer, "POST", "/api/account/password", { current: "wrong", next: "a brand new password" })).status, 400);
  const changed = await json(viewer, "POST", "/api/account/password", { current: password, next: "a brand new password" });
  assert.equal(changed.status, 200);
  const fresh = cookieOf(changed);
  assert.equal((await json(fresh, "GET", "/api/account")).status, 200);
  assert.equal((await json(viewer, "GET", "/api/account")).status, 401, "the old sign-in ends");

  // Roles change, and the last owner stays an owner.
  const ownerId = ((await (await json(owner, "GET", "/api/account")).json()) as any).account.id;
  assert.equal((await json(owner, "PATCH", `/api/people/${ownerId}`, { role: "viewer" })).status, 400);
  assert.equal((await json(owner, "DELETE", `/api/people/${ownerId}`)).status, 400);
  assert.equal(((await (await json(owner, "PATCH", `/api/people/${person.id}`, { role: "owner" })).json()) as any).person.role, "owner");
  assert.equal((await json(fresh, "POST", "/api/sites", { hostnames: "now.example.com" })).status, 201, "the promoted owner can change things");
  assert.equal((await json(owner, "DELETE", `/api/people/${person.id}`)).status, 200);
  assert.equal((await json(fresh, "GET", "/api/account")).status, 401, "a removed person is signed out");
});
