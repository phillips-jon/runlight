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

/** What went wrong with the assistant, as a code the dashboard says in its own words; a service's own text goes in `detail`. */
export class AssistantError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

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
/** However many rounds a question takes, the answer comes within this long or the assistant stops. */
const DEADLINE_MS = 120_000;
const MAX_TOKENS = 1500;

function system(context: ChatContext): string {
  return `${INSTRUCTIONS}

You are the assistant inside this Runlight dashboard. Today is ${context.today} in ${context.site.timezone}. The person is looking at the site "${context.site.name}" (id ${context.site.id}) for ${context.view}. Unless they ask about another site or range, use this site and these dates.

When a question needs numbers, read them with the tools first and never guess one. Answer in a few short sentences or a short list, in plain language, and name the dates you looked at.

Rule: answer only the newest message. If it asks nothing new (thanks, a greeting, "great", "that helps"), reply with one short friendly sentence, call no tools, and do not repeat, summarise, or re-check any earlier answer. Only go back to earlier numbers when the person asks about them again. Bounce rate is a fraction from 0 to 1 and durations are milliseconds in the tools; give them as a percent and in seconds or minutes. Write in the language whose code is "${context.language}".`;
}

const TOO_LONG = "That question took too long to answer. Try asking something narrower.";

/** Stops when the question's time is up or the person has left, before more work starts. */
function inTime(deadline: number, signal?: AbortSignal): void {
  if (signal?.aborted) throw new AssistantError("The question was cancelled.", "assistant_cancelled");
  if (Date.now() >= deadline) throw new AssistantError(TOO_LONG, "assistant_slow");
}

async function post(url: string, headers: Record<string, string>, body: unknown, deadline: number, signal?: AbortSignal): Promise<Record<string, unknown>> {
  inTime(deadline, signal);
  const left = deadline - Date.now();
  let answer: Response;
  try {
    answer = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.any([AbortSignal.timeout(Math.min(90_000, left)), ...(signal ? [signal] : [])]),
    });
  } catch (error) {
    const host = new URL(url).host;
    throw (error as Error).name === "TimeoutError"
      ? new AssistantError(`Could not reach ${host}: it took too long to answer`, "assistant_timeout", { host })
      : new AssistantError(`Could not reach ${host}: the connection failed`, "unreachable", { host });
  }
  const data = (await answer.json().catch(() => null)) as Record<string, unknown> | null;
  if (!answer.ok) {
    // The service's own message, never the request (it carries the key).
    const error = data?.error as { message?: unknown } | string | undefined;
    const message = typeof error === "string" ? error : typeof error?.message === "string" ? error.message : "";
    const host = new URL(url).host;
    if (!message) throw new AssistantError(`${host}: it answered ${answer.status}`, "assistant_status", { host, status: String(answer.status) });
    throw new AssistantError(`${host}: ${message.slice(0, 300)}`, "assistant_refused", { host, detail: message.slice(0, 300) });
  }
  return data ?? {};
}

/** A service that answered, but not in its protocol's shape. */
function unreadable(url: string): AssistantError {
  const host = new URL(url).host;
  const message = `${host} sent an answer Runlight could not read`;
  return new AssistantError(message, "assistant_failed", { host, detail: message });
}

const isObject = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);

const toolText = async (name: string, args: unknown, readApi: ApiRead): Promise<{ text: string; error: boolean }> => {
  try {
    const result = await callTool({ name, arguments: args && typeof args === "object" ? args : {} }, readApi);
    const content = result.content as Array<{ text: string }>;
    return { text: content[0]?.text ?? "", error: result.isError === true };
  } catch (error) {
    return { text: (error as Error).message, error: true };
  }
};

