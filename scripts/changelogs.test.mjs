// The changelog sections scripts/release.mjs writes, and the notes
// scripts/release-notes.mjs reads back.
//
//   node --test scripts/changelogs.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { addMarkdownChangelog, addReadmeChangelog, addRootChangelog, sectionOf, today } from "./changelogs.mjs";
import { compareVersions } from "./release.mjs";

const MARKDOWN = "# Release Notes for Runlight\n\n## Unreleased\n\n### Fixed\n- A thing.\n\n## 1.2.3 - 2026-09-30\n\n### Changed\n- Released with Runlight 1.2.3.\n";

test("a CHANGELOG.md's Unreleased section becomes the release's, dated", () => {
  const { text, change, written } = addMarkdownChangelog(MARKDOWN, "1.3.0", "2026-10-01");
  assert.equal(text, MARKDOWN.replace("## Unreleased", "## 1.3.0 - 2026-10-01"));
  assert.equal(change, "## Unreleased -> ## 1.3.0 - 2026-10-01");
  assert.equal(written, true);
});

test("the first release turns an Unreleased section with nothing released below it", () => {
  const first = "# Release Notes for Runlight\n\n## Unreleased\n\n### Added\n- A thing.\n";
  assert.equal(addMarkdownChangelog(first, "0.1.0", "2026-10-09").text, first.replace("## Unreleased", "## 0.1.0 - 2026-10-09"));
});

test("without an Unreleased section, a placeholder goes above the newest release", () => {
  const released = MARKDOWN.replace("## Unreleased\n\n### Fixed\n- A thing.\n\n", "");
  const { text, change, written } = addMarkdownChangelog(released, "1.3.0", "2026-10-01");
  assert.equal(text, "# Release Notes for Runlight\n\n## 1.3.0 - 2026-10-01\n\n### Changed\n- Released with Runlight 1.3.0.\n\n## 1.2.3 - 2026-09-30\n\n### Changed\n- Released with Runlight 1.2.3.\n");
  assert.match(change, /placeholder/);
  assert.equal(written, false);
});

test("a release already in a CHANGELOG.md is left as it is", () => {
  const { text, written } = addMarkdownChangelog(MARKDOWN, "1.2.3", "2026-10-01");
  assert.equal(text, MARKDOWN);
  assert.equal(written, true);
});

