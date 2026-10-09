/**
 * Prints one release's section of CHANGELOG.md, without its heading, for the
 * notes of its GitHub release (.github/workflows/release.yml).
 *
 *   node scripts/release-notes.mjs <version>
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { sectionOf } from "./changelogs.mjs";

const version = (process.argv[2] ?? "").replace(/^v/, "");
if (version === "") {
  console.error("usage: node scripts/release-notes.mjs <version>");
  process.exit(1);
}
try {
  process.stdout.write(sectionOf(readFileSync(path.join(process.cwd(), "CHANGELOG.md"), "utf8"), version));
} catch (error) {
  console.error(`release-notes: ${error.message}`);
  process.exit(1);
}
