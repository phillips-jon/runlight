/**
 * The HTTP conformance scenarios: requests to a fresh Runlight on a fixed
 * clock, and the answers it gives. `npm run conformance` (in the repo root)
 * runs them against this implementation and writes conformance/http.json;
 * the test replays that file, so the TypeScript answers and the file cannot
 * drift. Another implementation (a PHP port) replays the same file.
 *
 * Anything random in an answer (ids, tokens, secrets, share paths) is written
 * as "<name>", and a step can capture a value so later paths can use {{name}}.
 */
import { runlight } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";

export interface Step {
  /** Milliseconds to move the clock before this request. */
  advance?: number;
  method: string;
  path: string;
  headers?: Record<string, string>;
  body?: unknown;
  /** Values to keep from the answer, by dotted path, for later steps' {{name}}. */
  capture?: Record<string, string>;
  /** Text to look for in an answer that is not JSON, such as a script; the answer says which was found. */
  look?: string[];
  expect?: Answer;
}

/** What a step must answer: the status, the headers that matter to a client, and the JSON body. */
export interface Answer {
  status: number;
  headers?: Record<string, string>;
  body?: unknown;
  /** For each of the step's `look` strings, whether the answer's text holds it. */
  found?: boolean[];
}

/** Headers every implementation must send the same: the media type, and CORS for the tracker. */
const HEADERS = ["content-type", "access-control-allow-origin", "access-control-allow-methods"];

export interface Scenario {
  name: string;
  /** The runlight() site, in its options' shape. */
  site: { hostnames: string[]; timezone: string };
  /** Several sites instead, each with its id, when a scenario needs more than one. */
  sites?: Array<{ id: string; hostnames: string[]; timezone: string }>;
  /** Epoch milliseconds the clock starts at. */
  start: number;
  token: string;
  steps: Step[];
}

const CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const GPTBOT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
const auth = { authorization: "Bearer conformance" };
const json = { ...auth, "content-type": "application/json" };
const hit = (body: Record<string, unknown>, ip: string, ua = CHROME, extra: Record<string, string> = {}): Step => ({
  method: "POST",
  path: "/e",
  headers: { "user-agent": ua, "x-forwarded-for": ip, ...extra },
  body,
});
const get = (path: string): Step => ({ method: "GET", path, headers: auth });

