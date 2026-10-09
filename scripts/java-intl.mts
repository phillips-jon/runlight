/**
 * Writes the pieces of Node's ICU the Java port's email reports need, where the JDK's own CLDR data is older
 * than Node's and names regions and currencies in other words
 * (packages/java/runlight/src/main/resources/sh/runlight/intl.json): region names and currency symbols in the
 * dashboard's languages, and each currency's default fraction digits. Then writes a fixture of Intl's output
 * over many inputs (packages/java/runlight/src/test/resources/sh/runlight/intl-cases.json) for IntlTest to
 * replay. With --check it writes nothing and only says whether both files are current.
 *
 * Run from the repo root: node --import tsx scripts/java-intl.mts [--check]
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const LANGS = ["en", "de", "es", "fr", "pt"];
const LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

const regionCodes: string[] = [];
for (const a of LETTERS) for (const b of LETTERS) regionCodes.push(a + b);
for (let i = 0; i < 1000; i++) regionCodes.push(String(i).padStart(3, "0"));

const currencyCodes: string[] = [];
for (const a of LETTERS) for (const b of LETTERS) for (const c of LETTERS) currencyCodes.push(a + b + c);

/** A currency's prefix and suffix around the number 1, written with no fraction digits. */
function frame(lang: string, code: string): [string, string] {
  const text = new Intl.NumberFormat(lang, { style: "currency", currency: code, maximumFractionDigits: 0 }).format(1);
  const at = text.indexOf("1");
  return [text.slice(0, at), text.slice(at + 1)];
}

const regions: Record<string, Record<string, string>> = {};
const currencies: Record<string, Record<string, [string, string]>> = {};
const unknown: Record<string, [string, string]> = {};
for (const lang of LANGS) {
  const names = new Intl.DisplayNames(lang, { type: "region" });
  regions[lang] = {};
  for (const code of regionCodes) {
    let name: string | undefined;
    try {
      name = names.of(code);
    } catch {
      name = undefined;
    }
    if (name !== undefined && name !== code) regions[lang][code] = name;
  }
  // A code ICU does not know is written as itself; QQQ stands for any such code.
  const [before, after] = frame(lang, "QQQ");
  unknown[lang] = [before.replace("QQQ", "{c}"), after.replace("QQQ", "{c}")];
  currencies[lang] = {};
  for (const code of currencyCodes) {
    const own = frame(lang, code);
    const fallback = [unknown[lang][0].replace("{c}", code), unknown[lang][1].replace("{c}", code)];
    if (own[0] !== fallback[0] || own[1] !== fallback[1]) currencies[lang][code] = own;
  }
}
const digits: Record<string, number> = {};
for (const code of currencyCodes) {
  const n = new Intl.NumberFormat("en", { style: "currency", currency: code }).resolvedOptions().minimumFractionDigits ?? 2;
  if (n !== 2) digits[code] = n;
}

// The fixture: what reports.ts formats, over many inputs.
const numbers = [0, 1, -1, 7, 12, 999, 1000, 1234, 12345, 123456, 1234567, -1234567, 0.5, 1.5, 2.5, -2.5, 0.05, 2.05, 1.005, 0.135, 0.1 + 0.2, 1e21, 1e-7, 123.456789, 9999.95, 99999.95, 0.0001, 3.14159, -0.4, -0, NaN, Infinity, -Infinity, 1 / 3, 2 / 3, 0.995, 1.45, 1.55, 12.345, 0.004, 0.005, 0.0049, 0.125, 0.875, 2 ** 53, 1e16, 123456789.987];
const cases: unknown[] = [];
for (const lang of LANGS) {
  const number = new Intl.NumberFormat(lang);
  const percent = new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 });
  const decimal = new Intl.NumberFormat(lang, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  for (const n of numbers) {
    const text = Object.is(n, -0) ? "-0" : String(n);
    cases.push({ lang, kind: "number", n: text, out: number.format(n) });
    cases.push({ lang, kind: "percent", n: text, out: percent.format(n) });
    cases.push({ lang, kind: "decimal", n: text, out: decimal.format(n) });
  }
  for (const currency of ["USD", "EUR", "GBP", "JPY", "CHF", "BRL", "KWD", "CLF", "XYZ", "usd", "DEM", "INR", "CAD", "AUD", "MXN", "ab", "ABCD", "€"]) {
    for (const n of [0, 1, 1234.5, 12345, -3, 0.5, 0.125, 1234567.891, 19.99, 1.005, -0.5]) {
      let out: string;
      try {
        out = new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits: Number.isInteger(n) ? 0 : 2 }).format(n);
      } catch {
        out = `${n} ${currency}`;
      }
      cases.push({ lang, kind: "currency", n: String(n), currency, out });
    }
  }
  for (const d of ["2026-01-05", "2026-02-28", "2026-03-01", "2026-04-30", "2026-05-31", "2026-06-15", "2026-07-04", "2026-08-09", "2026-09-30", "2026-10-10", "2026-11-11", "2026-12-25", "1999-04-01"]) {
    const day = (opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(lang, { ...opts, timeZone: "UTC" }).format(new Date(`${d}T00:00:00Z`));
    cases.push({ lang, kind: "monthYear", date: d, out: day({ month: "long", year: "numeric" }) });
    cases.push({ lang, kind: "shortDay", date: d, out: day({ month: "short", day: "numeric" }) });
    cases.push({ lang, kind: "shortDayYear", date: d, out: day({ month: "short", day: "numeric", year: "numeric" }) });
  }
  const names = new Intl.DisplayNames(lang, { type: "region" });
  for (const code of ["US", "GB", "DE", "FR", "BR", "JP", "XK", "ZZ", "419", "001", "999", "us", "Us", "", "USA", "AA", "CW", "HK", "MK", "CI", "TR", "CZ", "SZ", "PS", "MM", "TL", "CV", "EU", "UN", "QO"]) {
    let out: string;
    try {
      out = names.of(code) ?? code;
    } catch {
      out = code;
    }
    cases.push({ lang, kind: "region", code, out });
  }
}

const java = new URL("../packages/java/runlight/src/", import.meta.url);
const files: Array<[URL, string]> = [
  [new URL("main/resources/sh/runlight/intl.json", java), JSON.stringify({ regions, currencies, unknown, digits }) + "\n"],
  [
    new URL("test/resources/sh/runlight/intl-cases.json", java),
    JSON.stringify({ description: "Intl.NumberFormat, DateTimeFormat, and DisplayNames as reports.ts uses them, from Node's ICU. Written by scripts/java-intl.mts.", cases }, null, 1) + "\n",
  ],
];

const check = process.argv.includes("--check");
const stale: string[] = [];
for (const [file, text] of files) {
  let current: string | null = null;
  try {
    current = readFileSync(file, "utf8");
  } catch {}
  if (current === text) continue;
  if (check) stale.push(fileURLToPath(file));
  else {
    mkdirSync(dirname(fileURLToPath(file)), { recursive: true });
    writeFileSync(file, text);
  }
}
if (stale.length) {
  console.error(`java-intl: ${stale.join(", ")} stale. Run node --import tsx scripts/java-intl.mts (on Node ${process.versions.node}, ICU ${process.versions.icu})`);
  process.exit(1);
}
console.log(check ? "java-intl: up to date" : "java-intl: written");
