import assert from "node:assert/strict";
import { after, test } from "node:test";
import { journeys } from "../src/journeys.js";
import { STORES, cleanup, setup } from "./helpers.js";

after(cleanup);

const rows = (visits: Record<string, string[]>) => Object.entries(visits).flatMap(([session, pages]) => pages.map((path) => ({ session, path })));

test("journeys line paths up by step, with flows, and follow a start, an end, and one page", () => {
  const data = rows({
    a: ["/", "/pricing", "/signup"],
    b: ["/", "/pricing", "/pricing", "/docs"],
    c: ["/", "/blog"],
    d: ["/blog", "/", "/pricing"],
    e: ["/docs"],
  });
  const all = journeys(data, { steps: 3 });
  assert.equal(all.visits, 5);
  assert.deepEqual(all.columns[0], { items: [{ value: "/", visits: 3 }, { value: "/blog", visits: 1 }, { value: "/docs", visits: 1 }], visits: 5, left: 1 });
  assert.deepEqual(all.columns[1]!.items[0], { value: "/pricing", visits: 2 }, "a refresh counts once");
  assert.deepEqual(all.links.filter((l) => l.step === 0 && l.from === "/").map((l) => [l.to, l.visits]), [["/pricing", 2], ["/blog", 1]]);
  assert.equal(all.paths.length, 5);
  // With two steps, visits a, b, and d go on to a third page, so only c went no further than step two.
  const two = journeys(data, { steps: 2 });
  assert.deepEqual([two.columns[1]!.visits, two.columns[1]!.left], [4, 1], "the last step counts only visits that ended there");
  assert.deepEqual(all.paths[0], { pages: ["/", "/blog"], visits: 1 }, "ties in a fixed order");

  const fromPricing = journeys(data, { steps: 3, start: "/pricing" });
  assert.equal(fromPricing.visits, 3, "visits that reached /pricing, from there on");
  assert.deepEqual(fromPricing.columns[0]!.items, [{ value: "/pricing", visits: 3 }]);

  const toSignup = journeys(data, { steps: 4, end: "/signup" });
  assert.deepEqual(toSignup.paths, [{ pages: ["/", "/pricing", "/signup"], visits: 1 }]);

  const through = journeys(data, { steps: 3, through: { step: 1, value: "/blog" } });
  assert.equal(through.visits, 1);
});

for (const kind of STORES) {
  test(`${kind}: /api/journeys reads each visit's pages in order`, async () => {
    const t = setup(kind, { site: { hostnames: ["example.com"] } });
    const visit = async (ip: string, pages: string[]) => {
      for (const [i, page] of pages.entries()) {
        await t.send({ k: "pageview", u: `https://example.com${page}`, i: `p${ip.replace(/\D/g, "")}x${i}` }, { ip });
        t.advance(10_000);
      }
    };
    await visit("203.0.113.1", ["/", "/pricing", "/signup"]);
    await visit("203.0.113.2", ["/", "/pricing"]);
    await visit("203.0.113.3", ["/blog"]);
    const answer = await t.get("/api/journeys?period=today&steps=3");
    assert.equal(answer.visits, 3);
    assert.deepEqual(answer.columns.map((c: any) => c.items.map((x: any) => `${x.value} ${x.visits}`)), [["/ 2", "/blog 1"], ["/pricing 2"], ["/signup 1"]]);
    assert.deepEqual((await t.get("/api/journeys?period=today&steps=3&end=/signup")).paths, [{ pages: ["/", "/pricing", "/signup"], visits: 1 }]);
  });
}
