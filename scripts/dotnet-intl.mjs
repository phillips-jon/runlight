// Writes packages/dotnet/src/Runlight/Assets/intl.json: the region names and currency symbols
// Node's ICU gives for the dashboard's languages, so the .NET port's email reports name a country
// and write an amount exactly as the TypeScript SDK does (.NET has no Intl.DisplayNames, and its
// cultures know only their own currency). Run with Node 24, whose ICU the fixtures hold; with
// --check it only says whether the file is current. It also checks that the way the port lays out
// an amount (Intl.cs) matches Node for every currency.
import { readFileSync, writeFileSync } from "node:fs";

const LANGS = ["en", "de", "es", "fr", "pt"];
const file = new URL("../packages/dotnet/src/Runlight/Assets/intl.json", import.meta.url);

const codes = [];
for (let a = 65; a <= 90; a++) for (let b = 65; b <= 90; b++) codes.push(String.fromCharCode(a, b));
for (let n = 0; n < 1000; n++) codes.push(String(n).padStart(3, "0"));

const regions = {};
const currencies = {};
const digits = {};
const all = Intl.supportedValuesOf("currency");
for (const lang of LANGS) {
  const names = new Intl.DisplayNames(lang, { type: "region", fallback: "code" });
  regions[lang] = {};
  for (const code of codes) {
    const name = names.of(code);
    if (name && name !== code) regions[lang][code] = name;
  }
  currencies[lang] = {};
  for (const currency of all) {
    const parts = new Intl.NumberFormat(lang, { style: "currency", currency }).formatToParts(1);
    const symbol = parts.find((p) => p.type === "currency")?.value ?? currency;
    if (symbol !== currency) currencies[lang][currency] = symbol;
  }
}
for (const currency of all) {
  const d = new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions().minimumFractionDigits;
  if (d !== 2) digits[currency] = d;
}

// The layout Intl.cs uses, checked here against Node for every currency and language.
const isSymbol = (ch) => /\p{S}/u.test(ch);
const layout = (lang, n, currency, max) => {
  const code = currency.toUpperCase();
  const symbol = currencies[lang][code] ?? code;
  const min = Math.min(digits[code] ?? 2, max);
  const amount = new Intl.NumberFormat(lang, { minimumFractionDigits: min, maximumFractionDigits: max }).format(Math.abs(n));
  const sign = n < 0 || Object.is(n, -0) ? "-" : "";
  if (lang === "en") return sign + symbol + (isSymbol(symbol.at(-1)) ? "" : "\u00a0") + amount;
  if (lang === "pt") return `${sign}${symbol}\u00a0${amount}`;
  return `${sign}${amount}\u00a0${symbol}`;
};
const wrong = [];
for (const lang of LANGS) {
  for (const currency of [...all, "XYZ", "usd"]) {
    for (const [n, max] of [[12, 0], [12.5, 2], [1234.5, 2], [1500, 0], [0.99, 2], [1234567.25, 2], [-3, 0]]) {
      const node = new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits: max }).format(n);
      const ours = layout(lang, n, currency, max);
      if (node !== ours) wrong.push(`${lang} ${currency} ${n}: ${JSON.stringify(node)} vs ${JSON.stringify(ours)}`);
    }
  }
}
if (wrong.length) {
  console.error(`dotnet-intl: the port's currency layout differs from Node in ${wrong.length} cases:\n${wrong.slice(0, 40).join("\n")}`);
  process.exit(1);
}

const text = `${JSON.stringify({ note: `Written by scripts/dotnet-intl.mjs from Node's ICU ${process.versions.icu}. Do not edit.`, regions, currencies, digits }, null, 1)}\n`;
let current = null;
try {
  current = readFileSync(file, "utf8");
} catch {}
// Another ICU (CI's Node, say) writes other data, so only the ICU that wrote the file compares it, as
// scripts/go-intl.mjs does.
const written = /from Node's ICU ([^ ]+)\. Do not edit\./.exec(current ?? "")?.[1];
if (process.argv.includes("--check") && written && written !== process.versions.icu) {
  console.log(`dotnet-intl: intl.json was written from ICU ${written}, this Node has ${process.versions.icu}`);
} else if (process.argv.includes("--check")) {
  if (current !== text) {
    console.error("dotnet-intl: intl.json is stale. Run node scripts/dotnet-intl.mjs");
    process.exit(1);
  }
  console.log("dotnet-intl: up to date");
} else {
  if (current !== text) writeFileSync(file, text);
  console.log("dotnet-intl: written");
}
