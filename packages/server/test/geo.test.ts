import assert from "node:assert/strict";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { Geo, lookupFrom } from "../src/geo.js";

test("DB-IP records become a country code, a readable region, and a plain city", () => {
  const records: Record<string, unknown> = {
    "24.114.0.1": { country: { iso_code: "CA" }, subdivisions: [{ names: { en: "Ontario" } }], city: { names: { en: "Toronto (Old Toronto)" } } },
    "8.8.8.8": { country: { iso_code: "US" }, subdivisions: [{ iso_code: "CA", names: { en: "California" } }], city: { names: { en: "Mountain View" } } },
    "10.0.0.1": null,
  };
  const lookup = lookupFrom({ get: (ip: string) => records[ip] ?? null } as never);
  assert.deepEqual(lookup("24.114.0.1"), { country: "CA", region: "Ontario", city: "Toronto" });
  assert.deepEqual(lookup("8.8.8.8"), { country: "US", region: "CA", city: "Mountain View" }, "a code wins when the database has one");
  assert.equal(lookup("10.0.0.1"), null);
  assert.equal(lookupFrom({ get: () => { throw new Error("bad address"); } } as never)("nonsense"), null);
});

test("a failed download leaves lookups empty and the folder clean, and is tried again later", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "rl-geo-"));
  const asked: string[] = [];
  const lines: string[] = [];
  const geo = new Geo(dir, "city", (line) => lines.push(line), (async (url: string) => {
    asked.push(url);
    return new Response("nope", { status: 404 });
  }) as never);
  await geo.refresh(Date.UTC(2026, 9, 1, 3));
  assert.deepEqual(asked, [
    "https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz",
    "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz",
  ], "early in a month, last month's release stands in");
  assert.equal(await geo.lookup("8.8.8.8"), null);
  assert.deepEqual(readdirSync(dir), []);
  await geo.refresh(Date.UTC(2026, 9, 1, 4));
  assert.equal(asked.length, 4, "tried again on the next check");
});
