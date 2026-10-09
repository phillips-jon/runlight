// Writes packages/go/internal/intl/intl.json: what this Node's ICU says for
// the email reports' languages, which Go's standard library has no data for:
// each region's name, and how each currency is written around its amount
// (the text before and after the number, and its usual fraction digits).
// Run with Node 24:
//   node scripts/go-intl.mjs [--check]
import { readFileSync, writeFileSync } from "node:fs";

const languages = ["en", "de", "es", "fr", "pt"];
const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const codes = [];
for (const a of letters) for (const b of letters) codes.push(a + b);
for (let n = 0; n < 1000; n++) codes.push(String(n).padStart(3, "0"));

const regions = {};
const currencies = {};
for (const lang of languages) {
  const names = new Intl.DisplayNames(lang, { type: "region" });
  regions[lang] = {};
  for (const code of codes) {
    let name;
    try {
      name = names.of(code);
    } catch {
      continue;
    }
    if (name && name !== code) regions[lang][code] = name;
  }
  currencies[lang] = {};
  for (const code of Intl.supportedValuesOf("currency")) {
    const format = new Intl.NumberFormat(lang, { style: "currency", currency: code });
    const parts = format.formatToParts(1234.5);
    const number = new Set(["integer", "group", "decimal", "fraction"]);
    let before = "";
    let after = "";
    let seen = false;
    for (const part of parts) {
      if (number.has(part.type)) seen = true;
      else if (seen) after += part.value;
      else before += part.value;
    }
    currencies[lang][code] = [before, after, format.resolvedOptions().minimumFractionDigits];
  }
}
const text = `${JSON.stringify({ icu: process.versions.icu, unicode: process.versions.unicode, regions, currencies })}\n`;
const file = new URL("../packages/go/internal/intl/intl.json", import.meta.url);
if (process.argv.includes("--check")) {
  const old = JSON.parse(readFileSync(file, "utf8"));
  if (old.icu !== process.versions.icu) console.log(`intl.json was written from ICU ${old.icu}, this Node has ${process.versions.icu}`);
  else if (readFileSync(file, "utf8") !== text) {
    console.error("packages/go/internal/intl/intl.json is stale: run node scripts/go-intl.mjs");
    process.exit(1);
  }
} else {
  writeFileSync(file, text);
}
