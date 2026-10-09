// Writes packages/rust/runlight-sqlx/tests/fixtures/reports-rows.json: the visits and rows the TypeScript SDK
// stores for each case's hits in packages/php/tests/fixtures/reports.json, so the Rust port's report tests can
// put the same rows in a store before the core that collects them is ported. It also checks that the SDK still
// renders each case's reports as the fixture holds them. Run with: node --import tsx scripts/rust-fixtures-reports.mts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { runlight } from "../packages/sdk/src/index.js";
import { sqlite } from "../packages/sdk/src/stores/sqlite.js";
import { buildReport } from "../packages/sdk/src/reports.js";

const AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
const fixture = JSON.parse(readFileSync(new URL("../packages/php/tests/fixtures/reports.json", import.meta.url), "utf8"));
const dir = new URL("../packages/rust/runlight-sqlx/tests/fixtures/", import.meta.url);
mkdirSync(dir, { recursive: true });

const cases = [];
for (const c of fixture.cases) {
  let now = 0;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "Example & Co", hostnames: ["example.com"], timezone: c.timezone }, now: () => now });
  await rl.init();
  for (const g of c.goals) await rl.store.saveGoal(g);
  for (const hit of c.hits) {
    now = hit.at;
    const headers: Record<string, string> = { "user-agent": AGENT, "x-forwarded-for": hit.ip };
    if (hit.country) headers["x-vercel-ip-country"] = hit.country;
    await rl.collect(new Request("https://example.com/runlight/e", { method: "POST", headers, body: JSON.stringify(hit.body) }));
  }
  now = c.at;
  const site = rl.site("default")!;
  for (const r of c.reports) {
    const built = await buildReport(rl, site, r.frequency, r.period, r.lang, r.links);
    if (built.html !== r.html || built.text !== r.text || built.subject !== r.subject) throw new Error(`rust-fixtures-reports: ${c.name} ${r.lang} ${r.frequency} no longer matches reports.json`);
  }
  const rollups = await rl.store.db.all<{ n: number }>("SELECT COUNT(*) AS n FROM rl_rollups");
  if (Number(rollups[0]!.n) !== 0) throw new Error("rust-fixtures-reports: the hits built rollups, which this file does not carry");
  const sessions = await rl.store.db.all("SELECT * FROM rl_sessions ORDER BY started_at, id");
  const events = await rl.store.db.all("SELECT * FROM rl_events ORDER BY id");
  cases.push({ name: c.name, site: { id: site.id, name: site.name, hostnames: site.hostnames, timezone: site.timezone }, sessions, events: events.map((e) => ({ ...(e as object), id: undefined })) });
  await rl.store.close();
}

const text = `${JSON.stringify(
  { description: "The rows the TypeScript SDK stores for the hits in packages/php/tests/fixtures/reports.json (scripts/rust-fixtures-reports.mts)", cases },
  (_, v) => (typeof v === "bigint" ? Number(v) : v),
)}\n`;
writeFileSync(new URL("reports-rows.json", dir), text);
console.log(`reports-rows.json: ${(text.length / 1024).toFixed(0)} KB`);
