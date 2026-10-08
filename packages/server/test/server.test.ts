import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
  assert.equal((await handle(req("/setup", form({ code: server.setupCode, email: "a@b.co", password: "short", again: "short" })))).status, 400);
  const mismatch = await handle(req("/setup", form({ code: server.setupCode, email: "a@b.co", password: "a long password", again: "a long pasword" })));
  assert.equal(mismatch.status, 400, "the password is asked twice");
  assert.match(await mismatch.text(), /not the same/);

  const made = await handle(req("/setup", form({ code: server.setupCode, email: "Jon@Example.com", password: "a long password", again: "a long password" })));
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

test("a link domain never takes over the dashboard's own name, sign-in, or API", async () => {
  const { server, handle } = make("script-token");
  await server.accounts.setPassword("jon@example.com", "a long password", Date.now());
  const auth = { authorization: "Bearer script-token", "content-type": "application/json" };
  await handle(req("/api/sites", { method: "POST", headers: auth, body: JSON.stringify({ name: "Blog", hostnames: "blog.example.com" }) }));
  const addDomain = (domain: string, host: string) => handle(req("/api/link-domains?site=blog.example.com", { host, method: "POST", headers: auth, body: JSON.stringify({ domain }) }));

  // Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
  const cookie = cookieOf(await handle(req("/login", form({ email: "jon@example.com", password: "a long password" }))));
  assert.equal((await handle(req("/api/sites", { headers: { cookie } }))).status, 200);
  for (const host of ["decoy.example.org", "203.0.113.5", "stats.example.com."]) assert.equal((await addDomain("stats.example.com", host)).status, 400, host);

  // Added anyway, as before this rule: its short links answer, and the server's own pages stay the server's.
  await server.runlight.store.addLinkDomain("stats.example.com", "blog.example.com", Date.now());
  server.runlight.forgetLinkDomains();
  await handle(req("/api/links?site=blog.example.com", { method: "POST", headers: auth, body: JSON.stringify({ url: "https://blog.example.com/a", slug: "login", domain: "stats.example.com" }) }));
  await handle(req("/api/links?site=blog.example.com", { method: "POST", headers: auth, body: JSON.stringify({ url: "https://blog.example.com/b", slug: "sale", domain: "stats.example.com" }) }));
  assert.equal((await handle(req("/sale"))).status, 302);
  assert.equal((await handle(req("/login"))).status, 200, "sign-in is still the sign-in page");
  assert.equal((await handle(req("/", { headers: { cookie } }))).status, 200, "the dashboard opens for someone signed in");
  assert.equal((await handle(req("/", {}))).status, 404);
  assert.equal((await handle(req("/api/link-domains/stats.example.com?site=blog.example.com", { method: "DELETE", headers: { cookie } }))).status, 200, "so it can be removed");
  assert.equal((await handle(req("/sale"))).status, 404);

  // With the public address set, short links never answer there, and nobody can add it under any Host.
  const named = createServer({ store: sqlite({ path: ":memory:" }), secret: "s".repeat(64), token: "script-token", url: "https://stats.example.com" });
  await named.handler(req("/api/sites", { method: "POST", headers: auth, body: JSON.stringify({ name: "Blog", hostnames: "blog.example.com" }) }));
  assert.equal((await named.handler(req("/api/link-domains?site=blog.example.com", { host: "decoy.example.org", method: "POST", headers: auth, body: JSON.stringify({ domain: "stats.example.com" }) }))).status, 400);
  await named.runlight.store.addLinkDomain("stats.example.com", "blog.example.com", Date.now());
  named.runlight.forgetLinkDomains();
  await named.handler(req("/api/links?site=blog.example.com", { method: "POST", headers: auth, body: JSON.stringify({ url: "https://blog.example.com/b", slug: "sale", domain: "stats.example.com" }) }));
  assert.equal((await named.handler(req("/sale"))).status, 404);
  assert.equal((await named.handler(req("/"))).status, 403, "the dashboard, waiting for setup");
});

