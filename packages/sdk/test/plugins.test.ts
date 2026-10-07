import assert from "node:assert/strict";
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
