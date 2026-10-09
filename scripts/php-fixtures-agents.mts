// Runs the Node server's access log parser over many lines and writes what parseLine and agentFetch
// return to packages/php/tests/fixtures/agents.json, so the PHP port's tests can require the same reading.
// Run with: TZ=UTC node --import tsx scripts/php-fixtures-agents.mts
import { writeFileSync } from "node:fs";
import { mock } from "node:test";
import { agentFetch, parseLine } from "../packages/server/src/agents.ts";

if (process.env.TZ !== "UTC") throw new Error("Run with TZ=UTC, as the PHP tests run");

const NOW = Date.UTC(2026, 9, 8, 15, 4, 5, 678);
mock.timers.enable({ apis: ["Date"], now: NOW });

const GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
const CLAUDE = "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)";
const CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
const line = (path: string, ua = GPTBOT, status = "200", method = "GET", time = "07/Oct/2026:13:55:36 -0400", vhost = "") =>
  `${vhost ? `${vhost} ` : ""}203.0.113.9 - - [${time}] "${method} ${path} HTTP/1.1" ${status} 5120 "-" "${ua}"`;
const caddy = (fields: Record<string, unknown>) => JSON.stringify(fields);

const lines: string[] = [
  line("/"),
  line("/blog/post?x=1"),
  line("/a b/x/../c#d?q=\"x\"&'y'"),
  line("/a?"),
  line("/a?b?c"),
  line("/%2e%2e/secret"),
  line("/./a/./b/."),
  line("/café/\u{1F600}?q=é"),
  line("/\\evil.example/x?y=1"),
  line("//evil.example/x"),
  line("///x"),
  line("/x\ty"),
  line("http://evil.example/h"),
  line("*"),
  line("/", CHROME),
  line("/", CLAUDE),
  line("/", GPTBOT, "404"),
  line("/", GPTBOT, "301"),
  line("/", GPTBOT, "199"),
  line("/", GPTBOT, "400"),
  line("/", GPTBOT, "200", "POST"),
  line("/", GPTBOT, "200", "get"),
  line("/", GPTBOT, "200", "HEAD"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 +0530"),
  line("/", GPTBOT, "200", "GET", "32/Oct/2026:00:00:00 -0100"),
  line("/", GPTBOT, "200", "GET", "07/Okt/2026:13:55:36 -0400"),
  line("/", GPTBOT, "200", "GET", "07/Oct/0099:13:55:36 +0000"),
  line("/", GPTBOT, "200", "GET", "29/Feb/2027:99:99:99 +0000"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 -0400", "blog.example.com:443"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 -0400", "Blog.Example.com"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 -0400", "10.0.0.1:443"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 -0400", "::1"),
  line("/", GPTBOT, "200", "GET", "07/Oct/2026:13:55:36 -0400", "bad host"),
  line("/", 'GPTBot \\"x\\"'),
  `1.2.3.4 - - [07/Oct/2026:13:55:36 -0400] "GET / HTTP/1.1" 200 1 "-" "GPTBot \\"x\\""`,
  `1.2.3.4 - - [07/Oct/2026:13:55:36 -0400] "GET /" 200 - "https://ref.example/\\"q" "${GPTBOT}"`,
  `   ${line("/padded")}   `,
  ` ${line("/nbsp")}　`,
  `1.2.3.4 - - [07/Oct/2026:13:55:36 -0400] "GET / HTTP/1.1" 200 1 "-" "${GPTBOT}"`,
  `1.2.3.4 - - [07/Oct/2026:13:55:36 -0400] "GET / HTTP/1.1" ٢٠٠ 1 "-" "${GPTBOT}"`,
  "not a log line",
  "",
  "   ",
  caddy({ ts: 1791399336.5, status: 200, request: { method: "GET", host: "example.com", uri: "/docs/", tls: {}, headers: { "User-Agent": [CLAUDE] } } }),
  caddy({ ts: 1791399336, status: 200, request: { method: "GET", host: "example.com", uri: "/docs/?a=1#frag", headers: { "user-agent": [GPTBOT] } } }),
  caddy({ ts: "2026-10-07T12:00:00Z", status: "200", request: { method: "GET", host: "example.com", uri: "/", headers: { "user-agent": ["x"] } } }),
  caddy({ ts: "yesterday", status: 200, request: { method: "GET", host: "example.com", uri: "/", headers: { "User-Agent": [GPTBOT] } } }),
  caddy({ status: 200, request: { method: "GET", host: "example.com", uri: "/", headers: { "User-Agent": [GPTBOT] } } }),
  caddy({ ts: 1, status: 503, request: { method: "GET", host: "example.com", uri: "/", headers: { "User-Agent": [GPTBOT] } } }),
  caddy({ ts: 1, request: { method: "GET", host: "example.com", uri: "/", headers: { "User-Agent": [GPTBOT] } } }),
  caddy({ ts: 1, status: 200, request: { method: "GET", host: "example.com:8443", uri: "/x", tls: [], headers: {} } }),
  caddy({ ts: 1, status: 200, request: { method: "GET", uri: "/no-host", headers: { "User-Agent": [GPTBOT] } } }),
  caddy({ ts: 1, status: 200, request: { method: "GET", host: "", uri: "/empty-host" } }),
  caddy({ ts: 1, status: 200, request: { method: "GET", host: "example.com", uri: "http://other/x" } }),
  caddy({ ts: 1, status: 200, request: { method: "GET", host: "example.com", uri: 5 } }),
  caddy({ ts: 1, status: 200, request: { method: "", host: "example.com", uri: "/" } }),
  caddy({ ts: 1, status: 200, request: null }),
  caddy({ ts: 1, status: 200 }),
  "{not json",
  "{}",
];
const sites: Array<string | undefined> = [undefined, "https://example.com", "http://example.com", "https://example.com/base/?q#h", "not a url"];

const number = (n: number) => (Number.isNaN(n) ? "NaN" : n);
const cases = lines.flatMap((text) =>
  sites.map((site) => {
    const parsed = parseLine(text, site);
    const fetched = agentFetch(text, site);
    return { line: text, ...(site === undefined ? {} : { site }), parsed: parsed && { ...parsed, at: number(parsed.at) }, fetched };
  }),
);

writeFileSync(new URL("../packages/php/tests/fixtures/agents.json", import.meta.url), `${JSON.stringify({ now: NOW, cases }, null, 2)}\n`);
console.log(`Wrote ${cases.length} cases.`);
