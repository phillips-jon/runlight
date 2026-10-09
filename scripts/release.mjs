/**
 * Cuts a release: bumps every version the release carries, regenerates the
 * lockfile and the PHP package's build.json, runs every check, builds the
 * WordPress plugin's zip, packs and installs the npm packages, then commits
 * "Release <version>" and tags v<version>. It never pushes or publishes; it
 * prints those commands.
 *
 *   node scripts/release.mjs <version> [options]
 *   npm run release -- <version> [options]
 *
 *   --dry-run          print every change and command, write nothing
 *   --branch <name>    release from this branch instead of main (for testing)
 *
 * The Postgres and MySQL tests run when RUNLIGHT_TEST_PG and
 * RUNLIGHT_TEST_MYSQL are set, as for `npm run check`.
 *
 * Every folder under packages/ and plugins/ needs a row in VERSIONED (a file
 * holding its version) or UNVERSIONED (why it has none), and a row in PUBLISH
 * (how it ships) or UNPUBLISHED (why it does not). The script refuses to run
 * while a folder is missing either.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { addMarkdownChangelog, addReadmeChangelog, addRootChangelog, today } from "./changelogs.mjs";

/**
 * Every place the release version lives. Each pattern captures
 * (before)(version)(after); a pattern with the g flag moves every match in
 * its file, and must match at least once.
 */
