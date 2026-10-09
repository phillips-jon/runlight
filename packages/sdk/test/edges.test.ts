import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { AssistantError, acknowledgement, chat, listModels } from "../src/assistant.js";
import { ConnectError, finishConnect, installUrl } from "../src/connect.js";
import { iconLinks } from "../src/icon.js";
import { importStep } from "../src/importers/index.js";
import { runlight } from "../src/index.js";
import { MailError, checkConfig, send } from "../src/mail/transports.js";
import { callTool, mcpResponse } from "../src/mcp.js";
import { sqlite } from "../src/stores/sqlite.js";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const message = { to: "jon@example.com", from: "reports@example.com", subject: "Hello", html: "<p>Hi</p>", text: "Hi" };
const code = (fn: () => unknown) => {
  try {
    fn();
  } catch (error) {
    return (error as { code?: unknown }).code;
  }
  return null;
};

test("mail: Basic auth carries a key as UTF-8, whatever its characters", async () => {
  const seen: string[] = [];
  globalThis.fetch = (async (_input: unknown, init: RequestInit = {}) => {
    seen.push((init.headers as Record<string, string>).authorization!);
    return new Response("{}");
  }) as typeof fetch;
  await send({ service: "mailgun", apiKey: "ключ", domain: "mg.example.com", region: "us" }, message);
  await send({ service: "mailjet", apiKey: "mj", secretKey: "kéy 😀" }, message);
  assert.deepEqual(seen, [`Basic ${Buffer.from("api:ключ").toString("base64")}`, `Basic ${Buffer.from("mj:kéy 😀").toString("base64")}`]);
});

test("mail: an SMTP port out of range is refused before anything is saved or sent", () => {
  const smtp = (port: string) => ({ service: "smtp", host: "smtp.example.com", port, security: "starttls" });
  for (const port of ["70000", "65536", "0", "-1", "1.5", "abc"]) assert.equal(code(() => checkConfig(smtp(port))), "mail_port", port);
  for (const port of ["587", " 465 ", "65535", "1"]) assert.equal(code(() => checkConfig(smtp(port))), null, port);
});

test("mail: a webhook address that is not a URL is refused before anything is saved or sent", () => {
  for (const url of ["https://", "https://[", "https:// /x"]) {
    assert.equal(code(() => checkConfig({ service: "webhook", url })), "mail_url", url);
    assert.ok((() => { try { checkConfig({ service: "webhook", url }); } catch (e) { return e instanceof MailError; } })(), url);
  }
  assert.equal(code(() => checkConfig({ service: "webhook", url: "https://hooks.example.com/mail" })), null);
  assert.equal(code(() => checkConfig({ service: "webhook", url: "http://example.com/x" })), "mail_https");
});

const mcp = async (body: unknown) => {
  const asked: string[] = [];
  const answer = await mcpResponse(new Request("https://x.com/mcp", { method: "POST", body: JSON.stringify(body) }), async (path) => {
    asked.push(path);
    return new Response('{"ok":true}');
  });
  return { status: answer.status, body: answer.status === 202 ? null : await answer.json(), asked };
};

test("MCP: a notification runs nothing and is answered with nothing", async () => {
  assert.deepEqual(await mcp({ jsonrpc: "2.0", method: "tools/call", params: { name: "get_stats" } }), { status: 202, body: null, asked: [] });
  assert.deepEqual(await mcp([{ jsonrpc: "2.0", method: "tools/call", params: { name: "list_sites" } }]), { status: 202, body: null, asked: [] });
});

