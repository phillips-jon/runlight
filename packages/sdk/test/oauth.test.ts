import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const b64url = (buf: Buffer) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

test("an app connects to the MCP server over OAuth: discovery, registration, consent, PKCE, and a read-only token", async () => {
  const rl = runlight({
    store: sqlite({ path: ":memory:" }),
    sites: [
      { id: "a", name: "Site A", hostnames: ["a.com"] },
      { id: "b", name: "Site B", hostnames: ["b.com"] },
    ],
  });
  const { GET, POST } = rl.routes({ token: "secret" });
  const origin = "https://x.com";
  const owner = { authorization: "Bearer secret" };

  // The MCP endpoint points at the metadata.
  const refused = await POST(new Request(`${origin}/runlight/mcp`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }));
  assert.equal(refused.status, 401);
  const metadataUrl = /resource_metadata="([^"]+)"/.exec(refused.headers.get("www-authenticate") ?? "")?.[1];
  assert.equal(metadataUrl, `${origin}/runlight/.well-known/oauth-protected-resource`);
  const resource = (await (await GET(new Request(metadataUrl!))).json()) as any;
  assert.deepEqual(resource.authorization_servers, [`${origin}/runlight`]);
  assert.equal(resource.resource, `${origin}/runlight/mcp`);
  const server = (await (await GET(new Request(`${origin}/.well-known/oauth-authorization-server/runlight`))).json()) as any;
  assert.equal(server.token_endpoint, `${origin}/runlight/oauth/token`);
  assert.deepEqual(server.code_challenge_methods_supported, ["S256"]);

  // Registration.
  assert.equal((await POST(new Request(`${origin}/runlight/oauth/register`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ redirect_uris: ["http://evil.example/cb"] }) }))).status, 400);
  const registered = await POST(new Request(`${origin}/runlight/oauth/register`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://claude.ai/api/mcp/auth_callback"] }) }));
  assert.equal(registered.status, 201);
  const { client_id } = (await registered.json()) as any;

  // Consent: signed out it says so; signed in it asks; allowing sends a code back.
  const verifier = b64url(randomBytes(32));
  const challenge = b64url(createHash("sha256").update(verifier).digest());
  const params = new URLSearchParams({ response_type: "code", client_id, redirect_uri: "https://claude.ai/api/mcp/auth_callback", code_challenge: challenge, code_challenge_method: "S256", state: "xyz" });
  assert.equal((await GET(new Request(`${origin}/runlight/oauth/authorize?${params}`))).status, 401);
  const wrongRedirect = new URLSearchParams(params);
  wrongRedirect.set("redirect_uri", "https://evil.example/cb");
  assert.equal((await GET(new Request(`${origin}/runlight/oauth/authorize?${wrongRedirect}`, { headers: owner }))).status, 400, "never sends a code to an address the app did not register");
  const consent = await GET(new Request(`${origin}/runlight/oauth/authorize?${params}`, { headers: owner }));
  assert.equal(consent.status, 200);
  const consentPage = await consent.text();
  assert.match(consentPage, /Claude<\/strong> wants to read your Runlight stats/);
  assert.match(consentPage, /sends you back to <strong>claude\.ai<\/strong>/, "the page shows where the answer goes");
  const deny = await POST(new Request(`${origin}/runlight/oauth/authorize`, { method: "POST", headers: { ...owner, "content-type": "application/x-www-form-urlencoded" }, body: `${params}&decision=deny` }));
  assert.match(deny.headers.get("location") ?? "", /error=access_denied&state=xyz/);
  const forged = await POST(new Request(`${origin}/runlight/oauth/authorize`, { method: "POST", headers: { ...owner, origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" }, body: `${params}&decision=allow` }));
  assert.equal(forged.status, 403);
  const allow = await POST(new Request(`${origin}/runlight/oauth/authorize`, { method: "POST", headers: { ...owner, origin, "content-type": "application/x-www-form-urlencoded" }, body: `${params}&decision=allow&site=b` }));
  const back = new URL(allow.headers.get("location") ?? "");
  assert.equal(back.origin + back.pathname, "https://claude.ai/api/mcp/auth_callback");
  assert.equal(back.searchParams.get("state"), "xyz");
  const code = back.searchParams.get("code")!;

  // The token: PKCE checked, the code good once.
  const exchange = (verifierUsed: string) =>
    POST(new Request(`${origin}/runlight/oauth/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "authorization_code", code, client_id, redirect_uri: "https://claude.ai/api/mcp/auth_callback", code_verifier: verifierUsed }).toString() }));
  assert.equal(((await (await exchange("wrong-verifier")).json()) as any).error, "invalid_grant");
  assert.equal(((await (await exchange(verifier)).json()) as any).error, "invalid_grant", "a code that failed once is spent");

  // Again, properly this time.
  const second = await POST(new Request(`${origin}/runlight/oauth/authorize`, { method: "POST", headers: { ...owner, origin, "content-type": "application/x-www-form-urlencoded" }, body: `${params}&decision=allow&site=b` }));
  const code2 = new URL(second.headers.get("location")!).searchParams.get("code")!;
  const issued = await POST(new Request(`${origin}/runlight/oauth/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "authorization_code", code: code2, client_id, redirect_uri: "https://claude.ai/api/mcp/auth_callback", code_verifier: verifier }).toString() }));
  const { access_token, token_type } = (await issued.json()) as any;
  assert.equal(token_type, "Bearer");

  const call = await POST(new Request(`${origin}/runlight/mcp`, { method: "POST", headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_sites", arguments: {} } }) }));
  const sites = JSON.parse(((await call.json()) as any).result.content[0].text).sites;
  assert.deepEqual(sites.map((s: any) => s.id), ["b"], "the token reads only the site chosen at consent");
  const tokens = (await (await GET(new Request(`${origin}/runlight/api/tokens`, { headers: owner }))).json()) as any;
  assert.deepEqual(tokens.tokens.map((t: any) => [t.name, t.site]), [["Claude (OAuth)", "b"]]);
});

test("registrations that never connect are cleared away, so a flood cannot fill the list", async () => {
  let now = Date.UTC(2026, 9, 7, 12);
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }], now: () => now });
  const { POST } = rl.routes({ token: "secret" });
  const register = (name: string) =>
    POST(new Request("https://x.com/runlight/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: name, redirect_uris: ["https://app.example/cb"] }) }));
  for (let i = 0; i < 200; i++) assert.equal((await register(`flood ${i}`)).status, 201);
  // The list is full of apps that never connected, so the oldest makes room.
  assert.equal((await register("Claude")).status, 201);
  assert.equal((await rl.store.settingsStartingWith("oauth-client:")).length, 200);
  // A day later every unused one is gone at the next registration.
  now += 86_400_000 + 1;
  assert.equal((await register("ChatGPT")).status, 201);
  assert.equal((await rl.store.settingsStartingWith("oauth-client:")).length, 1);
});

test("a signed-in viewer is told only an owner can connect, never sent to sign in again", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "a", name: "Site A", hostnames: ["a.com"] }] });
  const { GET, POST } = rl.routes({ signIn: "/login", authorize: (request) => (request.headers.get("cookie") === "viewer" ? "read" : false) });
  const registered = await POST(new Request("https://x.com/runlight/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://claude.ai/cb"] }) }));
  const { client_id } = (await registered.json()) as any;
  const params = new URLSearchParams({ response_type: "code", client_id, redirect_uri: "https://claude.ai/cb", code_challenge: "a".repeat(43), code_challenge_method: "S256" });
  const signedOut = await GET(new Request(`https://x.com/runlight/oauth/authorize?${params}`));
  assert.equal(signedOut.status, 303);
  const viewer = await GET(new Request(`https://x.com/runlight/oauth/authorize?${params}`, { headers: { cookie: "viewer" } }));
  assert.equal(viewer.status, 403);
  assert.match(await viewer.text(), /only an owner of this Runlight can connect Claude/);
});
