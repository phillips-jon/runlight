import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, test } from "node:test";
import { FORMAT, play, type Scenario } from "./http-conformance.js";
import { SCENARIOS } from "./http-scenarios.js";
import { STORES, cleanup, freshStore } from "./helpers.js";

after(cleanup);

const { description, scenarios } = JSON.parse(readFileSync(new URL("../../../conformance/http.json", import.meta.url), "utf8")) as { description: string; scenarios: Scenario[] };

for (const kind of STORES) {
  for (const scenario of scenarios) {
    test(`conformance (${kind}): ${scenario.name}`, async () => {
      const answers = await play(scenario, freshStore(kind));
      scenario.steps.forEach((step, i) => {
        assert.deepEqual(answers[i], step.expect, `${step.method} ${step.path} (step ${i + 1}). If this change is on purpose, run npm run conformance.`);
      });
    });
  }
}

test("conformance: the stored scenarios are the ones written in TypeScript", () => {
  const stored = scenarios.map((scenario) => ({ ...scenario, steps: scenario.steps.map(({ expect: _, ...step }) => step) }));
  assert.deepEqual(stored, JSON.parse(JSON.stringify(SCENARIOS)), "A scenario changed without the file. Run npm run conformance.");
  assert.equal(description, FORMAT, "The format's description changed without the file. Run npm run conformance.");
});
