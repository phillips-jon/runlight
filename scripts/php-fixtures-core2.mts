// Writes packages/php/tests/fixtures/reports.json: email reports the TypeScript SDK renders for fixed visits in
// every language, the periods they cover, and the Intl formatting they use, so the PHP port can replay the same
// visits and must render the same emails. Run with: node --import tsx scripts/php-fixtures-core2.mts
import { mkdirSync, writeFileSync } from "node:fs";
import { runlight } from "../packages/sdk/src/index.js";
import { sqlite } from "../packages/sdk/src/stores/sqlite.js";
import { buildReport, lastPeriod } from "../packages/sdk/src/reports.js";
import type { GoalRow } from "../packages/sdk/src/store.js";

const dir = new URL("../packages/php/tests/fixtures/", import.meta.url);
mkdirSync(dir, { recursive: true });

const LANGS = ["en", "de", "es", "fr", "pt"];
const DAY = 86_400_000;

// ---------------------------------------------------------------- Intl pieces

const numbers = [0, 1, 5, 999, 1000, 1234, 9999, 12345, 123456, 1234567, 0.5, 1.25, 1.35, 2.05, 2.5, 0.15, 1234.56, 99.95, 0.999];
const ratios = [0, 0.001, 0.004, 0.005, 0.0049, 0.12, 0.125, 0.135, 0.5, 0.995, 1, 1.5, 12.345, 0.3333333333333333, 0.6666666666666666, 2 / 7];
const money: Array<[number, string]> = [[12, "USD"], [12.5, "EUR"], [1234.5, "GBP"], [3, "JPY"], [1500, "CAD"], [0.99, "BRL"], [7, "CHF"], [12.5, "usd"], [5, "US"], [5, "XYZ"]];
const days: string[] = [];
for (let t = Date.UTC(2025, 11, 1); t <= Date.UTC(2027, 0, 31); t += DAY) days.push(new Date(t).toISOString().slice(0, 10));
const codes: string[] = ["", "gb", "T1", "A1", "XX", "ZZ", "EU", "UN", "QO", "001", "419"];
for (let a = 65; a <= 90; a++) for (let b = 65; b <= 90; b++) codes.push(String.fromCharCode(a, b));