/** The scenarios, without answers; the generator fills in `expect`. */
export const SCENARIOS: Scenario[] = [
  {
    name: "a day of visits and the reports they make",
    site: { hostnames: ["example.com"], timezone: "Europe/London" },
    start: Date.UTC(2026, 9, 6, 9, 0),
    token: "conformance",
    steps: [
      hit({ k: "pageview", u: "https://example.com/?utm_source=newsletter&utm_campaign=autumn", r: "https://mail.google.com/", i: "pv1", t: "Home", w: 1440, h: 900, l: "en-GB" }, "203.0.113.1", CHROME, { "x-vercel-ip-country": "GB", "x-vercel-ip-city": "London" }),
      { ...hit({ k: "engagement", u: "https://example.com/", i: "pv1", e: 18000, d: 70 }, "203.0.113.1"), advance: 20_000 },
      hit({ k: "pageview", u: "https://example.com/pricing", r: "https://example.com/", i: "pv2" }, "203.0.113.1"),
      { ...hit({ k: "event", u: "https://example.com/pricing", i: "pv2", n: "Signup", p: { plan: "pro" } }, "203.0.113.1"), advance: 5_000 },
      { ...hit({ k: "pageview", u: "https://example.com/blog/post", r: "https://chatgpt.com/", i: "pv3", w: 390, h: 844 }, "198.51.100.7", IPHONE, { "x-vercel-ip-country": "US" }), advance: 60_000 },
      { ...hit({ k: "pageview", u: "https://example.com/", r: "https://www.google.com/", i: "pv4" }, "192.0.2.4"), advance: 3_600_000 },
      // A bot and a page from another host are dropped.
      hit({ k: "pageview", u: "https://example.com/", i: "pv5" }, "192.0.2.9", "curl/8.4.0"),
      hit({ k: "pageview", u: "https://elsewhere.example/", i: "pv6" }, "192.0.2.10"),
      // Thirty minutes idle starts a second visit for the first visitor.
      { ...hit({ k: "pageview", u: "https://example.com/pricing", i: "pv7" }, "203.0.113.1"), advance: 31 * 60_000 },
      { method: "POST", path: "/api/observe", headers: json, body: { url: "https://example.com/blog/post", userAgent: GPTBOT } },
      get("/api/stats?period=today&compare=off"),
      get("/api/series?period=today&compare=off"),
      ...["page", "entry", "exit", "event", "source", "channel", "referrer", "utm_source", "utm_campaign", "country", "city", "browser", "os", "device", "screen", "language", "ai_agent", "ai_page"].map((d) => get(`/api/breakdown?period=today&dimension=${d}`)),
      get("/api/breakdown?period=today&dimension=page&filter=country:is:GB"),
      get("/api/stats?period=today&compare=off&filter=channel:is:AI"),
      // Page and event filters pick whole visits: "is not" means visits that never had one, a page
      // filter counts that page's views, and "contains" ignores case.
      get("/api/stats?period=today&compare=off&filter=event:is:Signup"),
      get("/api/stats?period=today&compare=off&filter=event:not:Signup"),
      get("/api/stats?period=today&compare=off&filter=page:is:/pricing"),
      get("/api/stats?period=today&compare=off&filter=page:is:/pricing&filter=page:is:/"),
      get("/api/stats?period=today&compare=off&filter=page:contains:PRICING"),
      get("/api/series?period=today&compare=off&filter=page:not:/pricing"),
      get("/api/breakdown?period=today&dimension=page&filter=event:is:Signup"),
      get("/api/breakdown?period=today&dimension=event&filter=page:is:/pricing"),
      get("/api/rhythm?period=today&filter=page:is:/pricing"),
      get("/api/rhythm?period=today"),
      get("/api/realtime"),
      get("/api/event-props?period=today&event=Signup"),
    ],
  },
  {
    name: "goals, funnels, and links",
    site: { hostnames: ["shop.example.com"], timezone: "America/New_York" },
    start: Date.UTC(2026, 9, 6, 15, 0),
    token: "conformance",
    steps: [
      hit({ k: "pageview", u: "https://shop.example.com/", i: "a1" }, "203.0.113.20"),
      { ...hit({ k: "pageview", u: "https://shop.example.com/cart", i: "a2" }, "203.0.113.20"), advance: 30_000 },
      { ...hit({ k: "pageview", u: "https://shop.example.com/thanks", i: "a3" }, "203.0.113.20"), advance: 30_000 },
      { ...hit({ k: "event", u: "https://shop.example.com/thanks", i: "a3", n: "Purchase", p: { amount: 49.5 } }, "203.0.113.20"), advance: 1_000 },
      hit({ k: "pageview", u: "https://shop.example.com/", i: "b1" }, "203.0.113.21"),
      { method: "POST", path: "/api/goals", headers: json, body: { name: "Purchase", kind: "event", match: "Purchase", valueMode: "prop", valueProp: "amount", currency: "USD" }, capture: { goal: "goal.id" } },
      { method: "POST", path: "/api/goals", headers: json, body: { name: "Thanks page", kind: "page", match: "/thanks*" } },
      { method: "POST", path: "/api/goals", headers: json, body: { name: "", kind: "event", match: "" } },
      get("/api/goals?period=today"),
      get("/api/goals/{{goal}}?period=today"),
      { method: "POST", path: "/api/funnels", headers: json, body: { name: "Checkout", steps: [{ kind: "page", match: "/" }, { kind: "page", match: "/cart" }, { kind: "event", match: "Purchase" }] } },
      get("/api/funnels?period=today"),
      { method: "POST", path: "/api/links", headers: json, body: { url: "https://example.org/sale", slug: "sale", name: "Sale" }, capture: { link: "link.id" } },
      { method: "POST", path: "/api/links", headers: json, body: { url: "https://example.org/other", slug: "sale" } },
      { method: "PATCH", path: "/api/links/{{link}}", headers: json, body: { name: "Autumn sale" } },
      get("/api/links?period=today"),
      { method: "DELETE", path: "/api/goals/{{goal}}", headers: auth },
      get("/api/goals?period=today"),
    ],
  },
  {
    name: "who may do what",
    site: { hostnames: ["example.com"], timezone: "UTC" },
    start: Date.UTC(2026, 9, 6, 12, 0),
    token: "conformance",
    steps: [
      { method: "GET", path: "/api/stats?period=today" },
      { method: "GET", path: "/api/stats?period=today", headers: { authorization: "Bearer wrong" } },
      { method: "POST", path: "/api/tokens", headers: json, body: { name: "Script" }, capture: { secret: "secret" } },
      { method: "GET", path: "/api/stats?period=today&compare=off", headers: { authorization: "Bearer {{secret}}" } },
      { method: "POST", path: "/api/goals", headers: { authorization: "Bearer {{secret}}", "content-type": "application/json" }, body: { name: "X", kind: "event", match: "X" } },
      { method: "GET", path: "/api/token", headers: { authorization: "Bearer {{secret}}" } },
      { method: "POST", path: "/api/goals", headers: auth, body: "not json" },
      get("/api/stats?period=nonsense"),
      get("/api/stats?period=today&filter=nope"),
      get("/api/stats?site=missing&period=today"),
      get("/api/breakdown?period=today&dimension=nope"),
      { method: "GET", path: "/e" },
      { method: "OPTIONS", path: "/e" },
      { method: "GET", path: "/api" },
    ],
  },
  {
    name: "refusals, their codes, and tickets",
    site: { hostnames: ["blog.example.com"], timezone: "UTC" },
    sites: [
      { id: "blog", hostnames: ["blog.example.com"], timezone: "UTC" },
      { id: "shop", hostnames: ["shop.example.com"], timezone: "UTC" },
    ],
    // A Wednesday, so a weekly report added now waits for Monday.
    start: Date.UTC(2026, 9, 7, 12, 0),
    token: "conformance",
    steps: [
      // A write that is not JSON, with no bearer token, as a form on another page would send it.
      { method: "POST", path: "/api/goals?site=blog", headers: { "content-type": "text/plain" }, body: "x" },
      get(`/api/stats?site=blog&period=today&${Array.from({ length: 7 }, (_, i) => `filter=page:is:/${i}`).join("&")}`),
      { method: "POST", path: "/api/link-domains?site=blog", headers: json, body: { domain: "not a domain" } },
      { method: "POST", path: "/api/link-domains?site=blog", headers: json, body: { domain: "db.internal" } },
      { method: "POST", path: "/api/link-domains?site=blog", headers: json, body: { domain: "shop.example.com" } },
      { method: "POST", path: "/api/link-domains?site=blog", headers: json, body: { domain: "go.runlight-conformance.com" } },
      { method: "POST", path: "/api/link-domains?site=shop", headers: json, body: { domain: "go.runlight-conformance.com" } },
      // A hub's manage token adds no link domain or report until the install knows its own address.
      { method: "POST", path: "/api/tokens", headers: json, body: { name: "Hub", scope: "manage", site: "blog" }, capture: { hub: "secret" } },
      { method: "POST", path: "/api/link-domains?site=blog", headers: { authorization: "Bearer {{hub}}", "content-type": "application/json" }, body: { domain: "t.runlight-conformance.com" } },
      { method: "POST", path: "/api/reports?site=blog", headers: { authorization: "Bearer {{hub}}", "content-type": "application/json" }, body: { email: "hub@example.com" } },
      // Picker tickets: the owner's names the dashboard and the site, and a hub gets none for an origin it names now.
      { method: "POST", path: "/api/pick?site=blog", headers: json, body: { origin: "https://stats.example.com" }, capture: { ticket: "ticket" } },
      { method: "GET", path: "/pick.js?runlight_ticket={{ticket}}", look: ['"https://stats.example.com"', '\\"blog.example.com\\"'] },
      { method: "GET", path: "/pick.js?runlight_ticket=0.00.00.00", look: ['"https://stats.example.com"', '\\"blog.example.com\\"'] },
      { method: "POST", path: "/api/pick?site=blog", headers: json, body: { origin: "javascript:alert(1)" } },
      { method: "POST", path: "/api/pick?site=blog", headers: { authorization: "Bearer {{hub}}", "content-type": "application/json" }, body: { origin: "https://hub.example.net" } },
      // A report: a sample with no mail service, then one too soon, and the first send waits for Monday.
      { method: "POST", path: "/api/reports?site=blog", headers: json, body: { email: "me@example.com", frequency: "weekly" }, capture: { report: "report.id" } },
      { method: "POST", path: "/api/reports/{{report}}/send?site=blog", headers: json },
      { method: "POST", path: "/api/reports/{{report}}/send?site=blog", headers: json },
      { method: "PUT", path: "/api/mail", headers: json, body: { service: "webhook", url: "https://127.0.0.1:9/", from: "reports@example.com" } },
      { method: "POST", path: "/api/check", headers: json },
      { method: "POST", path: "/api/check", headers: json, advance: 5 * 86_400_000 },
    ],
  },
];