export const VERSIONED = [
  { file: "packages/sdk/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // What the SDK reports about itself (VERSION, and GET <base>/api).
  { file: "packages/sdk/src/version.ts", pattern: /^(export const VERSION = ")([^"]+)(")/m },
  { file: "packages/server/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // The server requires the SDK of its own release. npm still links the
  // workspace, whose version is the same.
  { file: "packages/server/package.json", pattern: /^( {4}"@runlight\/sdk": ")([^"]+)(")/m },
  { file: "packages/server/src/version.ts", pattern: /^(export const VERSION = ")([^"]+)(")/m },
  // The PHP package reads its version from build.json, which
  // scripts/php-assets.mts writes from the SDK's VERSION (the release runs
  // it again, and `npm test` checks it is current). composer.json has no
  // version: Packagist takes it from the tag.
  { file: "packages/php/assets/build.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // The PHP tests' fixtures record what the TypeScript reports for its version.
  { file: "packages/php/tests/fixtures/version.json", pattern: /("version":")([^"]+)(")/ },
  { file: "packages/php/tests/fixtures/mcp.json", pattern: /(\\"serverInfo\\":\{\\"name\\":\\"runlight\\",\\"title\\":\\"Runlight\\",\\"version\\":\\")([^\\"]+)(\\")/g },
  // The WordPress plugin ships at the release's version; build.php refuses a
  // zip whose header, constant, readme Stable tag and changelog disagree.
  { file: "plugins/wordpress/runlight.php", pattern: /^( \* Version: +)(\S+)()$/m },
  { file: "plugins/wordpress/runlight.php", pattern: /^(define\( 'RUNLIGHT_PLUGIN_VERSION', ')([^']+)(' \);)$/m },
  { file: "plugins/wordpress/readme.txt", pattern: /^(Stable tag: )(\S+)()$/m },
  // The Python package: pyproject.toml for PyPI, and build.json, which
  // scripts/python-assets.mts writes from the SDK's VERSION and the package
  // reports as its own.
  { file: "packages/python/pyproject.toml", pattern: /^(version = ")([^"]+)(")/m },
  { file: "packages/python/src/runlight/assets/build.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // The Ruby gem: GEM_VERSION for RubyGems, and build.json, which
  // scripts/ruby-assets.mts writes from the SDK's VERSION.
  { file: "packages/ruby/lib/runlight/version.rb", pattern: /^(\s*GEM_VERSION = ")([^"]+)(")/m },
  { file: "packages/ruby/assets/build.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // The Rails test apps' lockfiles name the gem they load from the path.
  ...["7_2", "8_0", "8_1"].map((rails) => ({ file: `packages/ruby/test/rails/gemfiles/rails_${rails}.gemfile.lock`, pattern: /^( {4}runlight \()([^)]+)(\))$/m })),
  // A Go module's version is its tag (see PUBLISH); the constant is what the
  // module reports about itself, kept in step with the tag. build.json is
  // written by scripts/go-assets.mts from the SDK's VERSION.
  { file: "packages/go/version.go", pattern: /^(const Version = ")([^"]+)(")/m },
  // The MCP server's copy, which keeps that package off the root one.
  { file: "packages/go/internal/mcp/mcp.go", pattern: /^(const version = ")([^"]+)(")/m },
  { file: "packages/go/internal/assets/build.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // The chi and Echo adapters and the command are modules of their own,
  // released with the core under tags of their own (see PUBLISH), and each
  // requires the core at the same release. A replace directive points them
  // at the source for development; an app that requires one ignores it and
  // gets this version. The test module dbtest is never tagged, and moves
  // with them only to stay in step. (A requirement is on a require line of
  // its own or in a require block.)
  ...["chi", "echo", "cmd/runlight", "dbtest"].map((dir) => ({ file: `packages/go/${dir}/go.mod`, pattern: /^((?:require |\t)runlight\.sh\/go v)(\S+)()$/m })),
  // The Hex package: mix.exs alone holds its version, and build.json, which
  // scripts/elixir-assets.mts writes from the SDK's VERSION.
  { file: "packages/elixir/mix.exs", pattern: /^(\s*@version ")([^"]+)(")/m },
  { file: "packages/elixir/priv/assets/build.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
];

/** Folders with no version in any file, and why. */
export const UNVERSIONED = {
  "packages/dashboard": "built into the SDK, never published on its own",
  "packages/tracker": "built into the SDK, never published on its own",
  "plugins/drupal": "drupal.org stamps the version from the tag into the packaged .info.yml, and it talks to Runlight over HTTP rather than requiring a release of it",
  "plugins/craft": "Packagist and the Craft Plugin Store take the version from the tag, and it talks to Runlight over HTTP rather than requiring a release of it",
};

/**
 * The changelogs a release writes its section into (scripts/changelogs.mjs):
 * the WordPress plugin's readme, whose "= Unreleased =" becomes "= X.Y.Z =",
 * and the Craft plugin's CHANGELOG.md, whose "## Unreleased" becomes
 * "## X.Y.Z - <today>". A file with no notes written ahead gets a placeholder
 * section, with a reminder to write better notes. The project's CHANGELOG.md
 * is turned the same way, but holds the release's notes, so the release
 * refuses to run without its Unreleased section.
 */
const README_CHANGELOG = "plugins/wordpress/readme.txt";
const MARKDOWN_CHANGELOGS = ["plugins/craft/CHANGELOG.md"];
const ROOT_CHANGELOG = "CHANGELOG.md";

/** How each folder ships, printed after the release commit, in order. */
export const PUBLISH = [
  { dir: "packages/sdk", commands: () => ["npm publish --workspace packages/sdk --access public"] },
  // The server requires the SDK at exactly this release, so the SDK goes first.
  { dir: "packages/server", commands: (v) => [
    "npm publish --workspace packages/server --access public",
    `# packages/server: the pushed tag v${v} also builds the Docker image for linux/amd64 and linux/arm64 and pushes it to ghcr.io/phillips-jon/runlight as ${v}${v.includes("-") ? "" : " and latest"}, by .github/workflows/docker.yml (once DOCKER_ENABLED is true)`,
  ] },
  // Packagist reads composer.json from a repository's root and versions from
  // its tags, so packages/php goes to a read-only repository of its own.
  { dir: "packages/php", commands: (v) => [`# packages/php: the pushed tag v${v} is split to phillips-jon/runlight-php, which Packagist watches, by .github/workflows/php-split.yml (once PHP_SPLIT_DEPLOY_KEY is set)`] },
  { dir: "packages/python", commands: (v) => [`# packages/python: the pushed tag v${v} is built and published to PyPI as runlight by .github/workflows/pypi.yml, with trusted publishing (once PYPI_ENABLED is true)`] },
  { dir: "packages/ruby", commands: (v) => [`(cd packages/ruby && gem build runlight.gemspec && gem push runlight-${v}.gem)`] },
  // Go modules publish by tag: a module in a subdirectory is versioned by a
  // tag with that prefix, so the release commit also gets packages/go/vX.Y.Z,
  // and the Go proxy serves it once anyone asks. The chi and Echo adapters
  // and the command are modules of their own, each tagged with its directory
  // at the same version. packages/go/dbtest holds tests only and is never
  // tagged. runlight.sh answers the go command's lookups (site/build.mjs).
  { dir: "packages/go", commands: (v) => [
    ...["", "chi/", "echo/", "cmd/runlight/"].map((sub) =>
      `git tag -a packages/go/${sub}v${v} -m "Release ${v} (Go${sub ? `, ${sub.slice(0, -1)}` : ""})" v${v}^{} && git push origin packages/go/${sub}v${v}`),
    `# packages/go: then GOPROXY=https://proxy.golang.org go list -m runlight.sh/go@v${v} runlight.sh/go/chi@v${v} runlight.sh/go/echo@v${v} runlight.sh/go/cmd/runlight@v${v} makes the proxy fetch them (once runlight.sh serves the go-import tags)`,
  ] },
  // Hex reads a package from the tarball `mix hex.publish` uploads, so the
  // package needs no tag of its own. .github/workflows/hex.yml publishes it
  // from the release tag.
  { dir: "packages/elixir", commands: (v) => [`# packages/elixir: the pushed tag v${v} is published to Hex as runlight, with its docs, by .github/workflows/hex.yml (once HEX_ENABLED is true); by hand, (cd packages/elixir && mix hex.publish)`] },
  { dir: "plugins/wordpress", commands: (v) => [`# plugins/wordpress: the pushed tag v${v} gets a GitHub release with its CHANGELOG.md section as notes and the plugin's zip attached as runlight-${v}.zip and runlight.zip, by .github/workflows/release.yml (once RELEASE_ENABLED is true)`] },
  { dir: "plugins/drupal", commands: (v) => [`# plugins/drupal: the pushed tag is split to drupal.org's repository as the tag ${v} on the branch ${v.split(".").slice(0, 2).join(".")}.x by .github/workflows/php-plugins-split.yml (once DRUPAL_SPLIT_ENABLED is true); then make the drupal.org release from the ${v} tag`] },
  { dir: "plugins/craft", commands: (v) => [`# plugins/craft: the pushed tag v${v} is split to phillips-jon/runlight-craft, which Packagist and the Craft Plugin Store read, by .github/workflows/php-plugins-split.yml (once CRAFT_SPLIT_ENABLED is true)`] },
];

/** Folders that do not ship on their own, and why. */
export const UNPUBLISHED = {
  "packages/dashboard": "built into the SDK",
  "packages/tracker": "built into the SDK",
};

/** Files the steps regenerate, reported by --dry-run. */
const REGENERATED = ["package-lock.json", "packages/php/assets/build.json, packages/python/src/runlight/assets/build.json, packages/ruby/assets/build.json, packages/go/internal/assets/build.json, and packages/elixir/priv/assets/build.json (written again from the SDK's VERSION, the same as the edits above)"];

const ROOT = process.cwd();
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/;
const USAGE = "usage: node scripts/release.mjs <version> [--dry-run] [--branch <name>]";

function fail(message) {
  console.error(`release: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = { version: null, dryRun: false, branch: "main" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--branch") {
      const next = argv[++i];
      if (next === undefined || next.startsWith("--")) fail(`${arg} needs a value`);
      options.branch = next;
    } else if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      process.exit(0);
    } else if (arg.startsWith("--")) fail(`unknown option ${arg}`);
    else if (options.version === null) options.version = arg.replace(/^v/, "");
    else fail(`unexpected argument ${arg}`);
  }
  if (options.version === null) fail(USAGE);
  return options;
}

/** Semver precedence: negative, zero or positive, as a is lower, equal or higher. Build metadata is ignored. */
export function compareVersions(a, b) {
  const [, ...pa] = SEMVER.exec(a);
  const [, ...pb] = SEMVER.exec(b);
  for (let i = 0; i < 3; i++) {
    const d = Number(pa[i]) - Number(pb[i]);
    if (d !== 0) return d;
  }
  const [ra, rb] = [pa[3], pb[3]];
  if (ra === undefined || rb === undefined) return ra === rb ? 0 : ra === undefined ? 1 : -1;
  const ia = ra.split(".");
  const ib = rb.split(".");
  for (let i = 0; i < Math.max(ia.length, ib.length); i++) {
    if (ia[i] === undefined) return -1;
    if (ib[i] === undefined) return 1;
    const na = /^\d+$/.test(ia[i]);
    const nb = /^\d+$/.test(ib[i]);
    if (na && nb) {
      const d = Number(ia[i]) - Number(ib[i]);
      if (d !== 0) return d;
    } else if (na !== nb) return na ? -1 : 1;
    else if (ia[i] !== ib[i]) return ia[i] < ib[i] ? -1 : 1;
  }
  return 0;
}

function git(...args) {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trimEnd();
}

function read(file) {
  return readFileSync(path.join(ROOT, file), "utf8");
}

/**
 * Every folder under packages/ and plugins/ must be versioned or say why it
 * is not, so a new package is not released at a stale version, and must ship
 * or say why it does not, so it is not left unshipped. Returns the problems.
 */
export function tableProblems(root = ROOT) {
  const dirs = ["packages", "plugins"].flatMap((parent) =>
    readdirSync(path.join(root, parent))
      .filter((d) => statSync(path.join(root, parent, d)).isDirectory())
      .map((d) => `${parent}/${d}`),
  );
  const problems = [];
  const unversioned = dirs.filter((d) => !VERSIONED.some((row) => row.file.startsWith(`${d}/`)) && !(d in UNVERSIONED));
  if (unversioned.length > 0) problems.push(`no VERSIONED or UNVERSIONED row for ${unversioned.join(", ")}; add the file that holds its version, or why it has none, to scripts/release.mjs`);
  const unpublished = dirs.filter((d) => !PUBLISH.some((row) => row.dir === d) && !(d in UNPUBLISHED));
  if (unpublished.length > 0) problems.push(`no PUBLISH or UNPUBLISHED row for ${unpublished.join(", ")}; add how it ships, or why it does not, to scripts/release.mjs`);
  return problems;
}

/**
 * The edits to make, one per file, after checking every row holds the
 * current version. Throws when a row has no match or holds another version.
 */
export function planEdits(rows, readFile, current, next) {
  const edits = new Map();
  for (const { file, pattern } of rows) {
    const before = edits.get(file)?.after ?? readFile(file);
    const matches = pattern.global ? [...before.matchAll(pattern)] : [pattern.exec(before)].filter(Boolean);
    if (matches.length === 0) throw new Error(`${file}: no match for ${pattern}; update VERSIONED in scripts/release.mjs`);
    for (const match of matches) if (match[2] !== current) throw new Error(`${file} says ${match[2]}, not ${current}; bring it in step first`);
    const after = before.replace(pattern, (_, head, _version, tail) => `${head}${next}${tail}`);
    const lines = matches.map((match) => [match[0], `${match[1]}${next}${match[3]}`]);
    edits.set(file, { before: edits.get(file)?.before ?? before, after, lines: [...(edits.get(file)?.lines ?? []), ...lines] });
  }
  return edits;
}

/**
 * Lines that name a version which is not the release's, though it may look
 * like it: the MCP server's fallback for a build.json with no version, and
 * the Elixir install line's requirement, which admits any release.
 */
const NOT_THE_RELEASE = [
  { file: "packages/php/src/Mcp.php", line: /\?\? '0\.0\.0'\);$/ },
  ...["packages/elixir/README.md", "site/docs/elixir.md"].map((file) => ({ file, line: /\{:runlight, ">= 0\.0\.0"\}/ })),
];

/** Tracked files, outside the table and the regenerated ones, that still mention the old version. */
function strays(current) {
  const skip = new Set([...VERSIONED.map((row) => row.file), ...MARKDOWN_CHANGELOGS, ROOT_CHANGELOG, "package-lock.json", "scripts/release.mjs", "scripts/release.test.mjs"]);
  let found = [];
  try {
    // A version inside a longer dotted number (Chrome/129.0.0.0) is not one.
    // go.sum lists the Go modules' requirements, whose pseudo-versions
    // (v0.0.0-20240606120523-5a60cdf6a761) are never Runlight's.
    const escaped = current.replace(/\./g, "\\.");
    found = git("grep", "-n", "-I", "-P", `(?<![.\\d])${escaped}(?![.\\d])`, "--", ".", ":!package-lock.json", ":!**/go.sum").split("\n");
  } catch {}
  const known = (line) => {
    const [file, , ...rest] = line.split(":");
    return NOT_THE_RELEASE.some((row) => row.file === file && row.line.test(rest.join(":")));
  };
  return found.filter((line) => line && !skip.has(line.split(":")[0]) && !known(line)).map((line) => (line.length > 160 ? `${line.slice(0, 157)}...` : line));
}

/** Whether PHP, which builds the WordPress plugin's zip, is on the PATH with the zip extension. */
function hasPhpZip() {
  return spawnSync("php", ["-r", "exit(class_exists('ZipArchive') ? 0 : 1);"], { cwd: ROOT, encoding: "utf8" }).status === 0;
}

function shown(cmd, args, { cwd = ROOT, env = {} } = {}) {
  const vars = Object.entries(env).map(([k, v]) => `${k}=${v} `).join("");
  return `${cwd === ROOT ? "" : `(cd ${path.relative(ROOT, cwd) || cwd}) `}${vars}${[cmd, ...args].join(" ")}`;
}

function run(label, cmd, args, opts = {}) {
  console.log(`\n== ${label}\n$ ${shown(cmd, args, opts)}`);
  const result = spawnSync(cmd, args, { cwd: opts.cwd ?? ROOT, env: { ...process.env, ...opts.env }, stdio: "inherit" });
  if (result.status !== 0) {
    fail(`${label} failed. Nothing is committed; the working tree holds the bump so far (\`git restore .\` drops it).`);
  }
}

/** Run as a script (not imported by its tests): cut the release. */
function main() {
  const options = parseArgs(process.argv.slice(2));
  const next = options.version;
  if (!SEMVER.test(next)) fail(`${next} is not a valid semver version`);
  if (next.includes("+")) fail(`${next} has build metadata; release without the +...`);
  const current = JSON.parse(read("packages/sdk/package.json")).version;
  if (compareVersions(next, current) <= 0) fail(`${next} is not greater than the current ${current}`);

  const problems = tableProblems();
  if (problems.length > 0) fail(problems.join("\n"));
  const branch = git("rev-parse", "--abbrev-ref", "HEAD");
  if (branch !== options.branch) fail(`on ${branch}, not ${options.branch}${options.branch === "main" ? " (--branch overrides, for testing)" : ""}`);
  const dirty = git("status", "--porcelain", "--untracked-files=no");
  if (dirty !== "") fail(`the working tree has changes; commit or stash them first:\n${dirty}`);
  const tag = `v${next}`;
  if (git("tag", "--list", tag) !== "") fail(`tag ${tag} already exists`);

  let edits;
  try {
    edits = planEdits(VERSIONED, read, current, next);
  } catch (error) {
    fail(error.message);
  }
  const date = today();
  const readme = edits.get(README_CHANGELOG);
  if (!readme) fail(`${README_CHANGELOG} is not in VERSIONED`);
  const changes = [[README_CHANGELOG, readme, (text) => addReadmeChangelog(text, next, README_CHANGELOG), '"= Unreleased ="']];
  for (const file of [...MARKDOWN_CHANGELOGS, ROOT_CHANGELOG]) {
    if (!edits.has(file)) {
      const text = read(file);
      edits.set(file, { before: text, after: text, lines: [] });
    }
    const add = file === ROOT_CHANGELOG ? addRootChangelog : addMarkdownChangelog;
    changes.push([file, edits.get(file), (text) => add(text, next, date, file), '"## Unreleased"']);
  }
  for (const [file, edit, add, heading] of changes) {
    let result;
    try {
      result = add(edit.after);
    } catch (error) {
      fail(error.message);
    }
    edit.after = result.text;
    edit.lines.push(["Changelog", result.change]);
    if (!result.written) console.log(`Note: ${file} has no ${heading} section, so the release adds a placeholder changelog entry; edit it before tagging, or write the notes under ${heading} next time.\n`);
  }

  const php = hasPhpZip();
  const zipDir = options.dryRun ? path.join(os.tmpdir(), "runlight-wordpress-XXXXXX") : mkdtempSync(path.join(os.tmpdir(), "runlight-wordpress-"));
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const databases = ["RUNLIGHT_TEST_PG", "RUNLIGHT_TEST_MYSQL"].filter((name) => process.env[name]);
  const steps = [
    ["Refresh package-lock.json", npm, ["install", "--no-audit", "--no-fund"]],
    ["Write packages/php/assets", npm, ["run", "php-assets"]],
    ["Write packages/python/src/runlight/assets", npm, ["run", "python-assets"]],
    ["Write packages/ruby/assets", npm, ["run", "ruby-assets"]],
    ["Write packages/go/internal/assets", npm, ["run", "go-assets"]],
    ["Write packages/elixir/priv/assets", npm, ["run", "elixir-assets"]],
    ["Check", npm, ["run", "check"]],
    ["Build", npm, ["run", "build"]],
    ["Pack, install and load the npm packages", npm, ["run", "check:packages"]],
    ...(php ? [["Build the WordPress plugin's zip", "php", ["plugins/wordpress/build.php", zipDir]]] : []),
  ];
  const leftovers = strays(current);

  console.log(`Release ${current} -> ${next} on ${branch}${options.dryRun ? " (dry run: nothing is written)" : ""}\n`);
  for (const [file, { lines }] of edits) {
    console.log(file);
    for (const [before, after] of lines) console.log(`  - ${before.trim()}\n  + ${after.trim()}`);
  }
  console.log(`\nRegenerated by the steps below: ${REGENERATED.join(", ")}`);
  if (leftovers.length > 0) {
    console.log(`\nStill mentioning ${current} (not in VERSIONED; check whether they should move):`);
    for (const line of leftovers) console.log(`  ${line}`);
  }
  if (databases.length === 2) console.log("\nRUNLIGHT_TEST_PG and RUNLIGHT_TEST_MYSQL are set, so the check runs the Postgres and MySQL tests.");
  else console.log(`\n${databases.length === 0 ? "Neither RUNLIGHT_TEST_PG nor RUNLIGHT_TEST_MYSQL is set" : `Only ${databases[0]} is set`}, so the check skips ${databases.length === 0 ? "the Postgres and MySQL tests" : "the other database's tests"}. CI runs them, and the tag's workflows wait for CI to pass.`);
  if (!php) console.log("No PHP with the zip extension found; skipping the WordPress zip. release.yml builds it from the tag.");

  if (options.dryRun) {
    console.log("\nWould run:");
    for (const [label, cmd, args, opts = {}] of steps) console.log(`  ${label}: ${shown(cmd, args, opts)}`);
    console.log(`  Commit: git add -u && git commit -m "Release ${next}"`);
    console.log(`  Tag: git tag -a ${tag} -m "Release ${next}"`);
  } else {
    for (const [file, { after }] of edits) writeFileSync(path.join(ROOT, file), after);
    for (const [label, cmd, args, opts = {}] of steps) run(label, cmd, args, opts);
    const untracked = git("status", "--porcelain").split("\n").filter((line) => line.startsWith("??"));
    if (untracked.length > 0) console.log(`\nLeft out of the commit (untracked):\n${untracked.join("\n")}`);
    git("add", "-u");
    execFileSync("git", ["commit", "-m", `Release ${next}`], { cwd: ROOT, stdio: "inherit" });
    git("tag", "-a", tag, "-m", `Release ${next}`);
    console.log(`\nCommitted "Release ${next}" and tagged ${tag}. Nothing is pushed or published.`);
  }

  console.log(`\nNext, by hand:\n  git push origin ${branch} ${tag}\n  # The tag's workflows wait for CI to pass on this commit (.github/workflows/ci-passed.yml); publish to npm once it has.`);
  for (const { commands } of PUBLISH) for (const command of commands(next)) console.log(`  ${command}`);
  console.log("  # Once both packages exist on npm, a later release can publish them from a workflow with npm's trusted publishing instead of by hand.");
  if (!options.dryRun) rmSync(zipDir, { recursive: true, force: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
