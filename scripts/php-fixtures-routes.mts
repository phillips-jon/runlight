// Writes the PHP port's parity fixtures for the routes and OAuth: what the
// TypeScript SDK answers, byte for byte, to requests whose answers carry
// nothing random (the dashboard's page, the tracker, refusals and their codes,
// OAuth's documents and refusals), plus the pure helpers routes.ts and oauth.ts
// export. packages/php/tests/Routes replays them. Run with node --import tsx.
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { runlight } from "../packages/sdk/src/index.ts";
import { sqlite } from "../packages/sdk/src/stores/sqlite.ts";
import { coded, hostName, managePath } from "../packages/sdk/src/routes.ts";
import { resourceMetadataUrl, s256 } from "../packages/sdk/src/oauth.ts";

const dir = new URL("../packages/php/tests/fixtures/", import.meta.url);
mkdirSync(dir, { recursive: true });

const NOW = Date.UTC(2026, 9, 6, 12, 0);

interface Ask {
  method?: string;
  path: string;
  headers?: Record<string, string>;
  body?: string;
}

interface Setup {
  name: string;
  runlight: { site?: Record<string, unknown>; sites?: Array<Record<string, unknown>> };
  routes: Record<string, unknown>;
  asks: Ask[];
}

const json = { "content-type": "application/json" };
const owner = { authorization: "Bearer secret" };
const ownerJson = { ...owner, ...json };

