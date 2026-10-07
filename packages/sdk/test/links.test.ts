import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { CHROME_MAC, STORES, cleanup, setup, type StoreKind } from "./helpers.js";

after(cleanup);

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  const json = (method: string, body: unknown) => ({
    method,
    body: JSON.stringify(body),
    headers: { "content-type": "application/json", authorization: "Bearer secret" },
  });

  test("create, follow, and count a short link", async () => {
    const t = setup(kind);
    const created = await t.routes.POST(new Request("https://example.com/runlight/api/links", json("POST", { url: "https://thedailypreset.com/presets/golden?ref=x" })));
    assert.equal(created.status, 201);
    const { link } = await created.json();
    assert.match(link.slug, /^[a-z2-9]{6}$/);
    assert.equal(link.name, "thedailypreset.com/presets/golden");

    const follow = t.rl.linkHandler();
    const go = (path: string, headers: Record<string, string> = {}) =>
      follow(new Request(`https://example.com${path}`, { headers: { "user-agent": CHROME_MAC, "x-forwarded-for": "203.0.113.9", ...headers } }));
    const response = await go(`/go/${link.slug}?utm_source=newsletter&utm_medium=email`, { referer: "https://mail.google.com/" });
    assert.equal(response.status, 302);
    assert.equal(response.headers.get("location"), "https://thedailypreset.com/presets/golden?ref=x");
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal((await go("/go/nope")).status, 404);
    // Link previews and crawlers are sent on but not counted.
    assert.equal((await go(`/go/${link.slug}`, { "user-agent": "facebookexternalhit/1.1" })).status, 302);

    const list = await t.get("/api/links?period=today");
    assert.equal(list.prefix, "https://example.com/go");
    assert.equal(list.links[0].clicks, 1);
    assert.equal(list.links[0].visitors, 1);

    const stats = await t.get(`/api/links/${link.id}?period=today`);
    assert.equal(stats.clicks, 1);
    assert.equal(stats.series.length, 24);
    assert.deepEqual(stats.sources, [{ value: "Newsletter", visitors: 1, events: 1 }]);

    // Clicks are not visits: the site's own numbers do not move.
    const { stats: site } = await t.get("/api/stats?period=today");
    assert.equal(site.visitors, 0);
    assert.equal(site.pageviews, 0);
  });

  test("slugs are checked, unique per domain, and freed by deleting", async () => {
    const t = setup(kind);
    const post = (body: unknown) => t.routes.POST(new Request("https://example.com/runlight/api/links", json("POST", body)));
    assert.equal((await post({ url: "https://a.com", slug: "launch" })).status, 201);
    const clash = await post({ url: "https://b.com", slug: "launch" });
    assert.equal(clash.status, 400);
    assert.match((await clash.json()).error, /taken/);
    assert.equal((await post({ url: "https://b.com", slug: "has space" })).status, 400);
    assert.equal((await post({ url: "javascript:alert(1)" })).status, 400);
    assert.equal((await post({ url: "https://b.com", domain: "t.unknown.com" })).status, 400, "the domain must be added first");

    const { links } = await t.get("/api/links?period=today");
    const id = links[0].id;
    const renamed = await t.routes.PATCH(new Request(`https://example.com/runlight/api/links/${id}`, json("PATCH", { slug: "launch-2", name: "Launch" })));
    assert.equal(renamed.status, 200);
    assert.equal((await renamed.json()).link.slug, "launch-2");
    assert.equal((await t.routes.DELETE(new Request(`https://example.com/runlight/api/links/${id}`, json("DELETE", {})))).status, 200);
    assert.equal((await post({ url: "https://c.com", slug: "launch-2" })).status, 201, "a deleted link's slug is free again");
    assert.equal((await t.get("/api/links?period=today")).links.length, 1);
  });

  test("custom link domains answer at their root, and only for their own links", async () => {
    const t = setup(kind);
    const addDomain = await t.routes.POST(new Request("https://example.com/runlight/api/link-domains", json("POST", { domain: "https://t.thedailypreset.com/" })));
    assert.equal(addDomain.status, 201);
    assert.deepEqual((await t.get("/api/link-domains")).domains, ["t.thedailypreset.com"]);
    await t.routes.POST(new Request("https://example.com/runlight/api/links", json("POST", { url: "https://thedailypreset.com/a", slug: "a", domain: "t.thedailypreset.com" })));
    await t.routes.POST(new Request("https://example.com/runlight/api/links", json("POST", { url: "https://example.com/b", slug: "b" })));

    const at = (host: string, path: string) =>
      t.rl.linkDomainResponse(new Request(`https://${host}${path}`, { headers: { host, "user-agent": CHROME_MAC } }));
    assert.equal((await at("t.thedailypreset.com", "/a"))?.headers.get("location"), "https://thedailypreset.com/a");
    assert.equal((await at("t.thedailypreset.com", "/b"))?.status, 404, "the main site's links are not on the link domain");
    assert.equal(await at("example.com", "/a"), null, "other hosts carry on as normal");
    assert.equal((await t.rl.linkHandler()(new Request("https://example.com/go/a", { headers: { "user-agent": CHROME_MAC } }))).status, 404);

    const remove = await t.routes.DELETE(new Request("https://example.com/runlight/api/link-domains/t.thedailypreset.com", json("DELETE", {})));
    assert.equal(remove.status, 409, "a domain with live links stays");
  });

  test("CSV rows in the Umami fork's format import, and bad rows say why", async () => {
    const t = setup(kind);
    await t.routes.POST(new Request("https://example.com/runlight/api/link-domains", json("POST", { domain: "t.thedailypreset.com" })));
    const result = await t.routes.POST(
      new Request(
        "https://example.com/runlight/api/links/import",
        json("POST", {
          rows: [
            { link_name: "Golden hour", destination_url: "https://thedailypreset.com/golden", link_slug: "golden", tracking_domain: "t.thedailypreset.com" },
            { name: "Plain", url: "https://example.com/plain" },
            { name: "Broken", url: "not a url" },
            { name: "Duplicate", url: "https://example.com/x", slug: "golden", domain: "t.thedailypreset.com" },
          ],
        }),
      ),
    );
    const body = await result.json();
    assert.equal(body.created, 2);
    assert.deepEqual(body.failed.map((f: { row: number }) => f.row), [3, 4]);
    const { links } = await t.get("/api/links?period=today");
    assert.equal(links.length, 2);
    assert.ok(links.some((l: { domain: string; slug: string }) => l.domain === "t.thedailypreset.com" && l.slug === "golden"));
  });

  test("writes need JSON and the token", async () => {
    const t = setup(kind);
    const form = await t.routes.POST(
      new Request("https://example.com/runlight/api/links", { method: "POST", body: "url=https://a.com", headers: { "content-type": "application/x-www-form-urlencoded", authorization: "Bearer secret" } }),
    );
    assert.equal(form.status, 415);
    const anonymous = await t.routes.POST(new Request("https://example.com/runlight/api/links", { method: "POST", body: "{}", headers: { "content-type": "application/json" } }));
    assert.equal(anonymous.status, 401);
  });
}
