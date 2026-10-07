import assert from "node:assert/strict";
import { after, describe, test } from "node:test";
import { STORES, cleanup, setup, type StoreKind } from "./helpers.js";

after(cleanup);

for (const kind of STORES) describe(kind, () => suite(kind));

function suite(kind: StoreKind) {
  test("an event's properties and their values, filtered like everything else", async () => {
    const t = setup(kind);
    const out = (url: string, ip: string, path = "/") => t.send({ k: "event", u: `https://example.com${path}`, n: "Outbound link", p: { url } }, { ip });
    await out("https://github.com/x", "203.0.113.1");
    await out("https://github.com/x", "203.0.113.2", "/blog");
    await out("https://news.ycombinator.com/", "203.0.113.1");
    await t.send({ k: "event", u: "https://example.com/missing", n: "404", p: { path: "/missing" } });
    await t.send({ k: "event", u: "https://example.com/", n: "Signup", p: { plan: "pro", seats: 3 } });
    await t.send({ k: "event", u: "https://example.com/", n: "Signup", p: { plan: "team" } });

    const links = await t.get("/api/event-props?period=today&event=Outbound%20link");
    assert.deepEqual(links.keys, [{ key: "url", events: 3 }]);
    assert.equal(links.key, "url");
    assert.deepEqual(links.rows, [
      { value: "https://github.com/x", events: 2, visitors: 2 },
      { value: "https://news.ycombinator.com/", events: 1, visitors: 1 },
    ]);

    const signup = await t.get("/api/event-props?period=today&event=Signup");
    assert.deepEqual(signup.keys.map((k: { key: string }) => k.key), ["plan", "seats"]);
    assert.deepEqual((await t.get("/api/event-props?period=today&event=Signup&key=seats")).rows, [{ value: "3", events: 1, visitors: 1 }]);

    const blog = await t.get("/api/event-props?period=today&event=Outbound%20link&filter=page:is:/blog");
    assert.deepEqual(blog.rows.map((r: { value: string }) => r.value), ["https://github.com/x"]);

    const none = await t.get("/api/event-props?period=today&event=Nothing");
    assert.deepEqual({ keys: none.keys, key: none.key, rows: none.rows }, { keys: [], key: null, rows: [] });
    const bad = await t.routes.GET(new Request('https://example.com/runlight/api/event-props?period=today&event=Signup&key=a"b', { headers: { authorization: "Bearer secret" } }));
    assert.equal(bad.status, 400);
  });
}
