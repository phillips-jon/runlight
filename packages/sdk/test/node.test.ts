import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { toNodeHandler } from "../src/node.js";

test("the Node adapter passes large bodies through, and answers 413 past its limits", async () => {
  const seen: number[] = [];
  const handler = toNodeHandler(async (request) => {
    seen.push((await request.text()).length);
    return new Response("{}", { headers: { "content-type": "application/json" } });
  });
  const server = createServer((req, res) => void handler(req, res));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  try {
    const rows = "x".repeat(300 * 1024);
    const big = await fetch(`${base}/runlight/api/links/import`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ rows }) });
    assert.equal(big.status, 200);
    assert.equal(seen.at(-1), rows.length + 11, "a 300 KB import arrives whole");
    const collect = await fetch(`${base}/runlight/e`, { method: "POST", body: "x".repeat(20 * 1024) });
    assert.equal(collect.status, 413, "the collect endpoint keeps its small limit");
  } finally {
    server.close();
  }
});
