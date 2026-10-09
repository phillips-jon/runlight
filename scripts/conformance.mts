// Runs the HTTP conformance scenarios against the TypeScript implementation and
// writes their answers to conformance/http.json. Run it after changing behaviour
// on purpose; the SDK's tests fail until the file matches again.
import { writeFileSync } from "node:fs";
import { FORMAT, play } from "../packages/sdk/test/http-conformance.ts";
import { SCENARIOS } from "../packages/sdk/test/http-scenarios.ts";

const scenarios = [];
for (const scenario of SCENARIOS) {
  const answers = await play(scenario);
  scenarios.push({ ...scenario, steps: scenario.steps.map((step, i) => ({ ...step, expect: answers[i] })) });
}
const file = new URL("../conformance/http.json", import.meta.url);
writeFileSync(file, `${JSON.stringify({ description: FORMAT, scenarios }, null, 2)}\n`);
console.log(`conformance/http.json: ${scenarios.length} scenarios, ${scenarios.reduce((n, s) => n + s.steps.length, 0)} requests`);
