/**
 * The HTTP conformance runner: it plays scenarios (requests to a fresh Runlight on a fixed clock) and
 * records the answers. `npm run conformance` (in the repo root) runs the scenarios in http-scenarios.ts
 * against this implementation and writes conformance/http.json; the test replays that file on every
 * store, so the TypeScript answers and the file cannot drift. Another implementation (a PHP port)
 * replays the same file with a runner of its own, so everything here is described in the file's
 * description too (see FORMAT below), in words that do not depend on TypeScript.
 */
import { inflateRawSync } from "node:zlib";
import { runlight } from "../src/index.js";
import type { SqlStore } from "../src/store.js";
import { sqlite } from "../src/stores/sqlite.js";
import { totp } from "../src/accounts/auth.js";

export interface Step {
  /** Milliseconds to move the clock before this request. */
  advance?: number;
  method: string;
  /** Relative to the routes' base (/runlight), unless `absolute` is set or `to` names another handler. */
  path: string;
  /** Which entry point takes the request: the routes (default), the app's own short-link path, or the link-domain middleware. */
  to?: "routes" | "links" | "linkDomain";
  /** The path is from the host's root, not the routes' base. */
  absolute?: boolean;
  /** The request's host. Default example.com. */
  host?: string;
  headers?: Record<string, string>;
  /** A JSON body (an object or array, sent as JSON text) or a string sent as it is. */
  body?: unknown;
  /** Form fields, sent as application/x-www-form-urlencoded. */
  form?: Record<string, string>;
  /** The cookie jar this request uses: a name (default "main"), or false for none. */
  jar?: string | false;
  /** Values to keep from the answer for later steps' {{name}}. */
  capture?: Record<string, string>;
  /** Text to look for in an answer that is not JSON, such as a script; the answer says which was found. */
  look?: string[];
  expect?: Answer;
}

/** What a step must answer. */
export interface Answer {
  status?: number;
  headers?: Record<string, string | string[]>;
  body?: unknown;
  /** A plain text or CSV answer's text. */
  text?: string;
  /** A ZIP answer's files, in order. */
  files?: Array<{ name: string; text: string }>;
  /** For each of the step's `look` strings, whether the answer's text holds it. */
  found?: boolean[];
  /** The link-domain middleware let the request pass on to the app. */
  pass?: true;
  /** The requests the step made to other servers, in order. */
  fetched?: Fetched[];
}

export interface Fetched {
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: unknown;
}

/** A server the scenario stands in for: requests whose URL starts with `url` (and use `method`, when given) get this answer. */
export interface Upstream {
  method?: string;
  url: string;
  status?: number;
  headers?: Record<string, string>;
  body?: unknown;
}

export interface ScenarioOptions {
  /** routes({ accounts: true }): sign-in accounts, with the token as the first account's key. Needs secret. */
  accounts?: boolean;
  /** Sites are managed in the dashboard and kept in the database; site and sites are ignored. */
  managedSites?: boolean;
  /** The install's own address, routes({ origin }). */
  origin?: string;
  /** Encrypts saved keys and signs sessions. Without it there is none. */
  secret?: string;
  /** The key CMS plugins report AI agent fetches with. Without it there is none. */
  observeKey?: string;
  /** The bearer secret a platform cron may call /api/check with. Without it there is none. */
  cronSecret?: string;
  /** Tracker requests allowed per address per minute. Default 120; false for no limit. */
  rateLimit?: number | false;
}

export interface Scenario {
  name: string;
  /** The runlight() site, in its options' shape. */
  site: { hostnames: string[]; timezone: string };
  /** Several sites instead, each with its id, when a scenario needs more than one. */
  sites?: Array<{ id: string; hostnames: string[]; timezone: string; name?: string }>;
  /** Epoch milliseconds the clock starts at. */
  start: number;
  /** The routes' token; "" for none, null to leave them open. */
  token: string | null;
  options?: ScenarioOptions;
  upstream?: Upstream[];
  steps: Step[];
}

/** Headers every implementation must send the same, where it sends them. */
export const HEADERS = [
  "content-type",
  "cache-control",
  "location",
  "set-cookie",
  "www-authenticate",
  "allow",
  "content-disposition",
  "content-security-policy",
  "x-frame-options",
  "referrer-policy",
  "x-content-type-options",
  "x-robots-tag",
  "access-control-allow-origin",
  "access-control-allow-methods",
  "access-control-allow-headers",
  "access-control-max-age",
];

// The version and the implementation differ between ports and releases, so they are placeholders too.
const RANDOM = new Set(["token", "secret", "hint", "version", "library", "language", "ticket", "recovery"]);

/** Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures. */
function scrub(text: string): string {
  return text
    .replace(/([?&](?:code|ticket|secret|code_challenge)=)[^&#\s"'<>]+/g, "$1<value>")
    .replace(/(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])/g, "<hex>")
    .replace(/(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])/g, "<key>");
}

