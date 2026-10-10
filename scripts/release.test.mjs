// scripts/release.mjs: the version edits it plans, the tables it checks, and
// dry runs of the whole script on a temporary copy of the repository.
//
//   node --test scripts/release.test.mjs
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { minorOf, planEdits, PUBLISH, tableProblems, UNPUBLISHED, UNVERSIONED, VERSIONED } from "./release.mjs";

const ROOT = path.resolve(import.meta.dirname, "..");
const readRepo = (file) => readFileSync(path.join(ROOT, file), "utf8");
const current = JSON.parse(readRepo("packages/sdk/package.json")).version;
const NEXT = `${Number(current.split(".")[0]) + 1}.0.0`;

test("the repository's files are in step with the release's version", () => {
  assert.doesNotThrow(() => planEdits(VERSIONED, readRepo, current, NEXT));
});

test("every folder under packages/ and plugins/ is versioned and shipped, or says why not", () => {
  assert.deepEqual(tableProblems(ROOT), []);
  for (const dir of Object.keys(UNVERSIONED)) assert.ok(!VERSIONED.some((row) => row.file.startsWith(`${dir}/`)), `${dir} is in VERSIONED and UNVERSIONED`);
  for (const dir of Object.keys(UNPUBLISHED)) assert.ok(!PUBLISH.some((row) => row.dir === dir), `${dir} is in PUBLISH and UNPUBLISHED`);
});

test("a release moves every version, and the MCP fixture's four serverInfo entries", () => {
  const edits = planEdits(VERSIONED, readRepo, current, NEXT);
  const after = (file) => edits.get(file).after;
  assert.equal(JSON.parse(after("packages/sdk/package.json")).version, NEXT);
  const server = JSON.parse(after("packages/server/package.json"));
  assert.equal(server.version, NEXT);
  assert.equal(server.dependencies["@runlight/sdk"], NEXT);
  assert.equal(JSON.parse(after("packages/php/assets/build.json")).version, NEXT);
  assert.equal(JSON.parse(after("packages/php/tests/fixtures/version.json")).version, NEXT);
  const mcp = after("packages/php/tests/fixtures/mcp.json");
  assert.equal(edits.get("packages/php/tests/fixtures/mcp.json").lines.length, 4);
  assert.ok(!mcp.includes(`\\"version\\":\\"${current}\\"`));
  // The JSON-RPC version beside them is not the release's.
  assert.equal(mcp.split('\\"version\\":\\"1\\"').length, readRepo("packages/php/tests/fixtures/mcp.json").split('\\"version\\":\\"1\\"').length);
  assert.match(after("plugins/wordpress/runlight.php"), new RegExp(`^ \\* Version: +${NEXT}$`, "m"));
  assert.ok(after("plugins/wordpress/runlight.php").includes(`define( 'RUNLIGHT_PLUGIN_VERSION', '${NEXT}' );`));
  assert.match(after("plugins/wordpress/readme.txt"), new RegExp(`^Stable tag: ${NEXT}$`, "m"));
});

test("the Java, .NET, and Rust versions move, and the Cargo install lines name the new minor", () => {
  const edits = planEdits(VERSIONED, readRepo, current, NEXT);
  const after = (file) => edits.get(file).after;
  assert.match(after("packages/java/pom.xml"), new RegExp(`<revision>${NEXT}</revision>`));
  assert.match(after("packages/dotnet/Directory.Build.props"), new RegExp(`<Version>${NEXT}</Version>`));
  const cargo = after("packages/rust/Cargo.toml");
  assert.match(cargo, new RegExp(`^version = "${NEXT}"$`, "m"));
  assert.ok(cargo.includes(`runlight = { path = "runlight", version = "=${NEXT}" }`));
  assert.ok(after("packages/rust/runlight/src/version.rs").includes(`pub const VERSION: &str = "${NEXT}";`));
  for (const file of ["packages/rust/README.md"]) {
    assert.equal(edits.get(file).lines.length, 2, file);
    assert.ok(after(file).includes(`runlight = { version = "${minorOf(NEXT)}"`), file);
    assert.ok(after(file).includes(`runlight-sqlx = { version = "${minorOf(NEXT)}"`), file);
  }
});

