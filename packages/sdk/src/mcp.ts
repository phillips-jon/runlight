/**
 * The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
 * JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
 * the caller's own credentials, so the MCP server can see exactly what the
 * token can and nothing more.
 */
import { DIMENSIONS } from "./query.js";
import { VERSION } from "./version.js";

/** Newest first; a client asking for one we do not know is answered with the newest. */
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

export const INSTRUCTIONS = `Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.`;

type Json = Record<string, unknown>;

const RANGE = {
  site: { type: "string", description: "Site id from list_sites. Defaults to the first site." },
  period: {
    type: "string",
    enum: ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"],
    description: "The date range. Defaults to 30d. Ignored when from and to are given.",
  },
  from: { type: "string", description: "First day, YYYY-MM-DD, with to." },
  to: { type: "string", description: "Last day, YYYY-MM-DD, inclusive." },
  filters: {
    type: "array",
    items: { type: "string" },
    description: 'Narrow to matching visits, each "dimension:op:value" with op is, not, or contains.',
  },
} as const;

const COMPARE = {
  compare: { type: "string", enum: ["previous", "year", "custom", "off"], description: "What to compare with. Defaults to previous, the same length of time just before." },
  compare_from: { type: "string", description: "For compare custom: first day, YYYY-MM-DD." },
  compare_to: { type: "string", description: "For compare custom: last day, YYYY-MM-DD." },
} as const;

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Json;
  /** The API path and query to read, from the tool's arguments. */
  request: (args: Json) => { path: string; params: [string, string][] };
  /** Trims an answer before it goes back, when the API's carries more than an assistant needs. */
  shape?: (body: Json) => unknown;
}

function rangeParams(args: Json, keys: readonly string[]): [string, string][] {
  const params: [string, string][] = [];
  for (const key of keys) {
    const value = args[key];
    if (key === "filters") {
      if (Array.isArray(value)) for (const f of value) params.push(["filter", String(f)]);
    } else if (value !== undefined && value !== null && value !== "") params.push([key, String(value)]);
  }
  return params;
}

const read = (path: string, keys: readonly string[], extra: (args: Json) => [string, string][] = () => []) => (args: Json) => ({
  path,
  params: [...rangeParams(args, keys), ...extra(args)],
});

const RANGE_KEYS = ["site", "period", "from", "to", "filters"] as const;
const COMPARE_KEYS = [...RANGE_KEYS, "compare", "compare_from", "compare_to"] as const;

export const TOOLS: Tool[] = [
  {
    name: "list_sites",
    title: "List sites",
    description: "Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.",
    inputSchema: { type: "object", properties: {} },
    request: () => ({ path: "/api/sites", params: [] }),
  },
  {
    name: "get_stats",
    title: "Headline numbers",
    description: "Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range's numbers as previous.",
    inputSchema: { type: "object", properties: { ...RANGE, ...COMPARE } },
    request: read("/api/stats", COMPARE_KEYS),
  },
  {
    name: "get_timeseries",
    title: "Numbers over time",
    description: "The headline numbers for each hour, day, week, or month of a range, with the comparison range's points lined up by position.",
    inputSchema: {
      type: "object",
      properties: { ...RANGE, ...COMPARE, interval: { type: "string", enum: ["hour", "day", "week", "month"], description: "Chosen from the range when left out." } },
    },
    request: read("/api/series", [...COMPARE_KEYS, "interval"]),
  },
  {
    name: "get_breakdown",
    title: "Top values of a dimension",
    description:
      "Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).",
    inputSchema: {
      type: "object",
      properties: {
        ...RANGE,
        dimension: { type: "string", enum: [...DIMENSIONS] },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "Rows to return. Defaults to 10." },
        page: { type: "integer", minimum: 1, description: "For more rows: 2 is the next limit rows." },
      },
      required: ["dimension"],
    },
    request: read("/api/breakdown", [...RANGE_KEYS, "dimension", "page"], (args) => [["limit", String(Math.min(100, Math.max(1, Number(args.limit) || 10)))]]),
  },
  {
    name: "list_funnels",
    title: "Funnels",
    description: "Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step's conversion rate.",
    inputSchema: { type: "object", properties: { ...RANGE } },
    request: read("/api/funnels", RANGE_KEYS),
  },
  {
    name: "get_event_properties",
    title: "An event's properties",
    description:
      "The properties sent with one custom event and the values each took, most common first. Automatic events have their own: \"Outbound link\" and \"File download\" carry url, and \"404\" carries path. Leave key out to see every property name and the values of the most used one.",
    inputSchema: {
      type: "object",
      properties: {
        ...RANGE,
        event: { type: "string", description: "The event's name, as get_breakdown with dimension event lists it." },
        key: { type: "string", description: "Which property. Defaults to the most used one." },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "Values to return. Defaults to 25." },
      },
      required: ["event"],
    },
    request: read("/api/event-props", [...RANGE_KEYS, "event", "key"], (args) => [["limit", String(Math.min(100, Math.max(1, Number(args.limit) || 25)))]]),
  },
  {
    name: "get_visit_times",
    title: "When people visit",
    description: "Visits by weekday and hour in the site's timezone: grid[weekday][hour], Monday first, hours 0 to 23.",
    inputSchema: { type: "object", properties: { ...RANGE } },
    request: read("/api/rhythm", RANGE_KEYS),
    shape: (body) => ({ site: body.site, range: body.range, weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], grid: body.grid }),
  },
  {
    name: "get_realtime",
    title: "Right now",
    description: "People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.",
    inputSchema: { type: "object", properties: { site: RANGE.site } },
    request: read("/api/realtime", ["site"]),
  },
  {
    name: "list_goals",
    title: "Goals and conversions",
    description: "Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range's numbers as previous.",
    inputSchema: { type: "object", properties: { ...RANGE, ...COMPARE } },
    request: read("/api/goals", COMPARE_KEYS),
  },
  {
    name: "get_goal",
    title: "One goal in detail",
    description: "One goal's conversions over time and by channel, source, and page. Find the goal_id with list_goals.",
    inputSchema: { type: "object", properties: { ...RANGE, goal_id: { type: "string" } }, required: ["goal_id"] },
    request: (args) => ({ path: `/api/goals/${encodeURIComponent(String(args.goal_id ?? ""))}`, params: rangeParams(args, RANGE_KEYS) }),
  },
  {
    name: "get_journeys",
    title: "Paths through the site",
    description:
      "The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.",
    inputSchema: {
      type: "object",
      properties: {
        ...RANGE,
        steps: { type: "integer", minimum: 2, maximum: 8, description: "How many pages of each path. Defaults to 5." },
        start: { type: "string", description: "Only paths from this page, such as /pricing." },
        end: { type: "string", description: "Only paths that reach this page, cut there." },
      },
    },
    request: read("/api/journeys", [...RANGE_KEYS, "steps", "start", "end"]),
  },
  {
    name: "list_links",
    title: "Short links",
    description: "Every short link with its destination and its clicks in the range.",
    inputSchema: { type: "object", properties: { site: RANGE.site, period: RANGE.period, from: RANGE.from, to: RANGE.to } },
    request: read("/api/links", ["site", "period", "from", "to"]),
  },
];

