/**
 * Uses the packages the way a stranger would. Packs @runlight/sdk and
 * runlight.sh (build them first), installs both tarballs into a scratch
 * project, and checks that every SDK entry point loads with import and with
 * require and exports what it should, that runlight.sh loads, and that its
 * bin prints the version both packages carry.
 *
 *   node scripts/check-packages.mjs [--keep]
 *
 * The scratch project is deleted afterwards; pass --keep to leave it.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const ROOT = process.cwd();
const keep = process.argv.includes("--keep");
const npm = process.platform === "win32" ? "npm.cmd" : "npm";
const sdkPkg = JSON.parse(readFileSync(path.join(ROOT, "packages/sdk/package.json"), "utf8"));
const serverPkg = JSON.parse(readFileSync(path.join(ROOT, "packages/server/package.json"), "utf8"));
const version = sdkPkg.version;

function run(cmd, args, cwd) {
  console.log(`$ ${[cmd, ...args].join(" ")}`);
  return execFileSync(cmd, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
}

function fail(message) {
  console.error(`check-packages: ${message}`);
  process.exit(1);
}

if (serverPkg.version !== version) fail(`runlight.sh is ${serverPkg.version}, @runlight/sdk is ${version}`);

// Every subpath the SDK exports, as the names a consumer imports.
const entries = Object.keys(sdkPkg.exports)
  .filter((k) => k !== "./package.json")
  .map((k) => (k === "." ? "@runlight/sdk" : `@runlight/sdk/${k.slice(2)}`));
// What each entry must export, so a load that "works" but is empty still fails.
const expected = {
  "@runlight/sdk": ["runlight", "Runlight", "SqlStore", "VERSION"],
  "@runlight/sdk/sqlite": ["sqlite"],
  "@runlight/sdk/postgres": ["postgres"],
  "@runlight/sdk/mysql": ["mysql"],
  "@runlight/sdk/node": ["toNodeHandler", "observer"],
  "@runlight/sdk/libsql": ["libsql"],
  "@runlight/sdk/d1": ["d1"],
  "@runlight/sdk/bun": ["bunSqlite"],
};
const unchecked = entries.filter((e) => !expected[e]);
if (unchecked.length > 0) fail(`no expected exports for ${unchecked.join(", ")}; add them to scripts/check-packages.mjs`);

const dir = mkdtempSync(path.join(tmpdir(), "runlight-packages-"));
try {
  const packed = path.join(dir, "packed");
  mkdirSync(packed);
  run(npm, ["pack", "--silent", "--workspace", "packages/sdk", "--workspace", "packages/server", "--pack-destination", packed], ROOT);
  const tarballs = readdirSync(packed).filter((f) => f.endsWith(".tgz")).map((f) => path.join(packed, f));
  if (tarballs.length !== 2) fail(`expected two tarballs, found ${tarballs.length}`);

  const project = path.join(dir, "project");
  mkdirSync(project);
  writeFileSync(path.join(project, "package.json"), `${JSON.stringify({ name: "scratch", private: true, type: "module" }, null, 2)}\n`);
  run(npm, ["install", "--no-audit", "--no-fund", "--loglevel=error", ...tarballs], project);

  const imports = entries.map((e) => `[${JSON.stringify(e)}, await import(${JSON.stringify(e)})]`).join(",\n  ");
  writeFileSync(
    path.join(project, "esm.mjs"),
    `const expected = ${JSON.stringify(expected)};
const loaded = [
  ${imports},
];
for (const [name, mod] of loaded) {
  const missing = expected[name].filter((k) => mod[k] === undefined);
  if (missing.length) throw new Error(\`\${name} (import) lacks \${missing.join(", ")}\`);
}
const sdk = await import("@runlight/sdk");
if (sdk.VERSION !== ${JSON.stringify(version)}) throw new Error(\`@runlight/sdk VERSION is \${sdk.VERSION}\`);
const server = await import("runlight.sh");
if (typeof server.createServer !== "function") throw new Error("runlight.sh lacks createServer");
if (server.VERSION !== ${JSON.stringify(version)}) throw new Error(\`runlight.sh VERSION is \${server.VERSION}\`);
console.log(\`import: \${loaded.length} SDK entries and runlight.sh\`);
`,
  );
  writeFileSync(
    path.join(project, "cjs.cjs"),
    `const expected = ${JSON.stringify(expected)};
for (const name of Object.keys(expected)) {
  const mod = require(name);
  const missing = expected[name].filter((k) => mod[k] === undefined);
  if (missing.length) throw new Error(\`\${name} (require) lacks \${missing.join(", ")}\`);
}
console.log(\`require: \${Object.keys(expected).length} SDK entries\`);
`,
  );
  process.stdout.write(run("node", ["esm.mjs"], project));
  process.stdout.write(run("node", ["cjs.cjs"], project));
  const bin = path.join(project, "node_modules", ".bin", process.platform === "win32" ? "runlight.sh.cmd" : "runlight.sh");
  const printed = run(bin, ["--version"], project).trim();
  if (printed !== version) fail(`runlight.sh --version printed ${JSON.stringify(printed)}, not ${version}`);
  console.log(`runlight.sh --version: ${printed}`);
  console.log(`check-packages: @runlight/sdk and runlight.sh ${version} install and load`);
} finally {
  if (keep) console.log(`Kept ${dir}`);
  else rmSync(dir, { recursive: true, force: true });
}
