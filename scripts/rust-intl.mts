// Writes packages/rust/runlight/assets/intl.json: what the Rust port's Intl needs from Node's ICU for the
// dashboard's languages, which no Rust crate carries in the same words. That is each region's name, as
// Intl.DisplayNames gives it, and each currency's symbol, placement, and digits, as Intl.NumberFormat writes
// them. Only what differs from the plain default is kept: a region that keeps its code is left out, and so
// is a currency written as its code where the language writes an unknown code. Run with Node 24 (ICU 78)
// after a Node upgrade; with --check it only says whether the file is current.
import { readFileSync, writeFileSync } from "node:fs";
import { ENGLISH, LOCALES } from "../packages/sdk/src/generated/dashboard.ts";

const file = new URL("../packages/rust/runlight/assets/intl.json", import.meta.url);
const langs = Object.keys({ en: ENGLISH, ...LOCALES });
const letters = Array.from({ length: 26 }, (_, i) => String.fromCharCode(65 + i));

const regionCodes: string[] = [];
for (const a of letters) for (const b of letters) regionCodes.push(a + b);
for (let n = 0; n < 1000; n++) regionCodes.push(String(n).padStart(3, "0"));
const currencyCodes: string[] = [];
for (const a of letters) for (const b of letters) for (const c of letters) currencyCodes.push(a + b + c);

/** A currency's amount as [before, after] the number, from how 1 is written with no decimals. */
function sides(lang: string, code: string): [string, string] {
  const text = new Intl.NumberFormat(lang, { style: "currency", currency: code, maximumFractionDigits: 0 }).format(1);
  const at = text.indexOf("1");
  if (at < 0 || text.indexOf("1", at + 1) >= 0) throw new Error(`rust-intl: cannot split ${lang} ${code}: ${text}`);
  return [text.slice(0, at), text.slice(at + 1)];
}

const out: Record<string, unknown> = {
  note: "Written by scripts/rust-intl.mts from Node's ICU. Do not edit.",
  icu: process.versions.icu,
};
const regions: Record<string, Record<string, string>> = {};
const currencies: Record<string, unknown> = {};
for (const lang of langs) {
  const names = new Intl.DisplayNames(lang, { type: "region" });
  const own: Record<string, string> = {};
  for (const code of regionCodes) {
    let name = code;
    try {
      name = names.of(code) ?? code;
    } catch {}
    if (name !== code) own[code] = name;
  }
  regions[lang] = own;

  // An unknown code shows as itself, placed as this language places a code.
  const [before, after] = sides(lang, "ZZZ");
  const unknown = [before.replace("ZZZ", "{c}"), after.replace("ZZZ", "{c}")];
  const symbols: Record<string, [string, string]> = {};
  const digits: Record<string, number> = {};
  for (const code of currencyCodes) {
    const pair = sides(lang, code);
    if (pair[0] !== unknown[0]!.replace("{c}", code) || pair[1] !== unknown[1]!.replace("{c}", code)) symbols[code] = pair;
    const places = new Intl.NumberFormat(lang, { style: "currency", currency: code }).resolvedOptions().minimumFractionDigits!;
    if (places !== 2) digits[code] = places;
  }
  currencies[lang] = { unknown, symbols, digits };
}
out.regions = regions;
out.currencies = currencies;

const text = `${JSON.stringify(out, null, 1)}\n`;
let current: string | null = null;
try {
  current = readFileSync(file, "utf8");
} catch {}
// Another ICU (CI's Node, say) writes other data, so only the ICU that wrote the file compares it, as
// scripts/go-intl.mjs does.
let written: unknown;
try {
  written = JSON.parse(current ?? "").icu;
} catch {}
if (process.argv.includes("--check") && typeof written === "string" && written !== process.versions.icu) {
  console.log(`rust-intl: intl.json was written from ICU ${written}, this Node has ${process.versions.icu}`);
} else if (process.argv.includes("--check")) {
  if (current !== text) {
    console.error("rust-intl: packages/rust/runlight/assets/intl.json is stale. Run node --import tsx scripts/rust-intl.mts");
    process.exit(1);
  }
  console.log("rust-intl: up to date");
} else {
  if (current !== text) writeFileSync(file, text);
  console.log("rust-intl: written");
}
