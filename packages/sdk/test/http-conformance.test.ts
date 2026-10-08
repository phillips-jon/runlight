import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { play, type Scenario } from "./http-conformance.js";

const { scenarios } = JSON.parse(readFileSync(new URL("../../../conformance/http.json", import.meta.url), "utf8")) as { scenarios: Scenario[] };

for (const scenario of scenarios) {
  test(`conformance: ${scenario.name}`, async () => {
    const answers = await play(scenario);
    scenario.steps.forEach((step, i) => {
      assert.deepEqual(answers[i], step.expect, `${step.method} ${step.path} (step ${i + 1}). If this change is on purpose, run npm run conformance.`);
    });
  });
}
