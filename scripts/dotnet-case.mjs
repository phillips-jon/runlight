// Writes packages/dotnet/src/Runlight/CaseTables.cs: every code point whose
// String.prototype.toLowerCase or toUpperCase in Node differs from itself, with
// what it becomes, so the .NET port changes case exactly as JavaScript does
// (full mappings such as U+0130 to "i" and U+0307, and the German sharp s to
// "SS", which .NET's simple mappings leave alone). The one context-sensitive
// rule, a final capital sigma, is applied in Js.cs.
//
//   node scripts/dotnet-case.mjs
import { writeFileSync } from "node:fs";

function table(map) {
  const rows = [];
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const ch = String.fromCodePoint(cp);
    const mapped = map(ch);
    if (mapped !== ch) rows.push([cp, mapped]);
  }
  return rows;
}

function escape(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) out += `\\u${text.charCodeAt(i).toString(16).padStart(4, "0")}`;
  return out;
}

function literal(rows) {
  // code point in hex, a colon, the mapping escaped, rows joined by a newline.
  return rows.map(([cp, mapped]) => `        "${cp.toString(16)}:${escape(mapped)}\\n" +`).join("\n");
}

const lower = table((c) => c.toLowerCase());
const upper = table((c) => c.toUpperCase());
const out = [
  "// Written by scripts/dotnet-case.mjs; do not edit by hand.",
  `// From Node ${process.version} (ICU ${process.versions.icu}, Unicode ${process.versions.unicode}).`,
  "namespace Runlight;",
  "",
  "/// <summary>JavaScript's toLowerCase and toUpperCase, as code point and mapping rows: \"hex:text\\n\".</summary>",
  "internal static class CaseTables",
  "{",
  "    public const string Lower =",
  literal(lower),
  '        "";',
  "",
  "    public const string Upper =",
  literal(upper),
  '        "";',
  "}",
  "",
];
writeFileSync(new URL("../packages/dotnet/src/Runlight/CaseTables.cs", import.meta.url), out.join("\n"));
console.log(`${lower.length} lower and ${upper.length} upper mappings written`);