test("only the owner and admins teach the server its names, and a hub adds no link domain until the server knows its address", async () => {
  const { server, handle } = make();
  const owner = await server.accounts.setPassword("jon@example.com", "a long password", Date.now());
  const viewer = await server.accounts.setPassword("viewer@example.com", "another long one", Date.now(), "viewer");
  const as = (user: typeof owner) => `runlight_session=${encodeURIComponent(server.accounts.sessionFor(user, Date.now()))}`;
  const names = async () => JSON.parse((await server.runlight.store.setting("server-hosts")) ?? "[]") as string[];
  // A viewer's made-up forwarded names fill nothing.
  for (let i = 0; i < 25; i++) await handle(req("/api/sites", { headers: { cookie: as(viewer), "x-forwarded-host": `junk${i}.example.org` } }));
  assert.deepEqual(await names(), []);
  // An owner's are learned, if they are domain names.
  await handle(req("/api/sites", { headers: { cookie: as(owner), "x-forwarded-host": "203.0.113.7:8080" } }));
  await handle(req("/api/sites", { headers: { cookie: as(owner) } }));
  assert.deepEqual(await names(), ["stats.example.com"]);

  const json = { cookie: as(owner), "content-type": "application/json" };
  await handle(req("/api/sites", { method: "POST", headers: json, body: JSON.stringify({ name: "Blog", hostnames: "blog.example.com" }) }));
  const hub = ((await (await handle(req("/api/tokens", { method: "POST", headers: json, body: JSON.stringify({ name: "Hub", site: "blog.example.com", scope: "manage" }) }))).json()) as any).secret;
  const add = await handle(req("/api/link-domains?site=blog.example.com", { host: "decoy.example.org", method: "POST", headers: { authorization: `Bearer ${hub}`, "content-type": "application/json" }, body: JSON.stringify({ domain: "analytics.example.com" }) }));
  assert.equal(add.status, 400);
  assert.equal(((await add.json()) as any).code, "origin_needed");
});

