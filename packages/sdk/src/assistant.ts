/**
 * The dashboard's assistant: questions about the stats, answered by a model
 * the owner chooses, through the same read-only tools as the MCP server. The
 * model runs on the server, so the key never reaches a browser, and each tool
 * reads the API with the asking person's own access.
 *
 * Two protocols cover the providers: Anthropic's Messages API, and OpenAI's
 * Chat Completions, which OpenAI, Gemini (through its compatible endpoint),
 * OpenRouter, Ollama, LM Studio, and most others speak. Plain fetch, no SDKs.
 */
import { INSTRUCTIONS, TOOLS, callTool, type ApiRead } from "./mcp.js";

export interface Provider {
  id: string;
  name: string;
  protocol: "anthropic" | "openai";
  /** The API's address, filled in for known services and asked for otherwise. */
  baseUrl: string;
  /** A model to start with, or "" when the person picks one. */
  model: string;
  /** Whether it needs a key: "yes", "no" (a model on your own machine), or "optional". */
  key: "yes" | "no" | "optional";
}

export const PROVIDERS: Provider[] = [
  { id: "anthropic", name: "Anthropic (Claude)", protocol: "anthropic", baseUrl: "https://api.anthropic.com/v1", model: "claude-sonnet-5-5", key: "yes" },
  { id: "openai", name: "OpenAI", protocol: "openai", baseUrl: "https://api.openai.com/v1", model: "", key: "yes" },
  { id: "gemini", name: "Google Gemini", protocol: "openai", baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai", model: "", key: "yes" },
  { id: "openrouter", name: "OpenRouter", protocol: "openai", baseUrl: "https://openrouter.ai/api/v1", model: "", key: "yes" },
  { id: "ollama", name: "Ollama", protocol: "openai", baseUrl: "http://localhost:11434/v1", model: "", key: "no" },
  { id: "lmstudio", name: "LM Studio", protocol: "openai", baseUrl: "http://localhost:1234/v1", model: "", key: "no" },
  { id: "custom", name: "Another OpenAI-compatible service", protocol: "openai", baseUrl: "", model: "", key: "optional" },
];

export interface AssistantSettings {
  provider: string;
  model: string;
  baseUrl: string;
  key: string;
}

export class AssistantError extends Error {}

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

/** What the person is looking at, so "this week" and "this page" mean what they see. */
export interface ChatContext {
  site: { id: string; name: string; timezone: string };
  today: string;
  view: string;
  language: string;
}

const MAX_ROUNDS = 8;
const MAX_TOKENS = 1500;

function system(context: ChatContext): string {
  return `${INSTRUCTIONS}

You are the assistant inside this Runlight dashboard. Today is ${context.today} in ${context.site.timezone}. The person is looking at the site "${context.site.name}" (id ${context.site.id}) for ${context.view}. Unless they ask about another site or range, use this site and these dates.

Use the tools to read the numbers before you answer, and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is "${context.language}".`;
}

async function post(url: string, headers: Record<string, string>, body: unknown): Promise<Record<string, unknown>> {
  let answer: Response;
  try {
    answer = await fetch(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body), signal: AbortSignal.timeout(90_000) });
  } catch (error) {
    throw new AssistantError(`Could not reach ${new URL(url).host}: ${(error as Error).name === "TimeoutError" ? "it took too long to answer" : "the connection failed"}`);
  }
  const data = (await answer.json().catch(() => null)) as Record<string, unknown> | null;
  if (!answer.ok) {
    // The service's own message, never the request (it carries the key).
    const error = data?.error as { message?: unknown } | string | undefined;
    const message = typeof error === "string" ? error : typeof error?.message === "string" ? error.message : `it answered ${answer.status}`;
    throw new AssistantError(`${new URL(url).host}: ${message.slice(0, 300)}`);
  }
  return data ?? {};
}

const toolText = async (name: string, args: unknown, readApi: ApiRead): Promise<{ text: string; error: boolean }> => {
  try {
    const result = await callTool({ name, arguments: args && typeof args === "object" ? args : {} }, readApi);
    const content = result.content as Array<{ text: string }>;
    return { text: content[0]?.text ?? "", error: result.isError === true };
  } catch (error) {
    return { text: (error as Error).message, error: true };
  }
};

/** Answers the last question in `messages`, calling tools as the model asks. Returns the reply and the tools it used. */
export async function chat(settings: AssistantSettings, messages: ChatMessage[], context: ChatContext, readApi: ApiRead): Promise<{ reply: string; tools: string[] }> {
  const provider = PROVIDERS.find((p) => p.id === settings.provider);
  if (!provider) throw new AssistantError("Choose a provider in Settings, Assistant");
  const base = (settings.baseUrl || provider.baseUrl).replace(/\/+$/, "");
  if (!base) throw new AssistantError("Enter the service's address in Settings, Assistant");
  const model = settings.model || provider.model;
  if (!model) throw new AssistantError("Enter a model in Settings, Assistant");
  const used: string[] = [];
  const history = messages.slice(-20).map((m) => ({ role: m.role, content: String(m.content).slice(0, 8000) }));

  if (provider.protocol === "anthropic") {
    const tools = TOOLS.map((t) => ({ name: t.name, description: t.description, input_schema: t.inputSchema }));
    const convo: Array<Record<string, unknown>> = history;
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const data = await post(`${base}/messages`, { "x-api-key": settings.key, "anthropic-version": "2023-06-01" }, { model, max_tokens: MAX_TOKENS, system: system(context), tools, messages: convo });
      const blocks = (data.content ?? []) as Array<{ type: string; text?: string; id?: string; name?: string; input?: unknown }>;
      const calls = blocks.filter((b) => b.type === "tool_use");
      if (data.stop_reason !== "tool_use" || !calls.length) {
        return { reply: blocks.filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n").trim(), tools: used };
      }
      convo.push({ role: "assistant", content: blocks });
      const results = [];
      for (const call of calls) {
        used.push(call.name ?? "");
        const out = await toolText(call.name ?? "", call.input, readApi);
        results.push({ type: "tool_result", tool_use_id: call.id, content: out.text, ...(out.error ? { is_error: true } : {}) });
      }
      convo.push({ role: "user", content: results });
    }
    throw new AssistantError("The assistant needed too many steps for that question. Try asking something narrower.");
  }

  const tools = TOOLS.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.inputSchema } }));
  const convo: Array<Record<string, unknown>> = [{ role: "system", content: system(context) }, ...history];
  const headers: Record<string, string> = settings.key ? { authorization: `Bearer ${settings.key}` } : {};
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const data = await post(`${base}/chat/completions`, headers, { model, max_tokens: MAX_TOKENS, messages: convo, tools });
    const message = ((data.choices as Array<{ message?: Record<string, unknown> }> | undefined)?.[0]?.message ?? {}) as {
      content?: string | null;
      tool_calls?: Array<{ id: string; function: { name: string; arguments: string } }>;
    };
    if (!message.tool_calls?.length) return { reply: String(message.content ?? "").trim(), tools: used };
    convo.push({ role: "assistant", content: message.content ?? null, tool_calls: message.tool_calls });
    for (const call of message.tool_calls) {
      used.push(call.function.name);
      let args: unknown = {};
      try {
        args = JSON.parse(call.function.arguments || "{}");
      } catch {}
      const out = await toolText(call.function.name, args, readApi);
      convo.push({ role: "tool", tool_call_id: call.id, content: out.text });
    }
  }
  throw new AssistantError("The assistant needed too many steps for that question. Try asking something narrower.");
}
