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

test("a CMS plugin keeps its saved keys only while its Runlight address stays the same", (t) => {
  // WordPress's sanitize runs under PHP with stand-ins for the few WordPress functions it calls.
  const settings = new URL("../../../plugins/wordpress/includes/Settings.php", import.meta.url).pathname;
  const script = `
    namespace Runlight\\WordPress;
    define("ABSPATH", "/");
    $GLOBALS["saved"] = ["address" => "https://stats.example.com/runlight", "observe_key" => "rlo_saved", "dashboard_key" => "rl_saved"];
    function get_option($name, $default) { return $GLOBALS["saved"]; }
    function sanitize_text_field($v) { return trim($v); }
    function wp_unslash($v) { return $v; }
    function untrailingslashit($v) { return rtrim($v, "/"); }
    function esc_url_raw($v, $protocols) { return $v; }
    require ${JSON.stringify(settings)};
    $keys = [];
    foreach ([["https://stats.example.com/runlight", "", ""], ["https://evil.example/runlight", "", ""], ["https://other.example/runlight", "rlo_new", "rl_new"]] as [$address, $key, $dashboard]) {
      $saved = Settings::sanitize(["address" => $address, "observe_key" => $key, "dashboard_key" => $dashboard]);
      $keys[] = [$saved["observe_key"], $saved["dashboard_key"]];
    }
    echo json_encode($keys);
  `;
  let answer: string;
  try {
    answer = execFileSync("php", ["-r", script], { encoding: "utf8" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return t.skip("PHP is not installed");
    throw error;
  }
  assert.deepEqual(JSON.parse(answer), [["rlo_saved", "rl_saved"], ["", ""], ["rlo_new", "rl_new"]]);

  // Drupal's form runs too, with stand-ins for the form base class, its state, and the saved config.
  const drupal = new URL("../../../plugins/drupal/src/Form/SettingsForm.php", import.meta.url).pathname;
  const submit = `
    namespace Drupal\\Core\\Form {
      interface FormStateInterface { public function getValue($key); }
      class Config {
        public array $values = ["address" => "https://stats.example.com/runlight", "observe_key" => "rlo_saved", "dashboard_key" => "rl_saved"];
        public function get($key) { return $this->values[$key] ?? null; }
        public function set($key, $value) { $this->values[$key] = $value; return $this; }
        public function save() { return $this; }
      }
      abstract class ConfigFormBase {
        public static ?Config $saved = null;
        protected function config($name) { return self::$saved; }
        public function submitForm(array &$form, FormStateInterface $form_state): void {}
      }
    }
    namespace {
      require ${JSON.stringify(drupal)};
      class State implements Drupal\\Core\\Form\\FormStateInterface {
        public function __construct(private array $values) {}
        public function getValue($key) { return $this->values[$key] ?? ""; }
      }
      $keys = [];
      foreach ([["https://stats.example.com/runlight/", "", ""], ["https://evil.example/runlight", "", ""], ["https://other.example/runlight", "rlo_new", "rl_new"]] as [$address, $key, $dashboard]) {
        Drupal\\Core\\Form\\ConfigFormBase::$saved = new Drupal\\Core\\Form\\Config();
        $form = [];
        (new Drupal\\runlight\\Form\\SettingsForm())->submitForm($form, new State(["address" => $address, "observe_key" => $key, "dashboard_key" => $dashboard]));
        $keys[] = [Drupal\\Core\\Form\\ConfigFormBase::$saved->values["observe_key"], Drupal\\Core\\Form\\ConfigFormBase::$saved->values["dashboard_key"]];
      }
      echo json_encode($keys);
    }
  `;
  assert.deepEqual(JSON.parse(execFileSync("php", ["-r", submit], { encoding: "utf8" })), [["rlo_saved", "rl_saved"], ["", ""], ["rlo_new", "rl_new"]]);
});
