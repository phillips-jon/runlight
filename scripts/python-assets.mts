// Copies the built dashboard and tracker into packages/python/src/runlight/assets, so the
// Python port serves the very same files as the TypeScript SDK. Run after building the
// dashboard or tracker; with --check it only says whether the copies are current.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import * as dashboard from "../packages/sdk/src/generated/dashboard.ts";
import * as tracker from "../packages/sdk/src/generated/tracker.ts";
import { RUNLIGHT_ICON } from "../packages/sdk/src/brand.ts";
import { API_VERSION, VERSION } from "../packages/sdk/src/version.ts";

const dir = new URL("../packages/python/src/runlight/assets/", import.meta.url);
const files: Record<string, string> = {
  "dashboard.js": dashboard.DASHBOARD_JS,
  "dashboard.css": dashboard.DASHBOARD_CSS,
  "world.json": dashboard.WORLD_JSON,
  "tracker.js": tracker.TRACKER,
  "picker.js": tracker.PICKER,
  "locales.json": `${JSON.stringify({ en: dashboard.ENGLISH, ...dashboard.LOCALES }, null, 1)}\n`,
  "build.json": `${JSON.stringify(
    {
      note: "Written by scripts/python-assets.mts from the TypeScript SDK's generated files. Do not edit.",
      version: VERSION,
      apiVersion: API_VERSION,
      dashboardHash: dashboard.DASHBOARD_HASH,
      worldHash: dashboard.WORLD_HASH,
      localesHash: dashboard.LOCALES_HASH,
      trackerHash: tracker.TRACKER_HASH,
      icon: RUNLIGHT_ICON,
    },
    null,
    2,
  )}\n`,
};

const check = process.argv.includes("--check");
const stale: string[] = [];
mkdirSync(dir, { recursive: true });
for (const [name, text] of Object.entries(files)) {
  const file = new URL(name, dir);
  let current: string | null = null;
  try {
    current = readFileSync(file, "utf8");
  } catch {}
  if (current === text) continue;
  if (check) stale.push(name);
  else writeFileSync(file, text);
}
if (stale.length) {
  console.error(`python-assets: ${stale.join(", ")} stale in packages/python/src/runlight/assets. Run npm run python-assets`);
  process.exit(1);
}
console.log(check ? "python-assets: up to date" : "python-assets: written");
