import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { aiAgent, isBot, parseClient } from "../src/ua.js";

interface Case {
  ua: string;
  screenWidth?: number;
  hints?: { brands?: string; mobile?: string; platform?: string };
  client?: ReturnType<typeof parseClient>;
  bot?: boolean;
  agent?: { name: string; kind: string };
}

const { cases } = JSON.parse(readFileSync(new URL("../../../conformance/ua.json", import.meta.url), "utf8")) as { cases: Case[] };

for (const c of cases) {
  test(c.ua.slice(0, 90), () => {
    const agent = aiAgent(c.ua);
    if (c.agent) {
      assert.equal(agent?.name, c.agent.name);
      assert.equal(agent?.kind, c.agent.kind);
      return;
    }
    assert.equal(agent, null, "not an AI agent");
    assert.equal(isBot(c.ua), Boolean(c.bot), c.bot ? "is a bot" : "is a person");
    if (c.client) assert.deepEqual(parseClient(c.ua, c.hints, c.screenWidth), c.client);
  });
}

test("client hints mark a mobile Chromium as mobile", () => {
  const ua = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
  assert.equal(parseClient(ua).device, "tablet");
  assert.equal(parseClient(ua, { mobile: "?1" }).device, "tablet", "an Android UA without Mobile still reads as a tablet");
  const desktop = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
  assert.equal(parseClient(desktop, { mobile: "?1" }).device, "mobile");
});