test("the Java install lines name the release, and the Hex ones its minor", () => {
  const edits = planEdits(VERSIONED, readRepo, current, NEXT);
  const after = (file) => edits.get(file).after;
  for (const file of ["packages/java/README.md"]) {
    assert.ok(after(file).includes(`implementation("sh.runlight:runlight:${NEXT}")`), file);
    assert.match(after(file), new RegExp(`<artifactId>runlight</artifactId>\\s*<version>${NEXT}</version>`), file);
  }
  for (const file of ["packages/elixir/README.md", "README.md"]) {
    assert.ok(after(file).includes(`{:runlight, "~> ${minorOf(NEXT)}"}`), file);
  }
});

test("an install line keeps its minor across a prerelease, and takes the next stable one", () => {
  const rows = [{ file: "x", pattern: /^(runlight = \{ version = ")([^"]+)(")/m, form: "minor" }];
  const at = (minor) => () => `runlight = { version = "${minor}" }\n`;
  assert.equal(planEdits(rows, at("0.1"), "0.1.0", "0.2.0-beta.1").get("x").after, 'runlight = { version = "0.1" }\n');
  assert.equal(planEdits(rows, at("0.1"), "0.2.0-beta.1", "0.2.0").get("x").after, 'runlight = { version = "0.2" }\n');
  assert.equal(planEdits(rows, at("0.1"), "0.1.0", "0.1.1").get("x").after, 'runlight = { version = "0.1" }\n');
  assert.throws(() => planEdits(rows, at("0.3"), "0.1.0", "0.2.0"), /x says 0\.3, not 0\.1/);
});

test("a file out of step is refused", () => {
  const read = (file) => (file === "packages/server/src/version.ts" ? 'export const VERSION = "0.0.9";\n' : readRepo(file));
  assert.throws(() => planEdits(VERSIONED, read, current, NEXT), /packages\/server\/src\/version\.ts says 0\.0\.9/);
  const gone = (file) => (file === "packages/sdk/src/version.ts" ? "export const V = 1;\n" : readRepo(file));
  assert.throws(() => planEdits(VERSIONED, gone, current, NEXT), /packages\/sdk\/src\/version\.ts: no match/);
});

// Dry runs on a temporary copy: the tracked files and new ones not ignored,
// as they are in the working tree, committed to a fresh repository on main.
let copy;
const git = (...args) => execFileSync("git", args, { cwd: copy, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.com", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.com" } });
const release = (...args) => {
  const env = { ...process.env };
  delete env.RUNLIGHT_TEST_PG;
  delete env.RUNLIGHT_TEST_MYSQL;
  const result = spawnSync(process.execPath, ["scripts/release.mjs", ...args], { cwd: copy, encoding: "utf8", env });
  return { status: result.status, out: result.stdout, err: result.stderr };
};

before(() => {
  copy = mkdtempSync(path.join(os.tmpdir(), "runlight-release-test-"));
  const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], { cwd: ROOT, encoding: "utf8" }).split("\0").filter(Boolean);
  for (const file of files) {
    const from = path.join(ROOT, file);
    if (!existsSync(from)) continue;
    mkdirSync(path.dirname(path.join(copy, file)), { recursive: true });
    copyFileSync(from, path.join(copy, file));
  }
  git("init", "-q", "-b", "main");
  git("add", "-A");
  git("commit", "-q", "-m", "copy");
});

after(() => rmSync(copy, { recursive: true, force: true }));

