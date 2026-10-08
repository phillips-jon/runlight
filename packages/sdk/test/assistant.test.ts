import assert from "node:assert/strict";
import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

const body = (req: IncomingMessage) => new Promise<any>((resolve) => {
  let text = "";
  req.on("data", (c) => (text += c));
  req.on("end", () => resolve(JSON.parse(text || "{}")));
});

/** A model that asks for the stats once, then answers with the visitors it was told. */
async function fakeModel() {
  const seen: Array<{ path: string; headers: IncomingMessage["headers"]; body: any }> = [];
  const server = createServer(async (req, res) => {
    const json = await body(req);
    seen.push({ path: req.url ?? "", headers: req.headers, body: json });
    res.setHeader("content-type", "application/json");
    if (req.url === "/v1/messages") {
      const last = json.messages[json.messages.length - 1];
      const result = Array.isArray(last.content) ? last.content.find((b: any) => b.type === "tool_result") : null;
      if (!result) return res.end(JSON.stringify({ stop_reason: "tool_use", content: [{ type: "text", text: "Looking." }, { type: "tool_use", id: "t1", name: "get_stats", input: { period: "today" } }] }));
      const visitors = JSON.parse(result.content).stats.visitors;
      return res.end(JSON.stringify({ stop_reason: "end_turn", content: [{ type: "text", text: `You had ${visitors} visitors today.` }] }));
    }
    if (req.url === "/v1/chat/completions") {
      const last = json.messages[json.messages.length - 1];
      if (last.role !== "tool") return res.end(JSON.stringify({ choices: [{ message: { content: null, tool_calls: [{ id: "c1", type: "function", function: { name: "get_stats", arguments: '{"period":"today"}' } }] } }] }));
      return res.end(JSON.stringify({ choices: [{ message: { content: `Visitors: ${JSON.parse(last.content).stats.visitors}` } }] }));
    }
    if (req.url === "/v1/models?limit=100") {
      if (req.headers["x-api-key"] !== "sk-ant-secret") return res.writeHead(401).end(JSON.stringify({ error: { message: "invalid x-api-key" } }));
      return res.end(JSON.stringify({ data: [{ id: "claude-opus-5-5", display_name: "Claude Opus 5.5" }, { id: "claude-sonnet-5-5", display_name: "Claude Sonnet 5.5" }] }));
    }
    if (req.url === "/v1/models") return res.end(JSON.stringify({ data: [{ id: "models/zeta" }, { id: "alpha" }] }));
    res.statusCode = 404;
    res.end(JSON.stringify({ error: { message: "no such model" } }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`, seen, close: () => server.close() };
}

test("the assistant answers through the stats tools, with the key kept on the server", async () => {
  const model = await fakeModel();
  try {
    const rl = runlight({ store: sqlite({ path: ":memory:" }), sites: [{ id: "other", name: "Other", hostnames: ["other.example.com"] }, { id: "default", name: "Blog", hostnames: ["example.com"] }], secret: "s".repeat(32) });
    const { handler } = rl.routes({ token: "owner" });
    const call = async (method: string, path: string, data?: unknown, auth = "owner") => {
      const answer = await handler(new Request(`https://example.com/runlight${path}`, { method, headers: { authorization: `Bearer ${auth}`, "content-type": "application/json" }, ...(data === undefined ? {} : { body: JSON.stringify(data) }) }));
      return { status: answer.status, body: (await answer.json().catch(() => null)) as any };
    };
    for (const ip of ["203.0.113.1", "203.0.113.2"]) {
      await handler(new Request("https://example.com/runlight/e", { method: "POST", headers: { "user-agent": "Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36", "x-forwarded-for": ip }, body: JSON.stringify({ k: "pageview", u: "https://example.com/" }) }));
    }
    const ask = (question: string) => call("POST", "/api/assistant/chat", { site: "default", messages: [{ role: "user", content: question }], view: "today", language: "en" });

    assert.equal((await ask("How many?")).status, 400, "not set up yet");
    assert.equal((await call("PUT", "/api/assistant", { provider: "anthropic" })).status, 400, "Anthropic needs a key");
    assert.equal((await call("PUT", "/api/assistant", { provider: "anthropic", key: "sk-ant-secret", baseUrl: model.url })).status, 200);
    const shown = (await call("GET", "/api/assistant")).body;
    assert.equal(shown.keySaved, true);
    assert.equal(JSON.stringify(shown).includes("sk-ant-secret"), false, "the key never comes back");
    assert.notEqual(await rl.store.setting("assistant"), null);
    assert.equal((await rl.store.setting("assistant"))!.includes("sk-ant-secret"), false, "and it is kept sealed");

    // Loading models with the key saved for this provider, and with a wrong one.
    const models = await call("POST", "/api/assistant/models", { provider: "anthropic", baseUrl: model.url });
    assert.deepEqual(models.body.models, [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }, { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" }]);
    const refused = await call("POST", "/api/assistant/models", { provider: "anthropic", baseUrl: model.url, key: "wrong" });
    assert.equal(refused.status, 400);
    assert.match(refused.body.error, /invalid x-api-key/);
    assert.deepEqual((await call("POST", "/api/assistant/models", { provider: "ollama", baseUrl: model.url })).body.models.map((m: any) => m.id), ["alpha", "zeta"], "sorted, without Gemini's models/ prefix");

    const claude = await ask("How many visitors today?");
    assert.equal(claude.status, 200);
    assert.deepEqual(claude.body, { reply: "You had 2 visitors today.", tools: ["get_stats"] }, "a tool that names no site reads the one on screen, not the first");
    const sent = model.seen.find((r) => r.path === "/v1/messages")!;
    assert.equal(sent.headers["x-api-key"], "sk-ant-secret");
    assert.equal(sent.body.model, "claude-sonnet-5-5");
    assert.match(sent.body.system, /"Blog"/, "it knows which site is on screen");

    // An OpenAI-compatible service on your own machine needs no key; saving without one keeps none.
    assert.equal((await call("PUT", "/api/assistant", { provider: "ollama", model: "local-model", baseUrl: model.url })).status, 200);
    const local = await ask("And with the other one?");
    assert.deepEqual(local.body, { reply: "Visitors: 2", tools: ["get_stats"] });
    assert.equal(model.seen.at(-1)!.headers.authorization, undefined);

    // API tokens and shares cannot spend the owner's AI credit, and only owners change the settings.
    const token = (await call("POST", "/api/tokens", { name: "Script" })).body.secret;
    assert.equal((await call("POST", "/api/assistant/chat", { site: "default", messages: [{ role: "user", content: "hi" }] }, token)).status, 403);
    assert.equal((await call("PUT", "/api/assistant", { provider: "ollama", model: "x" }, token)).status, 401);
    assert.equal((await call("POST", "/api/assistant/models", { provider: "anthropic" }, token)).status, 401, "only owners list models with the saved key");

    // A service's own error comes back in plain words, never with the key in it.
    assert.equal((await call("PUT", "/api/assistant", { provider: "custom", model: "m", baseUrl: `${model.url}/missing`, key: "k-secret" })).status, 200);
    const failed = await ask("Hello?");
    assert.equal(failed.status, 502);
    assert.match(failed.body.error, /no such model/);
    assert.equal(failed.body.error.includes("k-secret"), false);
  } finally {
    model.close();
  }
});

test("thanks gets a short reply without the model or the tools", async () => {
  const { acknowledgement } = await import("../src/assistant.js");
  for (const text of ["Thanks!", "thank you", "Thanks!! 🙏", "ok", "Great, thanks.", "👍", "merci beaucoup", "Danke schön!", "valeu"]) {
    assert.ok(acknowledgement(text, "en"), text);
  }
  for (const text of ["Thanks, and what about last week?", "What was my bounce rate?", "ok so which pages?", "great results?"]) {
    assert.equal(acknowledgement(text, "en"), null, text);
  }
  assert.match(acknowledgement("merci", "fr")!, /plaisir/);
});
