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
  assert.match(await consent.text(), /Claude<\/strong> wants to read your Runlight stats/);
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
