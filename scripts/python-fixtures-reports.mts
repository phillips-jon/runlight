// Email reports over a database, as the TypeScript SDK builds them. Opens a copy of
// packages/php/tests/fixtures/store.db (the database scripts/php-fixtures-store.mts builds) and writes
// buildReport's subject, HTML, and text for each site, frequency, and language into
// packages/python/tests/fixtures/reports-store.json, so the Python port builds the same reports over the same rows
// without its core.
//
// Run with: node --import tsx scripts/python-fixtures-reports.mts
import { copyFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { buildReport, lastPeriod } from "../packages/sdk/src/reports.js";
import type { Runlight } from "../packages/sdk/src/runlight.js";
import { sqlite } from "../packages/sdk/src/stores/sqlite.js";

const root = path.resolve(import.meta.dirname, "..");
const folder = path.join(tmpdir(), `runlight-reports-${process.pid}`);
mkdirSync(folder, { recursive: true });
const file = path.join(folder, "store.db");
copyFileSync(path.join(root, "packages/php/tests/fixtures/store.db"), file);
const store = sqlite({ path: file });
await store.migrate();

const runlight = { store } as unknown as Runlight;
const cases: unknown[] = [];
for (const site of await store.sites()) {
  for (const [frequency, now] of [
    ["weekly", Date.UTC(2026, 9, 6, 12)],
    ["monthly", Date.UTC(2026, 9, 3, 12)],
    ["monthly", Date.UTC(2026, 10, 2, 12)],
  ] as const) {
    const period = lastPeriod(frequency, now, site.timezone);
    for (const lang of ["en", "de", "es", "fr", "xx"]) {
      const links = { dashboard: `https://stats.example.com/runlight/?site=${site.id}`, unsubscribe: "https://stats.example.com/runlight/unsubscribe/abc" };
      cases.push({ site, frequency, period, lang, links, report: await buildReport(runlight, site, frequency, period, lang, links) });
    }
  }
}
await store.close();
rmSync(folder, { recursive: true, force: true });

const out = path.join(root, "packages/python/tests/fixtures/reports-store.json");
mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify({ description: "buildReport over packages/php/tests/fixtures/store.db, from scripts/python-fixtures-reports.mts", cases })}\n`);
console.log(`${cases.length} reports written to ${path.relative(root, out)}`);