const intl = LANGS.map((code) => {
  const day = (d: string, opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(code, { ...opts, timeZone: "UTC" }).format(new Date(`${d}T00:00:00Z`));
  const region = (c: string) => {
    try {
      return new Intl.DisplayNames(code, { type: "region" }).of(c) ?? c;
    } catch {
      return c;
    }
  };
  const currency = (n: number, c: string) => {
    try {
      return new Intl.NumberFormat(code, { style: "currency", currency: c, maximumFractionDigits: Number.isInteger(n) ? 0 : 2 }).format(n);
    } catch {
      return `${n} ${c}`;
    }
  };
  return {
    lang: code,
    number: numbers.map((n) => [n, new Intl.NumberFormat(code).format(n)]),
    decimal: numbers.map((n) => [n, new Intl.NumberFormat(code, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(n)]),
    percent: ratios.map((n) => [n, new Intl.NumberFormat(code, { style: "percent", maximumFractionDigits: 0 }).format(n)]),
    currency: money.map(([n, c]) => [n, c, currency(n, c)]),
    monthYear: days.filter((d) => d.endsWith("-01")).map((d) => [d, day(d, { month: "long", year: "numeric" })]),
    shortDay: days.map((d) => [d, day(d, { month: "short", day: "numeric" }), day(d, { month: "short", day: "numeric", year: "numeric" })]),
    region: codes.map((c) => [c, region(c)]),
  };
});

// ---------------------------------------------------------------- periods

const zones = ["UTC", "America/Toronto", "Europe/London", "Asia/Tokyo", "Pacific/Auckland", "Pacific/Pago_Pago", "America/Santiago"];
const periods: unknown[] = [];
for (let t = Date.UTC(2026, 0, 1); t < Date.UTC(2027, 0, 10); t += 41 * 3_600_000 + 7 * 60_000) {
  for (const zone of zones) for (const frequency of ["weekly", "monthly"] as const) periods.push({ now: t, zone, frequency, period: lastPeriod(frequency, t, zone) });
}

// ---------------------------------------------------------------- reports

const PAGES = ["/", "/blog/one", "/blog/two", "/pricing", "/about", "/café", "/docs/a&b"];
const REFERRERS = ["https://www.google.com/", "https://news.ycombinator.com/", "", "https://chatgpt.com/", "https://t.co/x", "https://example.org/<post>"];
const COUNTRIES = ["GB", "US", "DE", "CA", "FR", "JP", "BR", ""];
const AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

/** The hits, in order, each with the clock when it arrives; the PHP test sends the same. */
const hits: Array<{ at: number; ip: string; country: string; body: Record<string, unknown> }> = [];
let n = 0;
for (let t = Date.UTC(2026, 8, 1, 13); t < Date.UTC(2026, 9, 12); t += DAY) {
  const day = Math.round((t - Date.UTC(2026, 8, 1, 13)) / DAY);
  // More visits in the later week than the week before, and some days with none.
  const visits = day % 9 === 4 ? 0 : 1 + ((day * 7) % 5) + (day > 34 ? 2 : 0);
  for (let v = 0; v < visits; v++) {
    n++;
    const at = t + v * 37 * 60_000;
    const ip = `203.0.113.${n % 50}`;
    const country = COUNTRIES[n % COUNTRIES.length]!;
    hits.push({ at, ip, country, body: { k: "pageview", u: `https://example.com${PAGES[n % PAGES.length]}`, r: REFERRERS[n % REFERRERS.length], i: `p${n}` } });
    if (n % 3 === 0) hits.push({ at: at + 30_000, ip, country, body: { k: "pageview", u: `https://example.com${PAGES[(n + 1) % PAGES.length]}`, i: `p${n}b` } });
    if (n % 4 === 0) hits.push({ at: at + 45_000, ip, country, body: { k: "event", u: "https://example.com/pricing", i: `p${n}`, n: "Signup", p: { amount: String((n % 5) * 2.5) } } });
    if (n % 2 === 0) hits.push({ at: at + 60_000, ip, country, body: { k: "engagement", u: "https://example.com/", i: `p${n}`, e: 5_000 + n * 750, d: n % 100 } });
  }
}

const goals: GoalRow[] = [
  { id: "g1", site: "default", name: "Signup", kind: "event", match: "Signup", clickBy: "", valueMode: "prop", value: 0, valueProp: "amount", currency: "EUR", createdAt: 1 },
  { id: "g2", site: "default", name: "Pricing <page>", kind: "page", match: "/pricing", clickBy: "", valueMode: "none", value: 0, valueProp: "", currency: "USD", createdAt: 2 },
  { id: "g3", site: "default", name: "Fixed", kind: "event", match: "Signup", clickBy: "", valueMode: "fixed", value: 3, valueProp: "", currency: "JPY", createdAt: 3 },
];

async function render(timezone: string, sent: typeof hits, withGoals: boolean, at: number) {
  let now = 0;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { name: "Example & Co", hostnames: ["example.com"], timezone }, now: () => now });
  await rl.init();
  for (const g of withGoals ? goals : []) await rl.store.saveGoal(g);
  for (const hit of sent) {
    now = hit.at;
    const headers: Record<string, string> = { "user-agent": AGENT, "x-forwarded-for": hit.ip };
    if (hit.country) headers["x-vercel-ip-country"] = hit.country;
    await rl.collect(new Request("https://example.com/runlight/e", { method: "POST", headers, body: JSON.stringify(hit.body) }));
  }
  now = at;
  const site = rl.site("default")!;
  const out: unknown[] = [];
  for (const lang of [...LANGS, "xx"]) {
    for (const frequency of ["weekly", "monthly"] as const) {
      const period = lastPeriod(frequency, at, timezone);
      const links = { dashboard: "https://stats.example.com/runlight/?site=default", unsubscribe: "https://stats.example.com/runlight/unsubscribe/abc" };
      out.push({ lang, frequency, period, links, ...(await buildReport(rl, site, frequency, period, lang, links)) });
    }
  }
  return out;
}

const cases = [
  { name: "a busy site in Toronto", timezone: "America/Toronto", withGoals: true, at: Date.UTC(2026, 9, 12, 15), hits },
  { name: "a site in Tokyo, a week with no visits before it", timezone: "Asia/Tokyo", withGoals: false, at: Date.UTC(2026, 8, 14, 3), hits: hits.filter((h) => h.at >= Date.UTC(2026, 8, 7)) },
  { name: "a site with no visits at all", timezone: "UTC", withGoals: true, at: Date.UTC(2026, 9, 12, 15), hits: [] },
];
const reports = [];
for (const c of cases) reports.push({ name: c.name, timezone: c.timezone, withGoals: c.withGoals, at: c.at, hits: c.hits, goals: c.withGoals ? goals : [], reports: await render(c.timezone, c.hits, c.withGoals, c.at) });

const text = `${JSON.stringify({ description: "Email reports and their Intl formatting, from the TypeScript SDK (scripts/php-fixtures-core2.mts)", intl, periods, cases: reports })}\n`;
writeFileSync(new URL("reports.json", dir), text);
console.log(`reports.json: ${(text.length / 1024).toFixed(0)} KB`);