test("a dry run shows every edit and command, and writes nothing", () => {
  const { status, out, err } = release("0.1.0", "--dry-run");
  assert.equal(status, 0, err);
  assert.match(out, /^Release 0\.0\.0 -> 0\.1\.0 on main \(dry run: nothing is written\)$/m);
  for (const { file } of VERSIONED) assert.match(out, new RegExp(`^${file.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"), file);
  assert.match(out, /^ {2}\+ ## Unreleased -> ## 0\.1\.0 - \d{4}-\d{2}-\d{2}$/m);
  assert.match(out, /^ {2}\+ = Unreleased = -> = 0\.1\.0 =$/m);
  assert.doesNotMatch(out, /placeholder/);
  assert.doesNotMatch(out, /Still mentioning/);
  assert.match(out, /Neither RUNLIGHT_TEST_PG nor RUNLIGHT_TEST_MYSQL is set/);
  assert.match(out, /^ {2}Check: npm run check$/m);
  assert.match(out, /^ {2}Pack, install and load the npm packages: npm run check:packages$/m);
  assert.match(out, /^ {2}Tag: git tag -a v0\.1\.0 -m "Release 0\.1\.0"$/m);
  assert.match(out, /^ {2}git push origin main v0\.1\.0$/m);
  const sdk = out.indexOf("npm publish --workspace packages/sdk --access public");
  const server = out.indexOf("npm publish --workspace packages/server --access public");
  assert.ok(sdk > 0 && server > sdk, "the SDK is published before the server");
  assert.match(out, /ghcr\.io\/runlightsh\/runlight as 0\.1\.0 and latest/);
  assert.match(out, /drupal\.org's repository as the tag 0\.1\.0 on the branch 0\.1\.x/);
  assert.equal(git("status", "--porcelain"), "");
  assert.equal(git("tag", "--list"), "");
});

test("a prerelease is not tagged latest", () => {
  const { status, out, err } = release("0.1.0-beta.1", "--dry-run");
  assert.equal(status, 0, err);
  assert.match(out, /runlight as 0\.1\.0-beta\.1, by/);
});

test("a release refuses a version no higher than the current one, or no version", () => {
  assert.match(release("0.0.0", "--dry-run").err, /0\.0\.0 is not greater than the current 0\.0\.0/);
  assert.match(release("1.0", "--dry-run").err, /1\.0 is not a valid semver version/);
  assert.match(release("1.0.0+build.1", "--dry-run").err, /build metadata/);
  assert.match(release("--dry-run").err, /usage/);
});

test("a release refuses another branch, a dirty tree, or a tag already there", () => {
  git("checkout", "-q", "-b", "other");
  try {
    assert.match(release("0.1.0", "--dry-run").err, /on other, not main/);
    assert.equal(release("0.1.0", "--dry-run", "--branch", "other").status, 0);
  } finally {
    git("checkout", "-q", "main");
    git("branch", "-q", "-D", "other");
  }
  writeFileSync(path.join(copy, "README.md"), "changed\n");
  try {
    assert.match(release("0.1.0", "--dry-run").err, /the working tree has changes/);
  } finally {
    git("checkout", "--", "README.md");
  }
  git("tag", "v0.1.0");
  try {
    assert.match(release("0.1.0", "--dry-run").err, /tag v0\.1\.0 already exists/);
  } finally {
    git("tag", "-d", "v0.1.0");
  }
});

test("a release refuses a new folder with no row in the tables", () => {
  mkdirSync(path.join(copy, "plugins", "joomla"));
  try {
    const { status, err } = release("0.1.0", "--dry-run");
    assert.equal(status, 1);
    assert.match(err, /no VERSIONED or UNVERSIONED row for plugins\/joomla/);
    assert.match(err, /no PUBLISH or UNPUBLISHED row for plugins\/joomla/);
  } finally {
    rmSync(path.join(copy, "plugins", "joomla"), { recursive: true });
  }
});

test("a release refuses a CHANGELOG.md without an Unreleased section", () => {
  const file = path.join(copy, "CHANGELOG.md");
  writeFileSync(file, readFileSync(file, "utf8").replace("## Unreleased", "## Later"));
  git("commit", "-q", "-am", "no notes");
  try {
    assert.match(release("0.1.0", "--dry-run").err, /CHANGELOG\.md: no "## Unreleased" section/);
  } finally {
    git("reset", "-q", "--hard", "HEAD~1");
  }
});

test("a version left behind outside the table is listed", () => {
  writeFileSync(path.join(copy, "packages/stray.md"), 'Install 0.0.0 now. Chrome/129.0.0.0 is not a version.\nrunlight = { version = "0.0" }\n');
  git("add", "-A");
  git("commit", "-q", "-m", "stray");
  try {
    const { status, out } = release("0.1.0", "--dry-run");
    assert.equal(status, 0);
    assert.match(out, /Still mentioning 0\.0\.0/);
    assert.match(out, /^ {2}packages\/stray\.md:1:Install 0\.0\.0 now/m);
    assert.match(out, /^ {2}packages\/stray\.md:2:runlight = \{ version = "0\.0" \}/m);
    assert.equal(out.match(/^ {2}\S+:\d+:/gm).length, 2, "only the strays, not the user agent");
  } finally {
    git("reset", "-q", "--hard", "HEAD~1");
  }
});