/** Reads one API path with the caller's credentials. */
export type ApiRead = (path: string, params: [string, string][]) => Promise<Response>;

interface RpcRequest {
  jsonrpc?: unknown;
  id?: unknown;
  method?: unknown;
  params?: unknown;
}

const rpcError = (id: unknown, code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

/** Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too. */
export async function callTool(params: Json, readApi: ApiRead): Promise<Json> {
  const tool = TOOLS.find((t) => t.name === params.name);
  if (!tool) throw Object.assign(new Error(`Unknown tool "${String(params.name)}"`), { code: -32602 });
  const args = (params.arguments && typeof params.arguments === "object" ? params.arguments : {}) as Json;
  const { path, params: query } = tool.request(args);
  const answer = await readApi(path, query);
  const body = (await answer.json().catch(() => ({}))) as Json;
  if (!answer.ok) return { content: [{ type: "text", text: String(body.error ?? `Runlight answered ${answer.status}`) }], isError: true };
  return { content: [{ type: "text", text: JSON.stringify(tool.shape ? tool.shape(body) : body) }] };
}

async function answer(message: RpcRequest, readApi: ApiRead): Promise<Json | null> {
  const isNotification = message.id === undefined;
  if (message.jsonrpc !== "2.0" || typeof message.method !== "string") return isNotification ? null : rpcError(message.id, -32600, "Invalid request");
  const params = (message.params && typeof message.params === "object" ? message.params : {}) as Json;
  try {
    let result: Json;
    switch (message.method) {
      case "initialize": {
        const asked = String(params.protocolVersion ?? "");
        result = {
          protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "runlight", title: "Runlight", version: VERSION },
          instructions: INSTRUCTIONS,
        };
        break;
      }
      case "ping":
        result = {};
        break;
      case "tools/list":
        result = {
          tools: TOOLS.map((t) => ({ name: t.name, title: t.title, description: t.description, inputSchema: t.inputSchema, annotations: { readOnlyHint: true, openWorldHint: false } })),
        };
        break;
      case "tools/call":
        result = await callTool(params, readApi);
        break;
      default:
        if (isNotification) return null;
        return rpcError(message.id, -32601, `Unknown method "${message.method}"`);
    }
    return isNotification ? null : { jsonrpc: "2.0", id: message.id, result };
  } catch (error) {
    if (isNotification) return null;
    const code = (error as { code?: number }).code;
    return rpcError(message.id, code ?? -32603, error instanceof Error && code ? error.message : "Internal error");
  }
}

/** Answers one POST to the MCP endpoint, already authorised. */
export async function mcpResponse(request: Request, readApi: ApiRead): Promise<Response> {
  const headers = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
  const body = (await request.json().catch(() => undefined)) as unknown;
  if (body === undefined || body === null || typeof body !== "object") {
    return new Response(JSON.stringify(rpcError(null, -32700, "Send a JSON-RPC message")), { status: 400, headers });
  }
  // Batches were in the 2025-03-26 protocol; answering them costs nothing.
  if (Array.isArray(body)) {
    const answers = (await Promise.all(body.map((m) => answer(m as RpcRequest, readApi)))).filter((a) => a !== null);
    return answers.length ? new Response(JSON.stringify(answers), { headers }) : new Response(null, { status: 202 });
  }
  const one = await answer(body as RpcRequest, readApi);
  return one ? new Response(JSON.stringify(one), { headers }) : new Response(null, { status: 202 });
}