/** Words that only acknowledge an answer, in the dashboard's languages; a message of nothing else gets a reply without the model. */
const THANKS = /^(?:(?:thanks|thank you|thank you so much|thanks a lot|thx|ty|cheers|ok|okay|great|cool|nice|perfect|awesome|got it|good|merci|merci beaucoup|super|parfait|d'accord|gracias|muchas gracias|vale|genial|perfecto|danke|danke schön|vielen dank|prima|alles klar|obrigado|obrigada|valeu|ótimo|beleza)[\s!.,]*)+$/iu;

const WELCOME: Record<string, string> = {
  en: "You're welcome. Ask me anything else about your stats.",
  fr: "Avec plaisir. Demandez-moi autre chose sur vos statistiques.",
  es: "De nada. Pregúntame lo que quieras sobre tus estadísticas.",
  de: "Gern geschehen. Frag mich gern noch etwas zu deinen Statistiken.",
  pt: "De nada. Pergunte o que quiser sobre suas estatísticas.",
};

/** A short reply to a message that only says thanks or OK, or null when the message asks something. */
export function acknowledgement(text: string, language: string): string | null {
  const plain = text.replace(/\p{Extended_Pictographic}|\uFE0F/gu, " ").trim();
  const welcome = Object.hasOwn(WELCOME, language) ? WELCOME[language]! : WELCOME.en!;
  if (!plain && text.trim()) return welcome;
  return THANKS.test(plain) ? welcome : null;
}

/** Answers the last question in `messages`, calling tools as the model asks. Returns the reply and the tools it used. */
export async function chat(
  settings: AssistantSettings,
  messages: ChatMessage[],
  context: ChatContext,
  readApi: ApiRead,
  signal?: AbortSignal,
): Promise<{ reply: string; tools: string[] }> {
  const provider = PROVIDERS.find((p) => p.id === settings.provider);
  if (!provider) throw new AssistantError("Choose a provider in Settings, AI Assistant", "assistant_provider");
  const base = (settings.baseUrl || provider.baseUrl).replace(/\/+$/, "");
  if (!base) throw new AssistantError("Enter the service's address in Settings, AI Assistant", "assistant_address");
  const model = settings.model || provider.model;
  if (!model) throw new AssistantError("Enter a model in Settings, AI Assistant", "assistant_model");
  const used: string[] = [];
  // "Thanks!" needs no model, no tools, and certainly not the last answer again.
  const thanks = acknowledgement(messages[messages.length - 1]?.content ?? "", context.language);
  if (thanks) return { reply: thanks, tools: [] };
  const deadline = Date.now() + DEADLINE_MS;
  // The last twenty turns, starting with a question (Anthropic refuses a history that opens with an answer),
  // and with unanswered questions in a row (a reply that never came) joined into one.
  const recent = messages.slice(-20);
  while (recent.length && recent[0]!.role !== "user") recent.shift();
  const history: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (const m of recent) {
    const content = String(m.content).slice(0, 8000);
    const last = history[history.length - 1];
    if (last && last.role === m.role) last.content += `\n\n${content}`;
    else history.push({ role: m.role, content });
  }

  if (provider.protocol === "anthropic") {
    const tools = TOOLS.map((t) => ({ name: t.name, description: t.description, input_schema: t.inputSchema }));
    const convo: Array<Record<string, unknown>> = history;
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const data = await post(`${base}/messages`, { "x-api-key": settings.key, "anthropic-version": "2023-06-01" }, { model, max_tokens: MAX_TOKENS, system: system(context), tools, messages: convo }, deadline, signal);
      const blocks = (data.content ?? []) as Array<{ type: string; text?: string; id?: string; name?: string; input?: unknown }>;
      if (!Array.isArray(blocks) || !blocks.every(isObject)) throw unreadable(base);
      const calls = blocks.filter((b) => b.type === "tool_use");
      if (data.stop_reason !== "tool_use" || !calls.length) {
        return { reply: blocks.filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n").trim(), tools: used };
      }
      convo.push({ role: "assistant", content: blocks });
      const results = [];
      for (const call of calls) {
        // The deadline covers the reading too, however many tools one answer asks for.
        inTime(deadline, signal);
        used.push(call.name ?? "");
        const out = await toolText(call.name ?? "", call.input, readApi);
        results.push({ type: "tool_result", tool_use_id: call.id, content: out.text, ...(out.error ? { is_error: true } : {}) });
      }
      convo.push({ role: "user", content: results });
    }
    throw new AssistantError("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps");
  }

  const tools = TOOLS.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.inputSchema } }));
  const convo: Array<Record<string, unknown>> = [{ role: "system", content: system(context) }, ...history];
  const headers: Record<string, string> = settings.key ? { authorization: `Bearer ${settings.key}` } : {};
  for (let round = 0; round < MAX_ROUNDS; round++) {
    // OpenAI's newer models take max_completion_tokens and refuse max_tokens; the other services still take max_tokens.
    const limit = provider.id === "openai" ? { max_completion_tokens: MAX_TOKENS } : { max_tokens: MAX_TOKENS };
    const data = await post(`${base}/chat/completions`, headers, { model, ...limit, messages: convo, tools }, deadline, signal);
    const message = ((data.choices as Array<{ message?: Record<string, unknown> }> | undefined)?.[0]?.message ?? {}) as {
      content?: string | null;
      tool_calls?: Array<{ id: string; function: { name: string; arguments: string } }>;
    };
    if (!message.tool_calls?.length) return { reply: String(message.content ?? "").trim(), tools: used };
    if (!Array.isArray(message.tool_calls) || !message.tool_calls.every((call) => isObject(call) && isObject(call.function))) throw unreadable(base);
    convo.push({ role: "assistant", content: message.content ?? null, tool_calls: message.tool_calls });
    for (const call of message.tool_calls) {
      inTime(deadline, signal);
      used.push(call.function.name);
      let args: unknown = {};
      try {
        args = JSON.parse(call.function.arguments || "{}");
      } catch {}
      const out = await toolText(call.function.name, args, readApi);
      convo.push({ role: "tool", tool_call_id: call.id, content: out.text });
    }
  }
  throw new AssistantError("The assistant needed too many steps for that question. Try asking something narrower.", "assistant_steps");
}

