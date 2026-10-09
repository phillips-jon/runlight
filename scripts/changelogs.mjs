/**
 * The changelogs a release writes its section into, for scripts/release.mjs.
 * A released section is history (the WordPress plugin directory and the
 * Craft Plugin Store show it), so it is never rewritten: a release adds its
 * own. Notes written ahead under an "Unreleased" heading become the
 * release's section. Without them, a plugin's changelog gets a placeholder
 * saying the plugin carries Runlight's release, and the caller asks for
 * better notes.
 *
 * Each function returns { text, change, written }: the new text, what
 * changed (for --dry-run), and whether notes were written ahead. It throws
 * when the file has neither an Unreleased section nor a released section to
 * add the new one above.
 */

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** The WordPress readme: "= X.Y.Z =" sections under "== Changelog ==", "= Unreleased =" written ahead. */
export function addReadmeChangelog(text, next, file = "readme.txt") {
  if (new RegExp(`^= ${escape(next)} =$`, "m").test(text)) return { text, change: `= ${next} = is already there`, written: true };
  if (/^= Unreleased =$/m.test(text)) return { text: text.replace(/^= Unreleased =$/m, `= ${next} =`), change: `= Unreleased = -> = ${next} =`, written: true };
  const at = text.search(/^= \d+\.\d+\.\d+[^=]* =$/m);
  if (at < 0 || !/^== Changelog ==$/m.test(text.slice(0, at))) throw new Error(`${file}: no "= X.Y.Z =" section under "== Changelog ==" to add ${next} above`);
  const entry = `= ${next} =\n* Released with Runlight ${next}.\n\n`;
  return { text: text.slice(0, at) + entry + text.slice(at), change: `+ = ${next} = (a placeholder entry: write the plugin's notes)`, written: false };
}

/**
 * A CHANGELOG.md in the Craft Plugin Store's shape: "## X.Y.Z - YYYY-MM-DD"
 * sections, newest first, and "## Unreleased" written ahead. `date` is the
 * release's, YYYY-MM-DD.
 */
export function addMarkdownChangelog(text, next, date, file = "CHANGELOG.md") {
  const heading = `## ${next} - ${date}`;
  if (new RegExp(`^## ${escape(next)}(?: |$)`, "m").test(text)) return { text, change: `## ${next} is already there`, written: true };
  if (/^## Unreleased[ \t]*$/m.test(text)) return { text: text.replace(/^## Unreleased[ \t]*$/m, heading), change: `## Unreleased -> ${heading}`, written: true };
  const at = text.search(/^## v?\d+\.\d+\.\d+/m);
  if (at < 0) throw new Error(`${file}: no "## X.Y.Z - YYYY-MM-DD" section to add ${next} above`);
  const entry = `${heading}\n\n### Changed\n- Released with Runlight ${next}.\n\n`;
  return { text: text.slice(0, at) + entry + text.slice(at), change: `+ ${heading} (a placeholder entry: write the plugin's notes)`, written: false };
}

/**
 * The project's own CHANGELOG.md at the root: "## Unreleased" becomes
 * "## X.Y.Z - YYYY-MM-DD", as in the Craft plugin's changelog. It is where a
 * release's notes are written, so a release without them is refused rather
 * than given a placeholder.
 */
export function addRootChangelog(text, next, date, file = "CHANGELOG.md") {
  if (new RegExp(`^## ${escape(next)}(?: |$)`, "m").test(text)) return { text, change: `## ${next} is already there`, written: true };
  if (!/^## Unreleased[ \t]*$/m.test(text)) throw new Error(`${file}: no "## Unreleased" section; write the release's notes there first`);
  const heading = `## ${next} - ${date}`;
  return { text: text.replace(/^## Unreleased[ \t]*$/m, heading), change: `## Unreleased -> ${heading}`, written: true };
}

/**
 * The section of a CHANGELOG.md for one version, without its heading, for a
 * GitHub release's notes (scripts/release-notes.mjs). Throws when there is none.
 */
export function sectionOf(text, version, file = "CHANGELOG.md") {
  const lines = text.split("\n");
  const start = lines.findIndex((line) => new RegExp(`^## ${escape(version)}(?: |$)`).test(line));
  if (start < 0) throw new Error(`${file}: no "## ${version}" section`);
  let end = lines.findIndex((line, i) => i > start && /^## /.test(line));
  if (end < 0) end = lines.length;
  const body = lines.slice(start + 1, end).join("\n").trim();
  if (body === "") throw new Error(`${file}: the "## ${version}" section is empty`);
  return `${body}\n`;
}

/** Today as YYYY-MM-DD in the local time zone, the date a release is cut. */
export function today(now = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}