test("a CHANGELOG.md with neither an Unreleased nor a released section is refused", () => {
  assert.throws(() => addMarkdownChangelog("# Release Notes for Runlight\n", "1.3.0", "2026-10-01", "x/CHANGELOG.md"), /x\/CHANGELOG\.md: no "## X\.Y\.Z/);
});

test("the WordPress readme's = Unreleased = becomes = X.Y.Z =, and a placeholder without it", () => {
  const readme = "== Changelog ==\n\n= Unreleased =\n* A thing.\n\n= 1.2.3 =\n* Released with Runlight 1.2.3.\n";
  assert.equal(addReadmeChangelog(readme, "1.3.0").text, readme.replace("= Unreleased =", "= 1.3.0 ="));
  const released = readme.replace("= Unreleased =\n* A thing.\n\n", "");
  const { text, written } = addReadmeChangelog(released, "1.3.0");
  assert.equal(text, released.replace("= 1.2.3 =", "= 1.3.0 =\n* Released with Runlight 1.3.0.\n\n= 1.2.3 ="));
  assert.equal(written, false);
  assert.throws(() => addReadmeChangelog("== Changelog ==\n", "1.3.0", "x/readme.txt"), /x\/readme\.txt: no "= X\.Y\.Z =" section/);
});

test("the root CHANGELOG.md's Unreleased section becomes the release's, and a release without one is refused", () => {
  const root = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- A thing.\n";
  const { text, change, written } = addRootChangelog(root, "1.0.0", "2026-10-01");
  assert.equal(text, root.replace("## Unreleased", "## 1.0.0 - 2026-10-01"));
  assert.equal(change, "## Unreleased -> ## 1.0.0 - 2026-10-01");
  assert.equal(written, true);
  assert.equal(addRootChangelog(text, "1.0.0", "2026-10-02").text, text);
  assert.throws(() => addRootChangelog(text, "1.0.1", "2026-10-02"), /CHANGELOG\.md: no "## Unreleased" section/);
});

test("a release's notes are its section, without the heading, up to the next release", () => {
  const text = "# Changelog\n\nIntro.\n\n## 1.1.0 - 2026-10-02\n\n### Added\n\n- New.\n\n## 1.0.0 - 2026-10-01\n\n- Old.\n";
  assert.equal(sectionOf(text, "1.1.0"), "### Added\n\n- New.\n");
  assert.equal(sectionOf(text, "1.0.0"), "- Old.\n");
  assert.throws(() => sectionOf(text, "1.0.1"), /no "## 1\.0\.1" section/);
  assert.throws(() => sectionOf(text, "1.1"), /no "## 1\.1" section/);
  assert.throws(() => sectionOf("## 1.0.0 - 2026-10-01\n\n## 0.9.0 - 2026-09-01\n- x\n", "1.0.0"), /is empty/);
});

test("today is the local date", () => {
  assert.equal(today(new Date(2026, 0, 5, 23, 59)), "2026-01-05");
});

test("compareVersions orders by Semantic Versioning's precedence", () => {
  const sorted = ["0.9.0", "0.10.0-alpha", "0.10.0-alpha.1", "0.10.0-alpha.beta", "0.10.0-beta", "0.10.0-beta.2", "0.10.0-beta.11", "0.10.0-rc.1", "0.10.0", "0.10.1", "1.0.0"];
  for (let i = 1; i < sorted.length; i++) {
    assert.ok(compareVersions(sorted[i - 1], sorted[i]) < 0, `${sorted[i - 1]} < ${sorted[i]}`);
    assert.ok(compareVersions(sorted[i], sorted[i - 1]) > 0, `${sorted[i]} > ${sorted[i - 1]}`);
  }
  assert.equal(compareVersions("1.2.3-beta.1", "1.2.3-beta.1"), 0);
});

/** Dated releases, newest first, under at most one Unreleased. Before the first release there may be none. */
function checkChangelog(text) {
  const headings = [...text.matchAll(/^## (.*)$/gm)].map((m) => m[1]);
  assert.ok(headings.filter((h) => h === "Unreleased").length <= 1, "at most one Unreleased");
  if (headings.includes("Unreleased")) assert.equal(headings[0], "Unreleased", "Unreleased comes first");
  const released = headings.filter((h) => h !== "Unreleased");
  assert.ok(headings.length > 0, "a section to release");
  for (const h of released) assert.match(h, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)? - \d{4}-\d{2}-\d{2}$/);
  const versions = released.map((h) => h.split(" ")[0]);
  for (let i = 1; i < versions.length; i++) assert.ok(compareVersions(versions[i - 1], versions[i]) > 0, `${released[i - 1]} before ${released[i]}`);
}

test("a prerelease is cut, then its release, and the changelog still checks", () => {
  const beta = addMarkdownChangelog(MARKDOWN, "1.3.0-beta.1", "2026-10-01");
  assert.match(beta.text, /^## 1\.3\.0-beta\.1 - 2026-10-01$/m);
  checkChangelog(beta.text);
  const beta2 = addMarkdownChangelog(beta.text, "1.3.0-beta.2", "2026-10-02");
  checkChangelog(beta2.text);
  const final = addMarkdownChangelog(beta2.text, "1.3.0", "2026-10-03");
  assert.match(final.text, /^## 1\.3\.0 - 2026-10-03\n[^]*^## 1\.3\.0-beta\.2 - /m);
  assert.equal(final.written, false, "1.3.0-beta.2's section does not count as 1.3.0's");
  checkChangelog(final.text);
  assert.throws(() => checkChangelog(addMarkdownChangelog(final.text, "1.3.0-rc.1", "2026-10-04").text), /1\.3\.0-rc\.1 - 2026-10-04 before 1\.3\.0 -/);
});

for (const file of ["CHANGELOG.md", "plugins/craft/CHANGELOG.md"]) {
  test(`${file} has dated releases, newest first, under at most one Unreleased`, () => {
    checkChangelog(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
  });
}

test("the WordPress readme's changelog starts with Unreleased or the plugin's version", () => {
  const readme = readFileSync(new URL("../plugins/wordpress/readme.txt", import.meta.url), "utf8");
  const stable = /^Stable tag: (\S+)$/m.exec(readme)?.[1];
  const first = /^== Changelog ==\n+= ([^=]+) =$/m.exec(readme)?.[1];
  assert.ok(first === "Unreleased" || first === stable, `the first changelog entry is ${first}, the Stable tag ${stable}`);
});