test("MCP: a batch element that is not an object is an invalid request of its own", async () => {
  const answer = await mcp([null, { jsonrpc: "2.0", id: 1, method: "ping" }, 5, []]);
  assert.equal(answer.status, 200);
  assert.deepEqual(answer.body, [
    { jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid request" } },
    { jsonrpc: "2.0", id: 1, result: {} },
    { jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid request" } },
    { jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid request" } },
  ]);
});

test("MCP: a refusal whose body is null or not an object reads like any other refusal", async () => {
  for (const body of ["null", "5", '"text"', "[1]"]) {
    const result = await callTool({ name: "list_sites" }, async () => new Response(body, { status: 403 }));
    assert.deepEqual(result, { content: [{ type: "text", text: "Runlight answered 403" }], isError: true }, body);
  }
  // An answer that is fine but null is passed on as it is, even through a tool that reshapes its answers.
  const fine = await callTool({ name: "get_visit_times" }, async () => new Response("null"));
  assert.deepEqual(fine, { content: [{ type: "text", text: "null" }] });
});

const context = { site: { id: "default", name: "Site", timezone: "UTC" }, today: "2026-10-08", view: "today", language: "en" };
const question = [{ role: "user" as const, content: "How many visitors?" }];

test("assistant: an answer in a shape it cannot read is assistant_failed, for every protocol", async () => {
  const answers: Array<[string, unknown]> = [
    ["anthropic", { content: "text" }],
    ["anthropic", { content: [null] }],
    ["anthropic", { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t", name: "list_sites", input: {} }, 5] }],
    ["anthropic", { content: { type: "text" } }],
    ["openai", { choices: [{ message: { tool_calls: "abc" } }] }],
    ["openai", { choices: [{ message: { tool_calls: [null] } }] }],
    ["openai", { choices: [{ message: { tool_calls: [{}] } }] }],
    ["openai", { choices: [{ message: { tool_calls: [{ id: "c", function: null }] } }] }],
    ["openai", { choices: [{ message: { tool_calls: { length: 1 } } }] }],
  ];
  for (const [provider, body] of answers) {
    globalThis.fetch = (async () => new Response(JSON.stringify(body))) as typeof fetch;
    await assert.rejects(
      chat({ provider, model: "m", baseUrl: "", key: "k" }, question, context, async () => new Response("{}")),
      (error: unknown) => error instanceof AssistantError && error.code === "assistant_failed" && typeof error.params.detail === "string",
      `${provider} ${JSON.stringify(body)}`,
    );
  }
  for (const body of [{ data: "x" }, { data: {} }]) {
    globalThis.fetch = (async () => new Response(JSON.stringify(body))) as typeof fetch;
    await assert.rejects(listModels({ provider: "openai", baseUrl: "", key: "k" }), (error: unknown) => error instanceof AssistantError && error.code === "assistant_failed", JSON.stringify(body));
  }
  // A list with entries that are not models is read like one with entries that have no id.
  globalThis.fetch = (async () => new Response('{"data":[null,5,{"id":"m1"}]}')) as typeof fetch;
  assert.deepEqual(await listModels({ provider: "openai", baseUrl: "", key: "k" }), [{ id: "m1", name: "m1" }]);
});

test("assistant: the chat route answers a reply it cannot read with 502 assistant_failed", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), secret: "k".repeat(32) });
  const { POST, PUT } = rl.routes({ token: "owner" });
  const headers = { authorization: "Bearer owner", "content-type": "application/json" };
  const saved = await PUT(new Request("https://x.com/runlight/api/assistant", { method: "PUT", headers, body: JSON.stringify({ provider: "anthropic", model: "m", key: "k" }) }));
  assert.equal(saved.status, 200, await saved.clone().text());
  globalThis.fetch = (async () => new Response('{"content":"text"}')) as typeof fetch;
  const answer = await POST(new Request("https://x.com/runlight/api/assistant/chat", { method: "POST", headers, body: JSON.stringify({ messages: question }) }));
  assert.equal(answer.status, 502);
  assert.equal(((await answer.json()) as any).code, "assistant_failed");
});

test("icons: only the rel attribute itself says what a link is", () => {
  assert.deepEqual(iconLinks('<link data-rel="x" rel="icon" href="/a.png">', "https://example.com/"), ["https://example.com/a.png"]);
  assert.deepEqual(iconLinks('<link rel="icon" data-href="/wrong.png" href="/right.png">', "https://example.com/"), ["https://example.com/right.png"]);
  assert.deepEqual(iconLinks('<link title="rel=icon" rel="stylesheet" href="/s.css">', "https://example.com/"), []);
  assert.deepEqual(iconLinks('<link rel="icon" href="/first.png" href="/second.png">', "https://example.com/"), ["https://example.com/first.png"]);
});

test("importers: a source named like a property of every object is unknown", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }) });
  const { POST } = rl.routes({ token: null });
  const answer = await POST(new Request("https://x.com/runlight/api/links/import/constructor", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ credentials: {} }) }));
  assert.equal(answer.status, 400);
  assert.equal(((await answer.json()) as any).code, "import_source");
  for (const source of ["constructor", "toString", "__proto__", "hasOwnProperty"]) {
    await assert.rejects(importStep(rl, "default", source, {}, null, 0), (error: unknown) => (error as { code?: string }).code === "import_source", source);
  }
});

