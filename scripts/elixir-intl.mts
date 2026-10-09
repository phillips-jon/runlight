// Writes packages/elixir/priv/intl.json: what the email reports need of Node's Intl (ICU) in each of the
// dashboard's languages, which Elixir has no copy of. Number separators, the percent and currency affixes,
// month names as dates are written, and region names. With --check it only says whether the file is current,
// when this Node's ICU is the one that wrote it.
import { readFileSync, writeFileSync } from "node:fs";
import { languages } from "../packages/sdk/src/messages.ts";

const out = new URL("../packages/elixir/priv/intl.json", import.meta.url);

function affixes(text: string, number: string, what: string): { prefix: string; suffix: string } {
  const at = text.indexOf(number);
  if (at < 0) throw new Error(`elixir-intl: ${what}: "${number}" is not in "${text}"`);
  return { prefix: text.slice(0, at), suffix: text.slice(at + number.length) };
}

/** A date's parts as a template, with the year and day as {y} and {d}. */
function template(lang: string, date: Date, options: Intl.DateTimeFormatOptions): string {
  return new Intl.DateTimeFormat(lang, { ...options, timeZone: "UTC" })
    .formatToParts(date)
    .map((p) => (p.type === "year" ? "{y}" : p.type === "day" ? "{d}" : p.value))
    .join("");
}

const regions: string[] = [];
for (let a = 65; a <= 90; a++) for (let b = 65; b <= 90; b++) regions.push(String.fromCharCode(a, b));
for (let n = 0; n < 1000; n++) regions.push(String(n).padStart(3, "0"));

const data: Record<string, unknown> = { note: "Written by scripts/elixir-intl.mts from Node's Intl. Do not edit.", icu: process.versions.icu };
for (const lang of languages()) {
  const parts = new Intl.NumberFormat(lang).formatToParts(1234567.5);
  const group = parts.find((p) => p.type === "group")?.value ?? "";
  const decimal = parts.find((p) => p.type === "decimal")?.value ?? ".";
  // Whether four digits are grouped (CLDR's minimum grouping digits).
  const groupsFour = new Intl.NumberFormat(lang).format(1234).length > 4;
  const percent = affixes(new Intl.NumberFormat(lang, { style: "percent" }).format(0.5), "50", `${lang} percent`);
  const number2 = new Intl.NumberFormat(lang, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(1234567.5);
  const currencies: Record<string, { prefix: string; suffix: string; digits: number }> = {};
  for (const code of Intl.supportedValuesOf("currency")) {
    const format = new Intl.NumberFormat(lang, { style: "currency", currency: code, minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const digits = new Intl.NumberFormat(lang, { style: "currency", currency: code }).resolvedOptions().minimumFractionDigits ?? 2;
    currencies[code] = { ...affixes(format.format(1234567.5), number2, `${lang} ${code}`), digits };
  }
  // A code ICU has no symbol for is written as itself, in the same place: XYZ stands for any of them.
  const other = affixes(
    new Intl.NumberFormat(lang, { style: "currency", currency: "XYZ", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(1234567.5),
    number2,
    `${lang} XYZ`,
  );
  const months = Array.from({ length: 12 }, (_, m) => {
    const date = new Date(Date.UTC(2026, m, 15));
    return [template(lang, date, { month: "long", year: "numeric" }), template(lang, date, { month: "short", day: "numeric" }), template(lang, date, { month: "short", day: "numeric", year: "numeric" })];
  });
  const names = new Intl.DisplayNames(lang, { type: "region" });
  const regionNames: Record<string, string> = {};
  for (const code of regions) {
    let name: string | undefined;
    try {
      name = names.of(code);
    } catch {
      name = undefined;
    }
    if (name !== undefined && name !== code) regionNames[code] = name;
  }
  data[lang] = { group, decimal, groupsFour, percent, currencies, other: { prefix: other.prefix.replace("XYZ", "{c}"), suffix: other.suffix.replace("XYZ", "{c}") }, months, regions: regionNames };
}

const text = `${JSON.stringify(data, null, 1)}\n`;
if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(out, "utf8");
  } catch {}
  // Another ICU (CI's Node, say) writes other data, so only the ICU that wrote the file compares it, as
  // scripts/go-intl.mjs does.
  let icu: unknown;
  try {
    icu = JSON.parse(current).icu;
  } catch {}
  if (typeof icu === "string" && icu !== process.versions.icu) {
    console.log(`elixir-intl: intl.json was written from ICU ${icu}, this Node has ${process.versions.icu}`);
    process.exit(0);
  }
  if (current !== text) {
    console.error("elixir-intl: packages/elixir/priv/intl.json is stale. Run node --import tsx scripts/elixir-intl.mts");
    process.exit(1);
  }
  console.log("elixir-intl: up to date");
} else {
  writeFileSync(out, text);
  console.log("elixir-intl: written");
}
