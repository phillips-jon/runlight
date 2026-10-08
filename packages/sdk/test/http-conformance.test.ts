import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { SCENARIOS, play, type Scenario } from "./http-conformance.js";

const { scenarios } = JSON.parse(readFileSync(new URL("../../../conformance/http.json", import.meta.url), "utf8")) as { scenarios: Scenario[] };

for (const scenario of scenarios) {
  test(`conformance: ${scenario.name}`, async () => {
    const answers = await play(scenario);
    scenario.steps.forEach((step, i) => {
      assert.deepEqual(answers[i], step.expect, `${step.method} ${step.path} (step ${i + 1}). If this change is on purpose, run npm run conformance.`);
    });
  });
}

test("conformance: the stored scenarios are the ones written in TypeScript", () => {
  const stored = scenarios.map((scenario) => ({ ...scenario, steps: scenario.steps.map(({ expect: _, ...step }) => step) }));
  assert.deepEqual(stored, JSON.parse(JSON.stringify(SCENARIOS)), "A scenario changed without the file. Run npm run conformance.");
});