test("assistant: thanks in a language named like a property of every object is answered in English", () => {
  for (const language of ["constructor", "__proto__", "toString"]) assert.equal(acknowledgement("Thanks!", language), acknowledgement("Thanks!", "en"), language);
});

test("importers: a browser, system, or device named like a property of every object is just a name", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), site: { hostnames: ["blog.example.com"], timezone: "UTC" }, now: () => Date.parse("2026-03-04T00:00:00Z") });
  const { POST } = rl.routes({ token: null });
  const answer = await POST(new Request("https://x.com/runlight/api/import/csv/visits", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ rows: [{ time: "2026-03-01T10:00:00Z", path: "/", visitor: "a", browser: "constructor", os: "toString", device: "valueOf" }] }),
  }));
  assert.equal(answer.status, 200, await answer.clone().text());
  assert.equal(((await answer.json()) as any).visits, 1);
  const rows = await rl.store.db.all<{ browser: string; os: string; device: string }>("SELECT browser, os, device FROM rl_sessions");
  assert.deepEqual(rows, [{ browser: "Constructor", os: "toString", device: "" }]);

  // Clicks from a link service take the same path.
  globalThis.fetch = (async (input: string | URL | Request) => {
    const url = String(input);
    const body = /startingAfter/.test(url)
      ? []
      : /\/links\?/.test(url)
        ? [{ id: "l1", domain: "dub.sh", key: "x", url: "https://a.com/x", title: "X", createdAt: "2026-01-02T00:00:00Z" }]
        : [{ timestamp: "2026-03-01T10:00:00Z", click: { id: "c1", country: "CA", device: "constructor", browser: "__proto__", os: "constructor" } }];
    return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  const links = runlight({ store: sqlite({ path: ":memory:" }) });
  let cursor: string | null = null;
  let clicks = 0;
  do {
    const step = await importStep(links, "default", "dub", { apiKey: "k" }, cursor, 0);
    assert.deepEqual(step.failed, []);
    clicks += step.clicks;
    cursor = step.cursor;
  } while (cursor);
  assert.equal(clicks, 1);
  const clicked = await links.store.db.all<{ browser: string; os: string; device: string }>("SELECT browser, os, device FROM rl_sessions");
  assert.deepEqual(clicked, [{ browser: "__proto__", os: "constructor", device: "" }]);
});

test("connect: an attempt saved without an expiry has expired", async () => {
  const rl = runlight({ store: sqlite({ path: ":memory:" }), managedSites: true, secret: "k".repeat(32) });
  await rl.init();
  const state = "a".repeat(32);
  for (const stored of [{ url: "https://example.com", client: "c", verifier: "v", redirect: "https://x.com/back", token: "https://example.com/token" }, null, 5, { expires: "9999999999999" }]) {
    await rl.store.setSetting(`connect:${state}`, JSON.stringify(stored));
    globalThis.fetch = (async () => {
      throw new Error("nothing should be fetched");
    }) as typeof fetch;
    await assert.rejects(finishConnect(rl, new URLSearchParams({ state, code: "c" })), (error: unknown) => error instanceof ConnectError && error.code === "expired", JSON.stringify(stored));
  }
});

test("connect: an address the URL parser refuses is the address error", () => {
  for (const url of ["https://[", "https://[::1", "https://a b"]) assert.equal(code(() => installUrl(url)), "url", url);
  assert.equal(installUrl("https://example.com/runlight/"), "https://example.com/runlight");
  assert.ok((() => { try { installUrl("https://["); } catch (e) { return e instanceof ConnectError; } })());
});
