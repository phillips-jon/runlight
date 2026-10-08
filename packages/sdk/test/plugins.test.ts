import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { AI_AGENTS } from "../src/data/agents.js";

const PLUGINS = ["wordpress/includes/Agents.php", "drupal/src/Agents.php", "craft/src/Agents.php"];

test("each CMS plugin knows every AI agent the server records, and no others", () => {
  const expected = AI_AGENTS.map((a) => a.token).sort();
  for (const file of PLUGINS) {
    const source = readFileSync(new URL(`../../../plugins/${file}`, import.meta.url), "utf8");
    const list = /TOKENS\s*=\s*(?:array\(|\[)([\s\S]*?)(?:\)|\]);/.exec(source)?.[1] ?? "";
    const tokens = [...list.matchAll(/'([^']+)'/g)].map((m) => m[1]!).sort();
    assert.deepEqual(tokens, expected, `${file} is out of step with src/data/agents.ts`);
  }
});

test("a CMS plugin keeps a saved observe key only while its Runlight address stays the same", (t) => {
  // WordPress's sanitize runs under PHP with stand-ins for the few WordPress functions it calls.
  const settings = new URL("../../../plugins/wordpress/includes/Settings.php", import.meta.url).pathname;
  const script = `
    namespace Runlight\\WordPress;
    define("ABSPATH", "/");
    $GLOBALS["saved"] = ["address" => "https://stats.example.com/runlight", "observe_key" => "rlo_saved"];
    function get_option($name, $default) { return $GLOBALS["saved"]; }
    function sanitize_text_field($v) { return trim($v); }
    function wp_unslash($v) { return $v; }
    function untrailingslashit($v) { return rtrim($v, "/"); }
    function esc_url_raw($v, $protocols) { return $v; }
    require ${JSON.stringify(settings)};
    echo json_encode([
      Settings::sanitize(["address" => "https://stats.example.com/runlight", "observe_key" => ""])["observe_key"],
      Settings::sanitize(["address" => "https://evil.example/runlight", "observe_key" => ""])["observe_key"],
      Settings::sanitize(["address" => "https://other.example/runlight", "observe_key" => "rlo_new"])["observe_key"],
    ]);
  `;
  let answer: string;
  try {
    answer = execFileSync("php", ["-r", script], { encoding: "utf8" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return t.skip("PHP is not installed");
    throw error;
  }
  assert.deepEqual(JSON.parse(answer), ["rlo_saved", "", "rlo_new"]);

  // Drupal's form runs only inside Drupal, so its rule is read from the source.
  const drupal = readFileSync(new URL("../../../plugins/drupal/src/Form/SettingsForm.php", import.meta.url), "utf8");
  assert.match(drupal, /\$kept = \$address === \(string\) \$config->get\('address'\) \? \(string\) \$config->get\('observe_key'\) : '';/);
  assert.match(drupal, /->set\('observe_key', \$key === '' \? \$kept : \$key\)/);
});
