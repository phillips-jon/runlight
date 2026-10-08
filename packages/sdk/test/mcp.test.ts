import assert from "node:assert/strict";
import { after, test } from "node:test";
import { TOOLS } from "../src/mcp.js";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

const SITES = [
  { id: "a", name: "Site A", hostnames: ["a.com"], timezone: "UTC" },
  { id: "b", name: "Site B", hostnames: ["b.com"], timezone: "UTC" },
];

for (const kind of STORES) {
  test(`${kind}: API tokens read, cannot write, can be limited to a site, and stop at revocation`, async () => {
    const t = setup(kind, { sites: SITES });
    const { GET, POST, DELETE } = t.routes;
    const owner = { authorization: "Bearer secret", "content-type": "application/json" };
    const url = (path: string) => `https://example.com/runlight${path}`;

    const make = async (body: unknown) => {
      const answer = await POST(new Request(url("/api/tokens"), { method: "POST", headers: owner, body: JSON.stringify(body) }));
      return { status: answer.status, body: (await answer.json()) as any };
    };
    assert.equal((await make({ name: "" })).status, 400);
    assert.equal((await make({ name: "X", site: "nope" })).status, 404);
    const all = await make({ name: "Claude" });
    assert.equal(all.status, 201);
    assert.match(all.body.secret, /^rl_[a-f0-9]{40}$/);
    assert.equal(all.body.token.hint, all.body.secret.slice(-4));
    const one = (await make({ name: "Client B", site: "b" })).body;

    const listed = (await (await GET(new Request(url("/api/tokens"), { headers: owner }))).json()) as any;
    assert.deepEqual(listed.tokens.map((x: any) => x.name).sort(), ["Claude", "Client B"]);
    assert.ok(!JSON.stringify(listed).includes(all.body.secret), "a token is shown once, never listed");
    assert.ok(!("hash" in listed.tokens[0]), "nor its hash");

    await t.send({ k: "pageview", u: "https://a.com/", i: "p1" });
    await t.send({ k: "pageview", u: "https://b.com/", i: "p2" }, { ip: "203.0.113.2" });

    const as = (secret: string) => ({ authorization: `Bearer ${secret}`, "content-type": "application/json" });
    const stats = await GET(new Request(url("/api/stats?site=a&period=today"), { headers: as(all.body.secret) }));
    assert.equal(stats.status, 200);
    assert.equal(((await stats.json()) as any).stats.visitors, 1);
    assert.equal((await GET(new Request(url("/api/links?site=a"), { headers: as(all.body.secret) }))).status, 200, "links can be read");

    // Nothing that writes, and nothing that manages access.
    assert.equal((await POST(new Request(url("/api/goals?site=a"), { method: "POST", headers: as(all.body.secret), body: JSON.stringify({ name: "G", kind: "page", match: "/" }) }))).status, 403);
    assert.equal((await POST(new Request(url("/api/links?site=a"), { method: "POST", headers: as(all.body.secret), body: JSON.stringify({ url: "https://x.com" }) }))).status, 403);
    assert.equal((await GET(new Request(url("/api/tokens"), { headers: as(all.body.secret) }))).status, 401, "a token cannot list tokens");
    assert.equal((await GET(new Request(url("/api/shares?site=a"), { headers: as(all.body.secret) }))).status, 401);
    assert.equal((await GET(new Request(url("/api/mail"), { headers: as(all.body.secret) }))).status, 401);

    // A site's token sees only that site.
    const sites = (await (await GET(new Request(url("/api/sites"), { headers: as(one.secret) }))).json()) as any;
    assert.deepEqual(sites.sites.map((s: any) => s.id), ["b"]);
    assert.equal(((await (await GET(new Request(url("/api/stats?period=today"), { headers: as(one.secret) }))).json()) as any).site, "b", "and defaults to it");
    assert.equal((await GET(new Request(url("/api/stats?site=a"), { headers: as(one.secret) }))).status, 404);
    assert.equal((await GET(new Request(url("/api/links?site=a"), { headers: as(one.secret) }))).status, 404);

    const used = (await (await GET(new Request(url("/api/tokens"), { headers: owner }))).json()) as any;
    assert.equal(used.tokens.find((x: any) => x.name === "Claude").lastUsedAt, t.now);

    assert.equal((await DELETE(new Request(url(`/api/tokens/${all.body.token.id}`), { method: "DELETE", headers: as(all.body.secret) }))).status, 403, "a token cannot revoke");
    assert.equal((await DELETE(new Request(url(`/api/tokens/${all.body.token.id}`), { method: "DELETE", headers: owner }))).status, 200);
    assert.equal((await DELETE(new Request(url(`/api/tokens/${all.body.token.id}`), { method: "DELETE", headers: owner }))).status, 404);
    assert.equal((await GET(new Request(url("/api/stats?site=a"), { headers: as(all.body.secret) }))).status, 401, "revoked at once");
  });

  test(`${kind}: the MCP server answers initialize, lists its tools, and calls them with the token's reach`, async () => {
    const t = setup(kind, { sites: SITES });
    const { GET, POST } = t.routes;
    const owner = { authorization: "Bearer secret", "content-type": "application/json" };
    const made = await POST(new Request("https://example.com/runlight/api/tokens", { method: "POST", headers: owner, body: JSON.stringify({ name: "B only", site: "b" }) }));
    const { secret } = (await made.json()) as { secret: string };
    await t.send({ k: "pageview", u: "https://b.com/pricing", r: "https://news.ycombinator.com/", i: "p1" });
    await t.send({ k: "pageview", u: "https://a.com/", i: "p2" });

    let id = 0;
    const rpc = async (method: string, params?: unknown, auth = secret) => {
      const answer = await POST(
        new Request("https://example.com/runlight/mcp", {
          method: "POST",
          headers: { authorization: `Bearer ${auth}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
          body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, ...(params ? { params } : {}) }),
        }),
      );
      return { status: answer.status, headers: answer.headers, body: answer.status === 202 ? null : ((await answer.json()) as any) };
    };

    const refused = await rpc("initialize", {}, "rl_" + "0".repeat(40));
    assert.equal(refused.status, 401);
    assert.match(refused.headers.get("www-authenticate") ?? "", /^Bearer/);
    assert.equal((await GET(new Request("https://example.com/runlight/mcp", { headers: owner }))).status, 405, "no event stream");

    const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    assert.equal(init.body.result.protocolVersion, "2025-06-18");
    assert.equal(init.body.result.serverInfo.name, "runlight");
    assert.ok(init.body.result.capabilities.tools);
    assert.equal((await rpc("initialize", { protocolVersion: "1999-01-01" })).body.result.protocolVersion, "2025-11-25", "an unknown version gets the newest");

    const note = await POST(
      new Request("https://example.com/runlight/mcp", { method: "POST", headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) }),
    );
    assert.equal(note.status, 202);

    const listed = await rpc("tools/list");
    assert.deepEqual(listed.body.result.tools.map((x: any) => x.name), TOOLS.map((x) => x.name));
    for (const tool of listed.body.result.tools) assert.equal(tool.annotations.readOnlyHint, true);

    const call = async (name: string, args: unknown = {}) => {
      const result = (await rpc("tools/call", { name, arguments: args })).body.result;
      return { ...result, data: result.isError ? null : JSON.parse(result.content[0].text) };
    };
    assert.deepEqual((await call("list_sites")).data.sites.map((s: any) => s.id), ["b"]);
    const stats = await call("get_stats", { period: "today" });
    assert.equal(stats.data.site, "b");
    assert.equal(stats.data.stats.pageviews, 1);
    assert.equal((await call("get_stats", { site: "a" })).isError, true, "another site is out of reach");
    const sources = await call("get_breakdown", { period: "today", dimension: "source", limit: 500 });
    assert.equal(sources.data.rows[0].value, "Hacker News");
    const filtered = await call("get_stats", { period: "today", filters: ["page:is:/nowhere"] });
    assert.equal(filtered.data.stats.pageviews, 0);
    const bad = await call("get_stats", { filters: ["nonsense"] });
    assert.equal(bad.isError, true);
    assert.match(bad.content[0].text, /Bad filter/);
    const times = await call("get_visit_times", { period: "today" });
    assert.equal(times.data.grid.length, 7);
    assert.ok(!("cells" in times.data), "trimmed to what an assistant needs");
    assert.equal((await call("list_goals", { period: "today" })).data.goals.length, 0);
    assert.equal((await call("get_goal", { goal_id: "f".repeat(24) })).isError, true);
    assert.equal((await call("list_links")).isError, undefined);
    assert.equal((await call("get_realtime")).isError, undefined);

    assert.equal((await rpc("tools/call", { name: "drop_tables" })).body.error.code, -32602);
    assert.equal((await rpc("resources/list")).body.error.code, -32601);
    assert.deepEqual((await rpc("ping")).body.result, {});

    // The owner's own token works too, across every site.
    assert.deepEqual(
      JSON.parse((await rpc("tools/call", { name: "list_sites", arguments: {} }, "secret")).body.result.content[0].text).sites.map((s: any) => s.id),
      ["a", "b"],
    );
  });
}