/** Ids and other random values become "<key>", so answers compare across runs and implementations. */
export function normalize(value: unknown, key = ""): unknown {
  if (Array.isArray(value)) return value.map((v) => normalize(v, key));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v, k)]));
  if (typeof value === "string") {
    if (RANDOM.has(key) || /^rlo?_[A-Za-z0-9]+$/.test(value) || /^[a-f0-9]{24}$/.test(value)) return `<${key || "value"}>`;
    return scrub(value);
  }
  return value;
}

/** A Set-Cookie header with its value as <value>, unless it clears the cookie. */
const cookieShape = (header: string) => header.replace(/^([^=;]+)=([^;]*)/, (_, name: string, value: string) => `${name}=${value ? "<value>" : ""}`);

const dig = (value: unknown, path: string): unknown => path.split(".").reduce<unknown>((v, k) => (v && typeof v === "object" ? (v as Record<string, unknown>)[k] : undefined), value);

/** The files in a ZIP, stored or deflated, by their local headers. */
function unzip(bytes: Uint8Array): Array<{ name: string; text: string }> {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const files: Array<{ name: string; text: string }> = [];
  let at = 0;
  while (at + 30 <= bytes.length && view.getUint32(at, true) === 0x04034b50) {
    const method = view.getUint16(at + 8, true);
    const size = view.getUint32(at + 18, true);
    const nameLength = view.getUint16(at + 26, true);
    const extra = view.getUint16(at + 28, true);
    const name = new TextDecoder().decode(bytes.subarray(at + 30, at + 30 + nameLength));
    const start = at + 30 + nameLength + extra;
    const data = bytes.subarray(start, start + size);
    files.push({ name, text: new TextDecoder().decode(method === 8 ? inflateRawSync(data) : data) });
    at = start + size;
  }
  return files;
}

