// Runs the HTTP conformance scenarios against the TypeScript implementation and
// writes their answers to conformance/http.json. Run it after changing behaviour
// on purpose; the SDK's tests fail until the file matches again.
import { writeFileSync } from "node:fs";
import { SCENARIOS, play } from "../packages/sdk/test/http-conformance.ts";

const scenarios = [];
for (const scenario of SCENARIOS) {
  const answers = await play(scenario);
  scenarios.push({ ...scenario, steps: scenario.steps.map((step, i) => ({ ...step, expect: answers[i] })) });
}
const file = new URL("../conformance/http.json", import.meta.url);
writeFileSync(
  file,
  `${JSON.stringify(
    {
      description:
        "HTTP requests to a fresh Runlight on a fixed clock, and the answers every implementation must give. Paths are relative to the routes' base (/runlight). Before each step the clock moves by advance milliseconds. capture keeps a value from an answer for later {{name}} in paths and headers. Ids, tokens, secrets, and hints in answers are written as <key>. An answer's headers are the ones it must carry: its media type, and CORS headers where it sends them. A scenario with sites runs with those sites, each with its id, in place of site. A step's look lists text to find in an answer that is not JSON, such as a script, and its answer's found says which of them it holds.",
      scenarios,
    },
    null,
    2,
  )}\n`,
);
console.log(`conformance/http.json: ${scenarios.length} scenarios, ${scenarios.reduce((n, s) => n + s.steps.length, 0)} requests`);