/**
 * The models a service offers with a key, from its own list: Anthropic's
 * /models, or the /models of an OpenAI-compatible API. Newest or most
 * relevant first where the service orders them; otherwise by name.
 */
export async function listModels(settings: Omit<AssistantSettings, "model">): Promise<Array<{ id: string; name: string }>> {
  const provider = PROVIDERS.find((p) => p.id === settings.provider);
  if (!provider) throw new AssistantError("Choose a provider", "assistant_provider");
  const base = (settings.baseUrl || provider.baseUrl).replace(/\/+$/, "");
  if (!base) throw new AssistantError("Enter the service's address first", "assistant_address");
  if (provider.key === "yes" && !settings.key) throw new AssistantError(`Enter your ${provider.name} key first`, "assistant_key", { provider: provider.name });
  const headers: Record<string, string> =
    provider.protocol === "anthropic" ? { "x-api-key": settings.key, "anthropic-version": "2023-06-01" } : settings.key ? { authorization: `Bearer ${settings.key}` } : {};
  let answer: Response;
  try {
    answer = await fetch(`${base}/models${provider.protocol === "anthropic" ? "?limit=100" : ""}`, { headers, signal: AbortSignal.timeout(20_000) });
  } catch {
    throw new AssistantError(`Could not reach ${new URL(base).host}`, "unreachable", { host: new URL(base).host });
  }
  const data = (await answer.json().catch(() => null)) as { data?: Array<{ id?: unknown; display_name?: unknown; name?: unknown }>; error?: { message?: unknown } | string } | null;
  if (!answer.ok) {
    const message = typeof data?.error === "string" ? data.error : typeof data?.error?.message === "string" ? data.error.message : "";
    const host = new URL(base).host;
    if (!message) throw new AssistantError(`${host}: it answered ${answer.status}`, "assistant_status", { host, status: String(answer.status) });
    throw new AssistantError(`${host}: ${String(message).slice(0, 300)}`, "assistant_refused", { host, detail: String(message).slice(0, 300) });
  }
  const listed = data?.data ?? [];
  if (!Array.isArray(listed)) throw unreadable(base);
  const models = listed
    .filter((m) => isObject(m) && typeof m.id === "string" && m.id)
    // Gemini lists ids as "models/gemini-...", which its OpenAI-compatible API takes without the prefix.
    .map((m) => {
      const id = String(m.id).replace(/^models\//, "");
      return { id, name: typeof m.display_name === "string" ? m.display_name : id };
    });
  if (!models.length) throw new AssistantError(`${new URL(base).host} listed no models. Type the model's name instead.`, "assistant_no_models", { host: new URL(base).host });
  // Anthropic lists newest first already; others come in no useful order.
  return provider.protocol === "anthropic" ? models : models.sort((a, b) => a.id.localeCompare(b.id));
}