test("the owner adds people by invite; viewers read every site and change nothing", async () => {
  const { server, handle } = make();
  await server.accounts.setPassword("owner@example.com", "a long password", Date.now());
  const signIn = async (email: string, password: string) => cookieOf(await handle(req("/login", form({ email, password }))));
  const owner = await signIn("owner@example.com", "a long password");
  const json = (cookie: string, method: string, path: string, body?: unknown) =>
    handle(req(path, { method, headers: { cookie, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));

  assert.deepEqual(((await (await json(owner, "GET", "/api/account")).json()) as any).account.role, "owner");
  // An owner invites; the person chooses their own password from the link.
  const added = await json(owner, "POST", "/api/people", { email: "Viewer@Example.com", role: "viewer" });
  assert.equal(added.status, 201);
  const sent = (await added.json()) as any;
  assert.equal(sent.invite.email, "viewer@example.com");
  assert.equal(sent.emailed, false, "no mail service here, so the link is for the owner to pass on");
  const link = new URL(sent.link);
  assert.equal(link.origin + link.pathname, `${origin}/invite`);
  assert.equal(((await (await json(owner, "GET", "/api/people")).json()) as any).invites.length, 1);
  assert.equal((await json(owner, "POST", "/api/people", { email: "owner@example.com", role: "viewer" })).status, 409);
  assert.equal((await handle(req("/api/people", { method: "POST", headers: { cookie: owner, "content-type": "text/plain; application/json" }, body: "{}" }))).status, 415);

  const page = await handle(req(link.pathname + link.search));
  assert.equal(page.status, 200);
  assert.match(await page.text(), /viewer@example\.com/);
  assert.equal((await handle(req(`/invite?code=${"x".repeat(32)}`))).status, 410, "a made-up code finds nothing");
  const code = link.searchParams.get("code")!;
  assert.equal((await handle(req("/invite", form({ code, password: "a long password", again: "a different one" })))).status, 400);
  const joined = await handle(req("/invite", form({ code, password: "a long password", again: "a long password" })));
  assert.equal(joined.status, 303, "joining signs the person in");
  const viewer = cookieOf(joined);
  const password = "a long password";
  assert.equal((await handle(req("/invite", form({ code, password: "another long one", again: "another long one" })))).status, 410, "the link works once");
  const listed = ((await (await json(owner, "GET", "/api/people")).json()) as any);
  assert.equal(listed.invites.length, 0);
  const person = listed.people.find((p: any) => p.email === "viewer@example.com");
  assert.equal(person.role, "viewer");

  // Sending again replaces the link; cancelling ends it.
  const second = ((await (await json(owner, "POST", "/api/people", { email: "later@example.com", role: "admin" })).json()) as any);
  const resent = ((await (await json(owner, "POST", `/api/invites/${second.invite.id}/resend`)).json()) as any);
  assert.notEqual(resent.link, second.link);
  assert.equal((await handle(req(new URL(second.link).pathname + new URL(second.link).search))).status, 410, "the old link stopped working");
  assert.equal((await json(owner, "DELETE", `/api/invites/${resent.invite.id}`)).status, 200);
  assert.equal((await handle(req(new URL(resent.link).pathname + new URL(resent.link).search))).status, 410);

  // The viewer reads and changes nothing.
  assert.equal((await json(owner, "POST", "/api/sites", { hostnames: "blog.example.com" })).status, 201);
  assert.equal((await json(viewer, "GET", "/api/sites")).status, 200);
  assert.equal((await json(viewer, "GET", "/api/stats?site=blog.example.com&period=today")).status, 200);
  // Refused as signed in but not allowed, so the dashboard says why instead of signing them out.
  const refused = await json(viewer, "POST", "/api/sites", { hostnames: "other.example.com" });
  assert.equal(refused.status, 403);
  assert.equal(((await refused.json()) as any).code, "owner_only");
  assert.equal((await json(viewer, "POST", "/api/tokens", { name: "x" })).status, 403);
  assert.equal((await json(viewer, "GET", "/api/people")).status, 403);
  const board = await (await handle(req("/", { headers: { cookie: viewer } }))).text();
  assert.match(board, /data-accounts=""/);
  assert.match(board, /data-sign-in="\/login"/, "so the dashboard can link to sign-in when a session ends");

  // Everyone changes their own password, and stays signed in while doing it.
  const wrong = await json(viewer, "POST", "/api/account/password", { current: "wrong", next: "a brand new password" });
  assert.deepEqual([wrong.status, (await wrong.json()).code], [400, "password_current_wrong"]);
  const short = await (await json(viewer, "POST", "/api/account/password", { current: password, next: "short" })).json();
  assert.deepEqual([short.code, short.params], ["password_short", { min: "10" }]);
  const changed = await json(viewer, "POST", "/api/account/password", { current: password, next: "a brand new password" });
  assert.equal(changed.status, 200);
  const fresh = cookieOf(changed);
  assert.equal((await json(fresh, "GET", "/api/account")).status, 200);
  assert.equal((await json(viewer, "GET", "/api/account")).status, 401, "the old sign-in ends");

  // Roles change, apart from the owner's, which nobody changes or removes here.
  const ownerId = ((await (await json(owner, "GET", "/api/account")).json()) as any).account.id;
  assert.equal((await json(owner, "PATCH", `/api/people/${ownerId}`, { role: "viewer" })).status, 403);
  assert.equal((await json(owner, "DELETE", `/api/people/${ownerId}`)).status, 400, "nobody removes themselves");
  assert.equal((await json(owner, "PATCH", `/api/people/${person.id}`, { role: "owner" })).status, 400, "ownership is handed over, never given");
  assert.equal(((await (await json(owner, "PATCH", `/api/people/${person.id}`, { role: "admin" })).json()) as any).person.role, "admin");
  assert.equal((await json(fresh, "POST", "/api/sites", { hostnames: "now.example.com" })).status, 201, "the promoted admin can change things");
  assert.equal((await json(owner, "DELETE", `/api/people/${person.id}`)).status, 200);
  assert.equal((await json(fresh, "GET", "/api/account")).status, 401, "a removed person is signed out");
});

test("removing someone deletes the tokens they made and the apps they connected", async () => {
  const { server, handle } = make();
  await server.accounts.setPassword("jon@example.com", "a long password", Date.now());
  const amy = await server.accounts.setPassword("amy@example.com", "a long password", Date.now());
  await server.accounts.setRole(amy.id, "admin");
  const signIn = async (email: string) => cookieOf(await handle(req("/login", form({ email, password: "a long password" }))));
  const jon = await signIn("jon@example.com");
  const her = await signIn("amy@example.com");
  const makeToken = async (cookie: string, name: string) =>
    ((await (await handle(req("/api/tokens", { method: "POST", headers: { cookie, "content-type": "application/json" }, body: JSON.stringify({ name }) }))).json()) as any).secret as string;
  const mine = await makeToken(jon, "Jon's script");
  const hers = await makeToken(her, "Amy's script");

  // Amy also connects an app over OAuth.
  const { client_id } = (await (await handle(req("/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://claude.ai/cb"] }) }))).json()) as any;
  const verifier = "v".repeat(50);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const allowed = await handle(req("/oauth/authorize", { method: "POST", headers: { cookie: her, origin, "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ response_type: "code", client_id, redirect_uri: "https://claude.ai/cb", code_challenge: challenge, code_challenge_method: "S256", decision: "allow" }).toString() }));
  const code = new URL(allowed.headers.get("location")!).searchParams.get("code")!;
  const granted = (await (await handle(req("/oauth/token", form({ grant_type: "authorization_code", code, client_id, redirect_uri: "https://claude.ai/cb", code_verifier: verifier })))).json()) as any;
  const app = granted.access_token as string;

  const works = async (token: string) => (await handle(req("/api/sites", { headers: { authorization: `Bearer ${token}` } }))).status;
  assert.deepEqual([await works(mine), await works(hers), await works(app)], [200, 200, 200]);
  assert.equal((await handle(req(`/api/people/${amy.id}`, { method: "DELETE", headers: { cookie: jon } }))).status, 200);
  assert.deepEqual([await works(mine), await works(hers), await works(app)], [200, 401, 401], "only Jon's own token is left");
});

test("an app's token belongs to whoever allowed it, however the swap is sent, and goes when they become a viewer or leave", async () => {
  const { server, handle } = make();
  await server.accounts.setPassword("jon@example.com", "a long password", Date.now());
  const bob = await server.accounts.setPassword("bob@example.com", "a long password", Date.now());
  const signIn = async (email: string) => cookieOf(await handle(req("/login", form({ email, password: "a long password" }))));
  const jon = await signIn("jon@example.com");
  const his = await signIn("bob@example.com");
  const { client_id } = (await (await handle(req("/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Script", redirect_uris: ["https://app.example/cb"] }) }))).json()) as any;
  const verifier = "v".repeat(50);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const allow = async () => {
    const allowed = await handle(req("/oauth/authorize", { method: "POST", headers: { cookie: his, origin, "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ response_type: "code", client_id, redirect_uri: "https://app.example/cb", code_challenge: challenge, code_challenge_method: "S256", decision: "allow" }).toString() }));
    return new URL(allowed.headers.get("location")!).searchParams.get("code")!;
  };
  const swap = async (code: string, type: string) =>
    handle(req("/oauth/token", { method: "POST", headers: { "content-type": type }, body: new URLSearchParams({ grant_type: "authorization_code", code, client_id, redirect_uri: "https://app.example/cb", code_verifier: verifier }).toString() }));
  const works = async (token: string) => (await handle(req("/api/sites", { headers: { authorization: `Bearer ${token}` } }))).status;

  // A media type the token endpoint reads as a form, which once kept the maker from being noted.
  const odd = ((await (await swap(await allow(), "application/jsonx")).json()) as any).access_token as string;
  assert.equal(await works(odd), 200);
  // Made a viewer: every token he made goes.
  assert.equal((await handle(req(`/api/people/${bob.id}`, { method: "PATCH", headers: { cookie: jon, "content-type": "application/json" }, body: JSON.stringify({ role: "viewer" }) }))).status, 200);
  assert.equal(await works(odd), 401);

  // A code he allowed as an admin and the app swaps after he is removed gets nothing.
  await server.accounts.setRole(bob.id, "admin");
  const late = await allow();
  assert.equal((await handle(req(`/api/people/${bob.id}`, { method: "DELETE", headers: { cookie: jon } }))).status, 200);
  const refused = await swap(late, "application/x-www-form-urlencoded");
  assert.equal(((await refused.json()) as any).error, "invalid_grant");
  assert.equal(((await (await handle(req("/api/tokens", { headers: { cookie: jon } }))).json()) as any).tokens.length, 0);
});

test("an invite goes out by email when the server has a mail service", async () => {
  const { createServer: listen } = await import("node:http");
  const got: any[] = [];
  const hook = listen((r, res) => {
    let text = "";
    r.on("data", (c) => (text += c));
    r.on("end", () => {
      got.push(JSON.parse(text));
      res.end("ok");
    });
  });
  await new Promise<void>((resolve) => hook.listen(0, "127.0.0.1", resolve));
  try {
    const { server, handle } = make();
    await server.accounts.setPassword("owner@example.com", "a long password", Date.now());
    const owner = cookieOf(await handle(req("/login", form({ email: "owner@example.com", password: "a long password" }))));
    await server.runlight.saveMailSettings({ service: "webhook", url: `http://127.0.0.1:${(hook.address() as { port: number }).port}/`, from: "runlight@example.com" });
    const sent = (await (await handle(req("/api/people", { method: "POST", headers: { cookie: owner, "content-type": "application/json" }, body: JSON.stringify({ email: "new@example.com", role: "viewer" }) }))).json()) as any;
    assert.equal(sent.emailed, true);
    assert.equal(got.length, 1);
    assert.equal(got[0].to, "new@example.com");
    assert.match(got[0].subject, /owner@example\.com invited you/);
    assert.ok(got[0].text.includes(sent.link), "the email carries the link");
  } finally {
    hook.close();
  }
});

test("one owner, admins who manage everyone else, members kept from the install-wide controls, and handing over", async () => {
  const store = sqlite({ path: ":memory:" });
  const server = createServer({ store, secret: "s".repeat(64), now: () => Date.UTC(2026, 9, 8, 12) });
  const handle = server.handler;
  const owner = await server.accounts.setPassword("owner@example.com", "a long password", Date.now());
  assert.equal(owner.role, "owner", "the first account is the owner");
  const ada = await server.accounts.setPassword("ada@example.com", "a long password", Date.now());
  assert.equal(ada.role, "admin", "a later one is an admin unless a role is given, since there is one owner");
  const mo = await server.accounts.setPassword("mo@example.com", "a long password", Date.now(), "member");
  const signIn = async (email: string, password = "a long password") => cookieOf(await handle(req("/login", form({ email, password }))));
  const as = async (cookie: string, method: string, path: string, body?: unknown) =>
    handle(req(path, { method, headers: { cookie, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const [o, a, m] = [await signIn("owner@example.com"), await signIn("ada@example.com"), await signIn("mo@example.com")];

  // A member changes a site's settings like anyone else.
  assert.equal((await as(m, "POST", "/api/sites", { hostnames: "blog.example.com" })).status, 201);
  assert.equal((await as(m, "POST", "/api/goals?site=blog.example.com", { name: "Signup", kind: "page", match: "/thanks" })).status, 201);
  assert.equal((await as(m, "POST", "/api/tokens", { name: "Script" })).status, 201);
  // Not people, the mail service, the assistant's settings, or deleting a site.
  assert.equal((await as(m, "GET", "/api/people")).status, 403);
  assert.equal((await as(m, "POST", "/api/people", { email: "x@example.com", role: "viewer" })).status, 403);
  for (const [method, path] of [["PUT", "/api/mail"], ["DELETE", "/api/mail"], ["PUT", "/api/assistant"], ["DELETE", "/api/assistant"], ["PUT", "/api/assistant/limits"], ["POST", "/api/assistant/models"], ["DELETE", "/api/sites/blog.example.com"]] as const) {
    const refused = await as(m, method, path, {});
    assert.equal(refused.status, 403, `${method} ${path}`);
    assert.equal(((await refused.json()) as any).code, "admin_only");
  }
  const assistant = ((await (await as(m, "GET", "/api/assistant")).json()) as any);
  assert.equal(assistant.provider, undefined, "a member sees whether the assistant is set up, never its settings");

  // An admin manages everyone but the owner, other admins included.
  assert.equal((await as(a, "PATCH", `/api/people/${mo.id}`, { role: "viewer" })).status, 200);
  assert.equal((await as(a, "PATCH", `/api/people/${owner.id}`, { role: "member" })).status, 403);
  assert.equal((await as(a, "DELETE", `/api/people/${owner.id}`)).status, 403);
  assert.equal((await as(a, "DELETE", `/api/people/${owner.id}/2fa`, { password: "a long password" })).status, 403);
  assert.equal((await as(a, "POST", "/api/people", { email: "new@example.com", role: "owner" })).status, 400, "nobody is invited as the owner");
  assert.equal((await as(a, "POST", "/api/people", { email: "new@example.com", role: "admin" })).status, 201);
  assert.equal((await as(a, "POST", `/api/people/${ada.id}/owner`, { password: "a long password" })).status, 403, "only the owner hands over");
  assert.equal((await as(a, "DELETE", "/api/sites/blog.example.com")).status, 200, "an admin can delete a site");

  // The owner hands over to an admin, with their password, and becomes an admin.
  assert.equal((await as(o, "POST", `/api/people/${mo.id}/owner`, { password: "a long password" })).status, 400, "only to an admin");
  assert.equal((await as(o, "POST", `/api/people/${ada.id}/owner`, { password: "wrong one" })).status, 400);
  const handed = ((await (await as(o, "POST", `/api/people/${ada.id}/owner`, { password: "a long password" })).json()) as any).people;
  assert.deepEqual(handed.map((p: any) => [p.email, p.role]).sort(), [["ada@example.com", "owner"], ["mo@example.com", "viewer"], ["owner@example.com", "admin"]]);
  assert.equal((await as(o, "DELETE", `/api/people/${ada.id}`)).status, 403, "the new owner is protected from the old one");

  // A server from before with several owners keeps the first, and the rest become admins.
  await store.db.run(`UPDATE rl_users SET role = 'owner'`);
  const again = createServer({ store, secret: "s".repeat(64) });
  const roles = (await again.accounts.list()).map((u) => [u.email, u.role]);
  assert.deepEqual(roles, [["owner@example.com", "owner"], ["ada@example.com", "admin"], ["mo@example.com", "admin"]]);
});