// The version and the implementation differ between ports and releases, so they are placeholders too.
const RANDOM = new Set(["id", "token", "secret", "hint", "version", "library", "language", "ticket"]);

/** Ids and other random values become "<key>", so answers compare across runs and implementations. */
export function normalize(value: unknown, key = ""): unknown {
  if (Array.isArray(value)) return value.map((v) => normalize(v, key));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v, k)]));
  if (typeof value === "string" && (RANDOM.has(key) || /^rl_[A-Za-z0-9]+$/.test(value) || /^[a-f0-9]{24}$/.test(value))) return `<${key || "value"}>`;
  return value;
}

const dig = (value: unknown, path: string): unknown => path.split(".").reduce<unknown>((v, k) => (v && typeof v === "object" ? (v as Record<string, unknown>)[k] : undefined), value);

/** Runs a scenario's steps against this implementation and returns each answer, normalized. */
export async function play(scenario: Scenario): Promise<Answer[]> {
  let now = scenario.start;
  const rl = runlight({ store: sqlite({ path: ":memory:" }), ...(scenario.sites ? { sites: scenario.sites } : { site: scenario.site }), now: () => now });
  const { handler } = rl.routes({ token: scenario.token });
  const kept: Record<string, string> = {};
  const fill = (text: string) => text.replace(/\{\{(\w+)\}\}/g, (_, name: string) => kept[name] ?? "");
  const answers: Answer[] = [];
  for (const step of scenario.steps) {
    now += step.advance ?? 0;
    const headers = Object.fromEntries(Object.entries(step.headers ?? {}).map(([k, v]) => [k, fill(v)]));
    const body = step.body === undefined ? undefined : typeof step.body === "string" ? step.body : JSON.stringify(step.body);
    const answer = await handler(new Request(`https://example.com/runlight${fill(step.path)}`, { method: step.method, headers, ...(body === undefined ? {} : { body }) }));
    const text = await answer.text();
    let parsed: unknown;
    try {
      parsed = text ? JSON.parse(text) : undefined;
    } catch {
      parsed = undefined;
    }
    for (const [name, at] of Object.entries(step.capture ?? {})) kept[name] = String(dig(parsed, at) ?? "");
    const sent: Record<string, string> = {};
    for (const name of HEADERS) {
      const value = answer.headers.get(name);
      if (value) sent[name] = name === "content-type" ? value.split(";")[0]!.trim() : value;
    }
    answers.push({
      status: answer.status,
      ...(Object.keys(sent).length ? { headers: sent } : {}),
      ...(parsed === undefined ? {} : { body: normalize(parsed) }),
      ...(step.look ? { found: step.look.map((s) => text.includes(s)) } : {}),
    });
  }
  return answers;
}
