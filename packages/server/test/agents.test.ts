import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, renameSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { runlight } from "@runlight/sdk";
import { toNodeHandler } from "@runlight/sdk/node";
import { sqlite } from "@runlight/sdk/sqlite";
import { agentFetch, parseLine, runAgents } from "../src/agents.js";

const GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
const CLAUDE = "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)";
const CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
const line = (path: string, ua: string, status = 200, method = "GET", time = "07/Oct/2026:13:55:36 -0400", vhost = "") =>
  `${vhost ? `${vhost} ` : ""}203.0.113.9 - - [${time}] "${method} ${path} HTTP/1.1" ${status} 5120 "-" "${ua}"`;

test("log lines: nginx and Apache combined, a vhost column, and Caddy's JSON", () => {
  assert.deepEqual(parseLine(line("/blog/post?x=1", GPTBOT), "https://example.com"), {
    method: "GET",
    url: "https://example.com/blog/post?x=1",
    status: 200,
    userAgent: GPTBOT,
    at: Date.UTC(2026, 9, 7, 17, 55, 36),
  });
  assert.equal(parseLine(line("/", GPTBOT), undefined), null, "with no host anywhere there is no page to name");
  assert.equal(parseLine(line("/", GPTBOT, 200, "GET", "07/Oct/2026:13:55:36 -0400", "blog.example.com:443"))?.url, "https://blog.example.com/");
  const caddy = JSON.stringify({ ts: 1791399336.5, status: 200, request: { method: "GET", host: "example.com", uri: "/docs/", tls: {}, headers: { "User-Agent": [CLAUDE] } } });
  assert.deepEqual(parseLine(caddy), { method: "GET", url: "https://example.com/docs/", status: 200, userAgent: CLAUDE, at: 1791399336500 });
  assert.equal(parseLine("not a log line"), null);

  // Only successful GETs from AI agents are worth sending.
  assert.ok(agentFetch(line("/", GPTBOT), "https://example.com"));
  assert.equal(agentFetch(line("/", CHROME), "https://example.com"), null, "people are the tracker's job");
  assert.equal(agentFetch(line("/", GPTBOT, 404), "https://example.com"), null);
  assert.equal(agentFetch(line("/", GPTBOT, 200, "POST"), "https://example.com"), null);
});

test("a log is read once, carries on where it stopped, and starts over after rotation", async () => {
  const now = Date.UTC(2026, 9, 7, 18, 0, 0);
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["example.com"] }, now: () => now });
  await rl.init();
  await rl.store.setSetting("observe-key:default", "rlo_site");
  const server = createServer(toNodeHandler(rl.routes({ token: "owner" }).handler));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const to = `http://127.0.0.1:${(server.address() as AddressInfo).port}/runlight`;
  const dir = mkdtempSync(path.join(tmpdir(), "runlight-agents-"));
  const log = path.join(dir, "access.log");
  const state = path.join(dir, "state.json");
  const fetches = async () => rl.store.db.all<{ path: string; name: string; ts: number }>(`SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path`);
  const run = () => runAgents({ log, to, key: "rlo_site", site: "https://example.com", state, out: () => {} });
  try {
    writeFileSync(log, [line("/a", GPTBOT), line("/b", CHROME), line("/c", CLAUDE, 200, "GET", "07/Oct/2026:13:56:00 -0400"), line("/style.css", GPTBOT), ""].join("\n"));
    assert.equal(await run(), 2, "two pages count; the stylesheet and the person do not");
    const first = await fetches();
    assert.deepEqual(first.map((f) => [f.path, f.name]), [["/a", "GPTBot"], ["/c", "ClaudeBot"]], "Runlight keeps pages, not their assets");
    assert.equal(Number(first[0]!.ts), Date.UTC(2026, 9, 7, 17, 55, 36), "counted when the page was served");

    assert.equal(await run(), 0, "nothing new, nothing sent");
    appendFileSync(log, `${line("/d", GPTBOT)}\n`);
    assert.equal(await run(), 1);

    renameSync(log, `${log}.1`);
    writeFileSync(log, `${line("/e", CLAUDE)}\n`);
    assert.equal(await run(), 1, "a rotated log is read from the top");
    assert.deepEqual((await fetches()).map((f) => f.path).sort(), ["/a", "/c", "/d", "/e"]);

    await assert.rejects(runAgents({ log, to, key: "rlo_wrong", site: "https://example.com", out: () => {} }), /refused the key/);

    // Lines for another host, a // path, an absolute target, an old line, and a bad byte: none stops the rest.
    const before = (await fetches()).length;
    writeFileSync(
      log,
      Buffer.concat([
        Buffer.from(`${line("/f", GPTBOT, 200, "GET", "07/Oct/2026:13:57:00 -0400", "other.example:443")}\n`),
        Buffer.from(`${line("//g", GPTBOT)}\n`),
        Buffer.from(`${line("http://evil.example/h", GPTBOT)}\n`),
        Buffer.from(`${line("/old", GPTBOT, 200, "GET", "01/Sep/2026:10:00:00 -0400")}\n`),
        Buffer.from([0xff, 0xfe, 0x0a]),
        Buffer.from(`${line("/i", CLAUDE)}\n`),
      ]),
    );
    assert.equal(await run(), 2, "/g and /i count; the other host, the absolute target, and the old line do not");
    const paths = (await fetches()).map((f) => f.path);
    assert.equal(paths.length, before + 2);
    assert.ok(paths.includes("/g") && paths.includes("/i"));
    assert.ok(!paths.includes("/f") && !paths.includes("/h") && !paths.includes("/old"));
    assert.equal(await run(), 0, "the offset after a bad byte lands on the next line, so nothing is sent twice");

    // Rotated by copying and truncating: the same file, a new start, already longer than the old place.
    writeFileSync(log, `${line("/one", GPTBOT)}\n`);
    assert.equal(await run(), 1);
    writeFileSync(log, `${line("/two", CLAUDE)}\n${line("/three", GPTBOT)}\n`);
    assert.equal(await run(), 2, "both lines of the new log, none skipped");
  } finally {
    server.close();
  }
});
