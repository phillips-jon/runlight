import assert from "node:assert/strict";
import { after, test } from "node:test";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

for (const kind of STORES) {
  test(`${kind}: a filter picks visits, and the numbers describe those whole visits`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"], timezone: "UTC" } });
    t.advance(-3 * 3_600_000);
    // Visit A: two pages and a Signup. Visit B: one page, no Signup.
    await t.send({ k: "pageview", u: "https://example.com/", i: "a1" }, { ip: "203.0.113.1" });
    t.advance(30_000);
    await t.send({ k: "pageview", u: "https://example.com/pricing", i: "a2" }, { ip: "203.0.113.1" });
    t.advance(30_000);
    await t.send({ k: "event", u: "https://example.com/pricing", n: "Signup" }, { ip: "203.0.113.1" });
    await t.send({ k: "pageview", u: "https://example.com/blog", i: "b1" }, { ip: "203.0.113.2" });
    t.advance(3 * 3_600_000);
    const stats = async (filter: string) => (await t.get(`/api/stats?period=today&compare=off&${filter}`)).stats;

    const signup = await stats("filter=event:is:Signup");
    assert.deepEqual([signup.visitors, signup.visits, signup.pageviews], [1, 1, 2], "the visits with a Signup, and all their pageviews");
    const pricing = await stats("filter=page:is:/pricing");
    assert.deepEqual([pricing.visits, pricing.pageviews], [1, 1], "a page filter counts that page's views");
    const both = await stats("filter=page:is:/pricing&filter=event:is:Signup");
    assert.equal(both.visits, 1, "a page and an event in the same visit");
    const without = await stats("filter=event:not:Signup");
    assert.deepEqual([without.visits, without.pageviews], [1, 1], "is not means visits that never had one");

    const points = (await t.get(`/api/series?period=today&compare=off&filter=event:is:Signup`)).points as Array<{ visits: number; pageviews: number }>;
    assert.deepEqual([points.reduce((n, p) => n + p.visits, 0), points.reduce((n, p) => n + p.pageviews, 0)], [1, 2], "the chart agrees");
    const pages = (await t.get(`/api/breakdown?period=today&dimension=page&filter=event:is:Signup`)).rows as Array<{ value: string }>;
    assert.deepEqual(pages.map((r) => r.value).sort(), ["/", "/pricing"], "the pages of the visits that signed up");
    const events = (await t.get(`/api/breakdown?period=today&dimension=event&filter=page:is:/pricing`)).rows as Array<{ value: string }>;
    assert.deepEqual(events.map((r) => r.value), ["Signup"]);
  });
}