const setups: Setup[] = [
  {
    name: "the dashboard, its assets, and the tracker",
    runlight: { sites: [{ id: "blog", name: "Blog", hostnames: ["blog.example.com"] }] },
    routes: { token: "secret" },
    asks: [
      { path: "/runlight/" },
      { path: "/runlight" },
      { path: "/runlight/?token=secret&site=blog" },
      { path: "/runlight/?token=wrong" },
      { path: "/runlight/s.js" },
      { path: "/runlight/s.js?site=blog" },
      { path: "/runlight/s.js?site=nope" },
      { path: "/runlight/pick.js" },
      { path: "/runlight/pick.js?runlight_ticket=1.aa.bb.cc" },
      { path: "/runlight/assets/app.old.js" },
      { path: "/runlight/assets/locale.xx.0.json" },
      { path: "/runlight/e", method: "OPTIONS" },
      { path: "/runlight/e" },
      { path: "/runlight/mcp" },
      { path: "/runlight/mcp", method: "POST", headers: json, body: "{}" },
      { path: "/runlight/nowhere" },
      { path: "/elsewhere" },
      { path: "/runlight/share/" + "a".repeat(32) },
      { path: "/runlight/share/" + "a".repeat(32), headers: { "accept-language": "fr-CA,fr;q=0.9,en;q=0.8" } },
      { path: "/runlight/share/nope", headers: { "accept-language": "xx, de;q=0.5" } },
      { path: "/runlight/unsubscribe/" + "b".repeat(32) },
      { path: "/runlight/unsubscribe/short", method: "POST" },
    ],
  },
  {
    name: "a dashboard moved, with its links",
    runlight: { site: { name: "Site & <Co>", hostnames: ["example.org"] } },
    routes: { token: "secret", basePath: "/admin/runlight/", signOut: "/out?x=1&y=\"2\"", signIn: "/in", geoCredit: true },
    asks: [{ path: "/admin/runlight/" }, { path: "/admin/runlight/?token=secret" }, { path: "/runlight/" }, { path: "/admin/runlight/api/nope", headers: owner }],
  },
  {
    name: "refusals and their codes",
    runlight: { sites: [{ id: "blog", hostnames: ["blog.example.com"] }, { id: "shop", hostnames: ["shop.example.com"] }] },
    routes: { token: "secret" },
    asks: [
      { path: "/runlight/api/stats" },
      { path: "/runlight/api/stats", headers: { authorization: "Bearer wrong" } },
      { path: "/runlight/api/stats?site=nope", headers: owner },
      { path: "/runlight/api/stats?period=forever", headers: owner },
      { path: "/runlight/api/stats?filter=nope", headers: owner },
      { path: "/runlight/api/stats?filter=page:like:x", headers: owner },
      { path: `/runlight/api/stats?${Array.from({ length: 7 }, () => "filter=page:is:/").join("&")}`, headers: owner },
      { path: "/runlight/api/stats?compare=sideways", headers: owner },
      { path: "/runlight/api/stats?compare=custom", headers: owner },
      { path: "/runlight/api/breakdown?dimension=shoe_size", headers: owner },
      { path: "/runlight/api/event-props", headers: owner },
      { path: "/runlight/api/event-props?event=Signup&key=a%22b", headers: owner },
      { path: "/runlight/api/goals", method: "POST", headers: { ...owner, "content-type": "text/plain" }, body: "{}" },
      { path: "/runlight/api/goals", method: "POST", headers: { "content-type": "text/plain; application/json" }, body: "{}" },
      { path: "/runlight/api/goals?site=blog", method: "POST", headers: ownerJson, body: "[]" },
      { path: "/runlight/api/goals?site=blog", method: "POST", headers: ownerJson, body: "not json" },
      { path: "/runlight/api/goals?site=blog", method: "POST", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/goals/nope?site=blog", method: "DELETE", headers: owner },
      { path: "/runlight/api/funnels/" + "c".repeat(24) + "?site=blog", method: "DELETE", headers: owner },
      { path: "/runlight/api/shares/nope?site=blog", method: "DELETE", headers: owner },
      { path: "/runlight/api/reports/nope?site=blog", method: "DELETE", headers: owner },
      { path: "/runlight/api/tokens", method: "POST", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/tokens", method: "POST", headers: ownerJson, body: JSON.stringify({ name: "x", site: "nope" }) },
      { path: "/runlight/api/tokens", method: "POST", headers: ownerJson, body: JSON.stringify({ name: "x", scope: "manage" }) },
      { path: "/runlight/api/tokens/" + "d".repeat(24), method: "DELETE", headers: owner },
      { path: "/runlight/api/token", headers: owner },
      { path: "/runlight/api/sites", method: "PUT", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/sites/blog", method: "PATCH", headers: ownerJson, body: JSON.stringify({ name: "" }) },
      { path: "/runlight/api/sites/blog", method: "PATCH", headers: ownerJson, body: JSON.stringify({ timezone: "Mars/Olympus" }) },
      { path: "/runlight/api/sites/blog", method: "PATCH", headers: ownerJson, body: JSON.stringify({ retentionMonths: 7 }) },
      { path: "/runlight/api/sites/connect", method: "POST", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/mail/test", method: "POST", headers: ownerJson, body: JSON.stringify({ to: "nobody" }) },
      { path: "/runlight/api/mail/test", method: "POST", headers: ownerJson, body: JSON.stringify({ to: "me@example.com" }) },
      { path: "/runlight/api/mail", method: "PATCH", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/reports?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ email: "nope" }) },
      { path: "/runlight/api/pick?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ origin: "javascript:alert(1)" }) },
      { path: "/runlight/api/link-domains?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ domain: "not a domain" }) },
      { path: "/runlight/api/link-domains?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ domain: "go.example.test" }) },
      { path: "/runlight/api/link-domains?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ domain: "10.0.0.1.nip.io" }) },
      { path: "/runlight/api/link-domains/go.example.com/check?site=blog", headers: owner },
      { path: "/runlight/api/links/import?site=blog", method: "POST", headers: ownerJson, body: JSON.stringify({ rows: "no" }) },
      { path: "/runlight/api/links/" + "e".repeat(24) + "?site=blog", headers: owner },
      { path: "/runlight/api/assistant/limits", method: "PUT", headers: ownerJson, body: JSON.stringify({ viewerDaily: 1.5 }) },
      { path: "/runlight/api/assistant/chat", method: "POST", headers: ownerJson, body: "{}" },
      { path: "/runlight/api/assistant/chat", method: "POST", headers: { ...ownerJson, "x-runlight-share": "x" }, body: "{}" },
      { path: "/runlight/api/observe", method: "POST", headers: json, body: "{}" },
      { path: "/runlight/api/observe", method: "POST", headers: { authorization: "Bearer nope", ...json }, body: JSON.stringify({ url: "https://blog.example.com/" }) },
      { path: "/runlight/api/observe", method: "POST", headers: ownerJson, body: JSON.stringify({ url: "ftp://blog.example.com/" }) },
      { path: "/runlight/api/observe", method: "POST", headers: ownerJson, body: JSON.stringify({ fetches: Array.from({ length: 501 }, () => ({})) }) },
      { path: "/runlight/api/stats", headers: { "x-runlight-share": "nope" } },
      { path: "/runlight/api/check", method: "POST", headers: json },
    ],
  },
  {
    name: "an install with no token",
    runlight: { site: { hostnames: ["example.com"] } },
    routes: { token: "" },
    asks: [{ path: "/runlight/api/stats" }, { path: "/runlight/api/tokens", method: "POST", headers: json, body: "{}" }, { path: "/runlight/mcp", method: "POST", headers: json, body: "{}" }],
  },
  {
    name: "OAuth's documents and refusals",
    runlight: { site: { hostnames: ["example.com"] } },
    routes: { token: "secret" },
    asks: [
      { path: "/.well-known/oauth-protected-resource" },
      { path: "/.well-known/oauth-authorization-server/runlight" },
      { path: "/.well-known/openid-configuration" },
      { path: "/runlight/.well-known/oauth-protected-resource" },
      { path: "/runlight/oauth/token", method: "OPTIONS" },
      { path: "/runlight/oauth/register", method: "POST", headers: json, body: JSON.stringify({ redirect_uris: ["http://evil.example/cb", 5] }) },
      { path: "/runlight/oauth/register", method: "POST", headers: json, body: "nope" },
      { path: "/runlight/oauth/authorize?client_id=nope&redirect_uri=https://app.example/cb" },
      { path: "/runlight/oauth/authorize?client_id=" + "f".repeat(32) },
      { path: "/runlight/oauth/token", method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "grant_type=password" },
      { path: "/runlight/oauth/token", method: "POST", headers: json, body: JSON.stringify({ grant_type: "authorization_code", code: "nope" }) },
      { path: "/runlight/oauth/token", method: "POST", headers: json, body: "[1,2]" },
      { path: "/runlight/oauth/token", method: "GET" },
      { path: "/runlight/oauth/nowhere" },
    ],
  },
];

const textOf = (bytes: Buffer) => (bytes.length > 20_000 ? { sha256: createHash("sha256").update(bytes).digest("hex"), length: bytes.length } : { text: bytes.toString("utf8") });

const exchanges: unknown[] = [];
for (const setup of setups) {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), now: () => NOW, ...setup.runlight });
  const routes = rl.routes(setup.routes as never);
  const answers: unknown[] = [];
  for (const ask of setup.asks) {
    const init: RequestInit = { method: ask.method ?? "GET", headers: ask.headers ?? {} };
    if (ask.body !== undefined) init.body = ask.body;
    const response = await routes.handler(new Request(`https://example.com${ask.path}`, init));
    const headers: Record<string, string | string[]> = {};
    response.headers.forEach((value, name) => {
      if (name !== "set-cookie") headers[name] = value;
    });
    const cookies = response.headers.getSetCookie();
    if (cookies.length) headers["set-cookie"] = cookies;
    answers.push({ ask, status: response.status, headers, ...textOf(Buffer.from(await response.arrayBuffer())) });
  }
  exchanges.push({ name: setup.name, runlight: setup.runlight, routes: setup.routes, answers });
}

const codedCases: Array<[string, string, number, Record<string, string> | undefined, Record<string, string>]> = [
  ["Unauthorized", "unauthorized", 401, undefined, {}],
  ["Unknown site", "unknown_site", 404, {}, {}],
  ['Bad filter "x". Use dimension:is|not|contains:value.', "filter_bad", 400, { filter: "x" }, {}],
  ["No icon", "icon_none", 404, undefined, { "cache-control": "private, max-age=3600" }],
  ["Ünïcödé / slashes   and \"quotes\"", "x", 418, { a: "é/</script>", b: "" }, {}],
];
const codedAnswers = [];
for (const [error, code, status, params, headers] of codedCases) {
  const response = coded(error, code, status, params, headers);
  const out: Record<string, string> = {};
  response.headers.forEach((value, name) => (out[name] = value));
  codedAnswers.push({ args: [error, code, status, params ?? null, headers], status: response.status, headers: out, text: await response.text() });
}

const hosts = ["Example.COM", "example.com:8080", "www.example.com.", "WWW.Example.com:443, proxy.example", "[::1]:3000", "[::1", "a.example...", " spaced.example ", "", "www.", "example.com:", "ÉXAMPLE.com"];
const manage = [
  ["GET", "/api/links"], ["POST", "/api/links/import"], ["POST", "/api/links/import/dub"], ["DELETE", "/api/link-domains/x"], ["GET", "/api/reports"],
  ["POST", "/api/goals"], ["PATCH", "/api/funnels/abc"], ["GET", "/api/shares"], ["POST", "/api/pick"], ["GET", "/api/pick"], ["GET", "/api/mail"],
  ["PUT", "/api/mail"], ["PATCH", "/api/sites/blog"], ["DELETE", "/api/sites/blog"], ["PATCH", "/api/sites/blog/x"], ["GET", "/api/stats"], ["GET", "/api/linksx"],
  ["GET", "/api/tokens"],
];
const verifiers = ["", "a", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "ünïcode verifier ✓", "x".repeat(128)];

writeFileSync(
  new URL("routes.json", dir),
  `${JSON.stringify({
    now: NOW,
    exchanges,
    coded: codedAnswers,
    hostName: hosts.map((h) => [h, hostName(h)]),
    managePath: manage.map(([m, p]) => [m, p, managePath(m!, p!)]),
    s256: await Promise.all(verifiers.map(async (v) => [v, await s256(v)])),
    resourceMetadataUrl: [["https://example.com", "/runlight", resourceMetadataUrl("https://example.com", "/runlight")], ["http://localhost:3000", "", resourceMetadataUrl("http://localhost:3000", "")]],
  })}\n`,
);
console.log("php-fixtures-routes: written");