/** A body another server was sent, as JSON or form fields when it is one of those, else its text. */
function sentBody(text: string, type: string): unknown {
  if (type.startsWith("application/x-www-form-urlencoded")) return Object.fromEntries(new URLSearchParams(text));
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/** Environment the SDK reads defaults from, cleared while a scenario plays so nothing outside it counts. */
const ENV = ["RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV"];

/** Runs a scenario's steps against this implementation and returns each answer, normalized. */
export async function play(scenario: Scenario, store: SqlStore = sqlite({ path: ":memory:" })): Promise<Answer[]> {
  const saved = ENV.map((name) => [name, process.env[name]] as const);
  for (const name of ENV) delete process.env[name];
  const realFetch = globalThis.fetch;
  let fetched: Array<{ seen: Fetched; text: string }> = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const method = (init.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
    const given = Object.fromEntries([...new Headers(init.headers ?? {}).entries()].sort(([a], [b]) => (a < b ? -1 : 1)));
    const text = typeof init.body === "string" ? init.body : init.body ? String(init.body) : "";
    fetched.push({ seen: { method, url, ...(Object.keys(given).length ? { headers: given } : {}), ...(text ? { body: sentBody(text, given["content-type"] ?? "") } : {}) }, text });
    const match = (scenario.upstream ?? []).find((u) => url.startsWith(u.url) && (!u.method || u.method === method));
    if (!match) throw new TypeError("fetch failed");
    const body = match.body === undefined ? null : typeof match.body === "string" ? match.body : JSON.stringify(match.body);
    return new Response(body, { status: match.status ?? 200, headers: { ...(typeof match.body === "object" ? { "content-type": "application/json" } : {}), ...match.headers } });
  }) as typeof fetch;
  try {
    return await steps(scenario, store, () => {
      const out = fetched;
      fetched = [];
      return out;
    });
  } finally {
    globalThis.fetch = realFetch;
    for (const [name, value] of saved) if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
}

async function steps(scenario: Scenario, store: SqlStore, takeFetched: () => Array<{ seen: Fetched; text: string }>): Promise<Answer[]> {
  let now = scenario.start;
  const options = scenario.options ?? {};
  const rl = runlight({
    store,
    ...(options.managedSites ? { managedSites: true } : scenario.sites ? { sites: scenario.sites } : { site: scenario.site }),
    ...(options.secret ? { secret: options.secret } : {}),
    ...(options.rateLimit !== undefined ? { rateLimit: options.rateLimit } : {}),
    now: () => now,
  });
  const { handler } = rl.routes({
    token: scenario.token,
    observeKey: options.observeKey ?? "",
    cronSecret: options.cronSecret ?? "",
    ...(options.accounts ? { accounts: true } : {}),
    ...(options.origin ? { origin: options.origin } : {}),
  });
  const links = rl.linkHandler();
  const kept: Record<string, string> = {};
  const jars = new Map<string, Map<string, string>>();
  const fill = (text: string) => text.replace(/\{\{(\w+)\}\}/g, (_, name: string) => kept[name] ?? "");
  const fillTotp = async (text: string) => {
    let out = text;
    for (const [whole, name] of text.matchAll(/\{\{totp:(\w+)\}\}/g)) out = out.replace(whole, await totp(kept[name!] ?? "", Math.floor(now / 30_000)));
    return fill(out);
  };
  const fillDeep = async (value: unknown): Promise<unknown> => {
    if (typeof value === "string") return fillTotp(value);
    if (Array.isArray(value)) return Promise.all(value.map(fillDeep));
    if (value && typeof value === "object") return Object.fromEntries(await Promise.all(Object.entries(value).map(async ([k, v]) => [k, await fillDeep(v)])));
    return value;
  };
  const answers: Answer[] = [];
  for (const step of scenario.steps) {
    now += step.advance ?? 0;
    const headers: Record<string, string> = {};
    for (const [k, v] of Object.entries(step.headers ?? {})) headers[k.toLowerCase()] = await fillTotp(v);
    let body: string | undefined;
    if (step.form) {
      body = new URLSearchParams((await fillDeep(step.form)) as Record<string, string>).toString();
      headers["content-type"] ??= "application/x-www-form-urlencoded";
    } else if (step.body !== undefined) {
      body = typeof step.body === "string" ? await fillTotp(step.body) : JSON.stringify(await fillDeep(step.body));
    }
    const jar = step.jar === false ? null : (jars.get(step.jar ?? "main") ?? jars.set(step.jar ?? "main", new Map()).get(step.jar ?? "main")!);
    if (jar?.size && headers.cookie === undefined) headers.cookie = [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
    const to = step.to ?? "routes";
    const prefix = to === "routes" && !step.absolute ? "/runlight" : "";
    const request = new Request(`https://${step.host ?? "example.com"}${prefix}${await fillTotp(step.path)}`, { method: step.method, headers, ...(body === undefined ? {} : { body }) });
    takeFetched();
    const answer = to === "links" ? await links(request) : to === "linkDomain" ? await rl.linkDomainResponse(request) : await handler(request);
    // Work the request started after answering (retention) finishes before the next one, as it would between real requests.
    await rl.idle();
    const sentOut = takeFetched();
    const outbound = sentOut.map((f) => normalize(f.seen) as Fetched);
    if (!answer) {
      answers.push({ pass: true, ...(outbound.length ? { fetched: outbound } : {}) });
      continue;
    }
    const bytes = new Uint8Array(await answer.arrayBuffer());
    const text = new TextDecoder().decode(bytes);
    const type = (answer.headers.get("content-type") ?? "").split(";")[0]!.trim();
    let parsed: unknown;
    if (type !== "application/zip") {
      try {
        parsed = text ? JSON.parse(text) : undefined;
      } catch {
        parsed = undefined;
      }
    }
    for (const [name, spec] of Object.entries(step.capture ?? {})) {
      const cut = spec.indexOf("~");
      const source = cut < 0 ? spec : spec.slice(0, cut);
      const pattern = cut < 0 ? null : spec.slice(cut + 1);
      let value: string;
      if (source === "text") value = text;
      else if (source === "fetched") value = sentOut.map((f) => f.text).join("\n");
      else if (source.startsWith("header:")) {
        const header = source.slice("header:".length).toLowerCase();
        value = header === "set-cookie" ? answer.headers.getSetCookie().join("\n") : (answer.headers.get(header) ?? "");
      } else value = String(dig(parsed, source) ?? "");
      kept[name] = pattern === null ? value : (new RegExp(pattern).exec(value)?.[1] ?? "");
    }
    for (const cookie of answer.headers.getSetCookie()) {
      if (!jar) continue;
      const [pair, ...attributes] = cookie.split(";");
      const name = pair!.slice(0, pair!.indexOf("=")).trim();
      const value = pair!.slice(pair!.indexOf("=") + 1).trim();
      if (!value || attributes.some((a) => /^\s*max-age=0\s*$/i.test(a))) jar.delete(name);
      else jar.set(name, value);
    }
    const sent: Record<string, string | string[]> = {};
    for (const name of HEADERS) {
      if (name === "set-cookie") {
        const cookies = answer.headers.getSetCookie();
        if (cookies.length) sent[name] = cookies.map(cookieShape);
        continue;
      }
      const value = answer.headers.get(name);
      if (value) sent[name] = name === "content-type" ? value.split(";")[0]!.trim() : (normalize(value) as string);
    }
    answers.push({
      status: answer.status,
      ...(Object.keys(sent).length ? { headers: sent } : {}),
      ...(parsed === undefined ? {} : { body: normalize(parsed) }),
      ...(parsed === undefined && (type === "text/plain" || type === "text/csv") ? { text: normalize(text) as string } : {}),
      ...(type === "application/zip" ? { files: unzip(bytes).map((f) => ({ name: f.name, text: normalize(f.text) as string })) } : {}),
      ...(step.look ? { found: step.look.map((s) => text.includes(s)) } : {}),
      ...(outbound.length ? { fetched: outbound } : {}),
    });
  }
  return answers;
}

/** How the file is read, written into it for the other implementations' runners. */
export const FORMAT = [
  "HTTP requests to a fresh Runlight on a fixed clock, and the answers every implementation must give. Each scenario runs on an empty database with the scenario's site (or sites, each with its id, in place of site), its token as the routes' token (an empty string for none, null to leave them open), and its options, then plays its steps in order. Nothing from the environment counts: no RUNLIGHT_TOKEN, RUNLIGHT_SECRET, CRON_SECRET, RUNLIGHT_OBSERVE_KEY, or NODE_ENV.",
  "Scenario options: accounts (sign-in accounts on, as routes({ accounts: true }), with the token as the key the first account is made with), managedSites (sites are kept in the database and managed through the API; site and sites are ignored), origin (the install's own address), secret (encrypts saved keys and signs sessions; none without it), observeKey (the install-wide key for POST /api/observe; none without it), cronSecret (the bearer secret POST and GET /api/check also take; none without it), and rateLimit (tracker requests per address per minute, default 120, false for none).",
  "Before each step the clock moves by advance milliseconds, and work a request starts after answering (such as deleting visits past a shorter retention) is finished before the next step. A step is method, path, headers, and a body: body is a JSON value sent as JSON text (with no content type unless headers name one), or a string sent as it is; form is fields sent as application/x-www-form-urlencoded. The request goes to https://{host}/runlight{path}, where host is the step's host or example.com. A step's to picks the entry point: routes (the default), links (the app's own short-link path, linkHandler(), with path from the host's root such as /go/sale), or linkDomain (the middleware for link domains, linkDomainResponse(), with path from the host's root). absolute: true sends a routes path from the host's root instead of under /runlight, as for /.well-known/ at the site's root.",
  "Cookies: each scenario has cookie jars, named by a step's jar (default main; false sends and keeps none). Every Set-Cookie in an answer goes into the step's jar (an empty value or Max-Age=0 removes it), and a request sends its jar's cookies as one Cookie header (name=value pairs joined by '; ') unless its headers give a cookie.",
  "Templates: {{name}} in a path, a header, a body string, or a form field is a value captured earlier (empty when nothing was), and {{totp:name}} is the six-digit TOTP code (RFC 6238: SHA-1, 30 second steps, base32 secret) for the captured secret at the step's clock. capture keeps values from an answer: a dotted path into its JSON body (a.b.0.c), header:<name> for a response header (all of its Set-Cookie lines joined by newlines for set-cookie), text for the raw body, or fetched for the bodies of the requests the step made to other servers, joined by newlines; any of them followed by ~<regex> keeps the regex's first group instead. Captures read the answer as sent, before it is normalized.",
  "Answers: status, headers, body, text, files, found, fetched, or pass. headers holds those of content-type (its media type only), cache-control, location, set-cookie (a list, one per cookie, with each value written <value> unless it is empty), www-authenticate, allow, content-disposition, content-security-policy, x-frame-options, referrer-policy, x-content-type-options, x-robots-tag, and the access-control-allow-origin, -methods, -headers, and -max-age headers that the answer sends, and none it does not. body is a JSON answer's body. text is a text/plain or text/csv answer's body. files lists a ZIP answer's files in order, each with its name and text. A step's look lists text to find in an answer that is not JSON, such as a page or a script, and found says which of them it holds. pass: true means the link-domain middleware let the request through to the app.",
  "Other servers: upstream lists servers the scenario stands in for. A request the implementation makes to another server goes to the first upstream whose url its URL starts with (and whose method matches, when one is given), which answers with that status (default 200), headers, and body (a JSON value sent as JSON with application/json, or a string sent as it is). A request no upstream matches fails as a network error does. fetched lists every such request a step made, in order, each with its method, url, the headers the implementation set (lowercased, sorted), and its body (parsed as JSON, or as form fields when it is application/x-www-form-urlencoded, else text).",
  "Normalizing, applied to bodies, text, files, header values, and fetched requests alike: a string whose key is token, secret, hint, version, library, language, ticket, or recovery, or that is a whole rl_ or rlo_ token or 24 hex digits, becomes <k>, where k is its key's name (value for a string with no key). In other strings, the value of a code, ticket, secret, or code_challenge query parameter becomes <value>, every run of 24 or more lowercase hex digits not next to another letter or digit becomes <hex>, and every rl_ or rlo_ token of 20 or more characters becomes <key>.",
].join("\n\n");
