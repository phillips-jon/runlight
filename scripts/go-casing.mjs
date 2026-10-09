// Writes packages/go/internal/js/casing.json: every character whose
// toLowerCase() or toUpperCase() in this Node is not itself, so the Go port
// changes case exactly as JavaScript does (İ to i̇, ß to SS), whatever
// Unicode version Go was built with. Run with Node 24:
//   node scripts/go-casing.mjs [--check]
import { readFileSync, writeFileSync } from "node:fs";

const lower = {};
const upper = {};
for (let cp = 0; cp <= 0x10ffff; cp++) {
  if (cp >= 0xd800 && cp <= 0xdfff) continue;
  const s = String.fromCodePoint(cp);
  // Σ's lower case depends on its neighbours; the Go side applies that rule itself.
  const l = cp === 0x3a3 ? "σ" : s.toLowerCase();
  const u = s.toUpperCase();
  if (l !== s) lower[cp.toString(16)] = l;
  if (u !== s) upper[cp.toString(16)] = u;
}
const text = `${JSON.stringify({ unicode: process.versions.unicode, lower, upper })}\n`;
const file = new URL("../packages/go/internal/js/casing.json", import.meta.url);
if (process.argv.includes("--check")) {
  const old = readFileSync(file, "utf8");
  if (JSON.parse(old).unicode !== process.versions.unicode) {
    console.log(`casing.json was written from Unicode ${JSON.parse(old).unicode}, this Node has ${process.versions.unicode}`);
  } else if (old !== text) {
    console.error("packages/go/internal/js/casing.json is stale: run node scripts/go-casing.mjs");
    process.exit(1);
  }
} else {
  writeFileSync(file, text);
}
