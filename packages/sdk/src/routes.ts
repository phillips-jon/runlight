import { AssistantError, PROVIDERS, chat, listModels } from "./assistant.js";
import { ConnectError, finishConnect, startConnect } from "./connect.js";
import { PAGES_PER_VISIT, journeys } from "./journeys.js";
import { JOURNEY_VISITS, type ReportRow, type ShareRow, type SiteRow, type TokenRow } from "./store.js";
import { DASHBOARD_CSS, DASHBOARD_HASH, DASHBOARD_JS, LOCALES, LOCALES_HASH, WORLD_HASH, WORLD_JSON } from "./generated/dashboard.js";
import { PICKER, TRACKER, TRACKER_HASH } from "./generated/tracker.js";
import { hmac, randomId, sha256 } from "./hash.js";
import { DIMENSIONS, isDimension, isSessionDimension, MAX_FILTERS, parseFilter, type Filter, type Query } from "./query.js";
import { EMAIL, LINK_DOMAIN_CHECK, RETENTION_MONTHS, envValue as env, type RequestContext, type Runlight } from "./runlight.js";
import { mcpResponse } from "./mcp.js";
import { readablePath } from "./sources.js";
import { oauthResponse, resourceMetadataUrl } from "./oauth.js";
import { csv, zip } from "./zip.js";
import { GoalError, clickRules, goalFrom } from "./goals.js";
import { FunnelError, funnelFrom } from "./funnels.js";
import { MailError, SERVICES } from "./mail/transports.js";
import { languages, translator } from "./messages.js";
import { fetchIcon } from "./icon.js";
import { publicAddresses, publicFetch, resolvesPrivately } from "./safefetch.js";
import { ImportError, importStep } from "./importers/index.js";
import { importCsvVisits, importUmamiVisits, umamiWebsites } from "./importers/visits.js";
import { LinkError } from "./links.js";
import { lastPeriod } from "./reports.js";
import { buckets, compareRange, isTimezone, localDate, localWeekdayHour, resolveRange, type CompareMode } from "./time.js";
import { API_VERSION, VERSION } from "./version.js";
import { RUNLIGHT_ICON } from "./brand.js";
import { accountsWeb, type AccountsWeb } from "./accounts/web.js";

export interface RoutesOptions {
  /** Where the routes are mounted. Default "/runlight". */
  basePath?: string;
  /**
   * Required to read stats. Send it as `Authorization: Bearer <token>`, or
   * open the dashboard once with `?token=<token>` and a cookie is set.
   * Defaults to process.env.RUNLIGHT_TOKEN. Without one, the dashboard and API
   * are open only when NODE_ENV is "development", and answer 503 everywhere
   * else. Pass `null` to leave them open everywhere, for example behind your
   * own auth middleware. On an edge runtime, pass the token from its env.
   */
  token?: string | null;
  /**
   * Your own check instead of a token. Return true for full access, "member"
   * to let the request change everything but the install-wide controls (the
   * mail service, the assistant's settings, and deleting a site), "read" to
   * let it read every site's stats and change nothing (as an API token can),
   * or false to refuse it.
   */
  authorize?: (request: Request) => boolean | "member" | "read" | Promise<boolean | "member" | "read">;
  /**
   * Also accepted as a bearer token on POST /api/check, so a platform cron
   * can run scheduled work. Defaults to process.env.CRON_SECRET.
   */
  cronSecret?: string;
  /**
   * Lets another site report AI agent fetches to POST /api/observe without
   * the dashboard token: what the WordPress, Drupal, and Craft plugins use.
   * Defaults to process.env.RUNLIGHT_OBSERVE_KEY. The token works too.
   */
  observeKey?: string;
  /** A link to sign out, shown in the dashboard's footer. The standalone server sets it. */
  signOut?: string;
  /**
   * Where to sign in: an app connecting over OAuth sends the owner here first, and the dashboard
   * links here when a session ends. The standalone server sets it.
   */
  signIn?: string;
  /**
   * Sign-in accounts for the dashboard, with Settings, People to invite others as admins, members, or viewers.
   * The first account is created at /runlight/setup with RUNLIGHT_TOKEN, or openly in development without one.
   * Sessions are signed with RUNLIGHT_SECRET (or the token). The standalone server passes its own.
   */
  accounts?: boolean | AccountsWeb;
  /** Credits DB-IP in the dashboard's footer, as its free location data asks. The standalone server sets it. */
  geoCredit?: boolean;
  /**
   * The address people open the app at, such as https://example.com. A link
   * domain can never be its host, and links in email reports point there,
   * whatever Host header a request carries. Without it, the request's own
   * host stands in.
   */
  origin?: string;
  /**
   * More names the dashboard is reached at, which can never be link domains
   * either. The standalone server passes the ones owners signed in from.
   */
  ownHosts?: () => Promise<Iterable<string>>;
  /**
   * @internal For the standalone server's accounts: the account a request
   * comes from, so the tokens someone makes and the apps they connect are
   * noted against them.
   */
  accountOf?: (request: Request) => Promise<string | null>;
  /** @internal Notes who made a token. False when they can no longer make one, which takes it back. */
  tokenMade?: (token: TokenRow, by: string) => Promise<boolean>;
}

export type FetchHandler = (request: Request, context?: RequestContext) => Promise<Response>;

export interface Routes {
  handler: FetchHandler;
  GET: FetchHandler;
  POST: FetchHandler;
  PUT: FetchHandler;
  PATCH: FetchHandler;
  DELETE: FetchHandler;
  OPTIONS: FetchHandler;
}

const COOKIE = "runlight_token";
const IMPLEMENTATION = { library: "@runlight/sdk", language: "typescript" };

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some clients try first. */
const isOauthDocument = (path: string): boolean => path.startsWith("/.well-known/oauth-") || path.startsWith("/.well-known/openid-configuration");

function isDevelopment(): boolean {
  return env("NODE_ENV") === "development";
}

/**
 * An error the dashboard can show in its own language: `code` names it and
 * `params` fill its placeholders, while `error` stays the English message.
 */
export function coded(error: string, code: string, status: number, params?: Record<string, string>, headers: Record<string, string> = {}): Response {
  return json({ error, code, ...(params ? { params } : {}) }, status, headers);
}

/**
 * A refusal from a check elsewhere: its own code and params when the error
 * carries them, or else `fallback` with its English words as `detail`.
 */
function refused(error: Error, fallback: string, status = 400): Response {
  const own = error as Error & { code?: unknown; params?: Record<string, string> };
  return typeof own.code === "string" ? coded(error.message, own.code, status, own.params) : coded(error.message, fallback, status, { detail: error.message });
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", ...headers },
  });
}

/**
 * Whether a request's body is JSON by its media type. A cross-site form or a
 * no-cors fetch can only send text/plain, urlencoded, or multipart, so a JSON
 * media type proves the request came from a page allowed to send it. A
 * substring test would accept "text/plain; application/json", which can.
 */
function isJson(request: Request): boolean {
  return (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() === "application/json";
}

/** A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www. */
export function hostName(value: string): string {
  const first = value.split(",")[0]!.trim().toLowerCase();
  const name = first.startsWith("[") ? first.slice(0, first.indexOf("]") + 1) : first.replace(/:\d*$/, "");
  return name.replace(/\.+$/, "").replace(/^www\./, "");
}

/** A domain name, such as go.example.com. */
export const DOMAIN_NAME = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/**
 * Whether a domain name is one kept for private networks or tests, or has
 * an IPv4 address inside it (as nip.io answers). The link-domain check
 * fetches from it, so a name inside the install's own network must never
 * get that far; names that only resolve there are refused when fetched.
 */
function privateName(domain: string): boolean {
  if (/(^|\.)\d{1,3}(\.\d{1,3}){3}(\.|$)/.test(domain)) return true;
  return /\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)$/.test(domain);
}

/**
 * Answers a read for a site counted by another install by asking that install,
 * with its token and its own id for the site, and handing back what it says.
 */
async function passThrough(remote: { url: string; token: string; site: string }, path: string, url: URL, request?: Request): Promise<Response> {
  const target = new URL(`${remote.url}${path}`);
  url.searchParams.forEach((value, key) => target.searchParams.append(key, value));
  target.searchParams.set("site", remote.site);
  // A change made from the hub goes on to the install with its JSON body; reads carry none.
  const write = request && request.method !== "GET" && request.method !== "HEAD";
  const headers: Record<string, string> = { authorization: `Bearer ${remote.token}` };
  if (write && request.headers.get("content-type")) headers["content-type"] = request.headers.get("content-type")!;
  let answer: Response;
  try {
    answer = await fetch(target, {
      method: write ? request.method : "GET",
      headers,
      ...(write ? { body: await request.text() } : {}),
      // An install that answers with a redirect gets no fetch of somewhere else on its behalf.
      redirect: "manual",
      // A long report or an export is worked out in full before the install sends a byte, so reads get
      // two minutes. A browser that leaves stops the wait too.
      signal: AbortSignal.any([AbortSignal.timeout(write ? 30_000 : 120_000), ...(request ? [request.signal] : [])]),
    });
  } catch (error) {
    const host = new URL(remote.url).host;
    if ((error as Error)?.name === "TimeoutError") return coded(`${host} took too long to answer. Try a shorter range.`, "remote_slow", 504, { host });
    return coded(`Could not reach ${host}`, "unreachable", 502, { host });
  }
  // What comes back is shown from this server's origin, so it is never taken as a page:
  // JSON, or a download for exports, with sniffing off and nothing allowed to run.
  const download = /^\/api\/export$/.test(path) || (path === "/api/breakdown" && url.searchParams.get("format") === "csv");
  const back: Record<string, string> = {
    "cache-control": "private, no-store",
    "x-content-type-options": "nosniff",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "content-type": download ? (answer.headers.get("content-type")?.startsWith("text/csv") ? "text/csv; charset=utf-8" : "application/zip") : "application/json; charset=utf-8",
  };
  if (download) {
    const name = /filename="([A-Za-z0-9._-]+)"/.exec(answer.headers.get("content-disposition") ?? "")?.[1] ?? "runlight-export";
    back["content-disposition"] = `attachment; filename="${name}"`;
  }
  if (answer.status >= 300 && answer.status < 400) return coded(`${new URL(remote.url).host} answered with a redirect`, "redirected", 502, { host: new URL(remote.url).host });
  // The install's own errors say what went wrong there; a refused token is this server's problem to report.
  if (answer.status === 401) return coded(`${new URL(remote.url).host} refused the token. Connect it again from the site's settings.`, "token_refused", 502, { host: new URL(remote.url).host });
  // An install's own error is shown here, so it says where it came from, keeps only short text, and
  // carries its code and params for the dashboard to put in its own words.
  if (answer.status >= 400 && !download) {
    const host = new URL(remote.url).host;
    const text = await answer.text().catch(() => "");
    const body = (() => {
      try {
        return text.length <= 65_536 ? (JSON.parse(text) as { error?: unknown; code?: unknown; params?: unknown }) : null;
      } catch {
        return null;
      }
    })();
    const params = body?.params && typeof body.params === "object" ? Object.entries(body.params as Record<string, unknown>).filter(([, v]) => typeof v === "string").slice(0, 10).map(([k, v]) => [k.slice(0, 40), (v as string).slice(0, 200)]) : [];
    return json(
      {
        error: `${host}: ${typeof body?.error === "string" ? body.error.slice(0, 300) : `answered ${answer.status}`}`,
        ...(typeof body?.code === "string" && /^[a-z_]{1,40}$/.test(body.code) ? { code: body.code, params: Object.fromEntries(params) } : {}),
      },
      answer.status,
      back,
    );
  }
  return new Response(answer.body, { status: answer.status, headers: back });
}

/** A plain page in a visitor's language, for unsubscribing and for a share link that is gone. */
function smallPage(lang: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Runlight</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>${body}</main></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
        "referrer-policy": "no-referrer",
      },
    },
  );
}

/** The first language a browser asks for that the dashboard speaks, else English. */
function acceptedLanguage(request: Request): string {
  for (const part of (request.headers.get("accept-language") ?? "").split(",")) {
    const code = part.split(";")[0]!.trim().slice(0, 2).toLowerCase();
    if (languages().includes(code)) return code;
  }
  return "en";
}

/** Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads. */
function rowsCsv(rows: ReadonlyArray<object>, sheet: { timezone: string; interval?: string; dimension?: string }): string {
  const readable = rows.map((r) => sheetRow(r as Record<string, unknown>, sheet));
  const header = readable.length ? Object.keys(readable[0]!) : ["value"];
  return csv(header, readable.map((r) => header.map((k) => r[k])));
}

/**
 * One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
 * durations in seconds, and paths as people write them.
 */
function sheetRow(row: Record<string, unknown>, sheet: { timezone: string; interval?: string; dimension?: string }): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (key === "start" && typeof value === "number") {
      const hour = sheet.interval === "hour" ? ` ${String(localWeekdayHour(value, sheet.timezone)[1]).padStart(2, "0")}:00` : "";
      out.date = `${localDate(value, sheet.timezone)}${hour}`;
    } else if (key === "bounceRate" && typeof value === "number") out.bounceRatePercent = Math.round(value * 1000) / 10;
    else if ((key === "visitDuration" || key === "timeOnPage") && typeof value === "number") out[`${key}Seconds`] = Math.round(value / 1000);
    else if (key === "value" && typeof value === "string" && PATH_DIMENSIONS.has(sheet.dimension ?? "")) out.value = readablePath(value);
    else out[key] = value;
  }
  return out;
}

const PATH_DIMENSIONS = new Set(["page", "entry", "exit", "ai_page"]);

/** A file to save, never shown in the browser or kept in a shared cache. */
function download(name: string, body: string | Uint8Array, type: string): Response {
  return new Response(body as BodyInit, {
    headers: { "content-type": type, "content-disposition": `attachment; filename="${name.replace(/[^A-Za-z0-9._-]/g, "-")}"`, "cache-control": "private, no-store" },
  });
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function cookieValue(token: string): Promise<string> {
  return sha256(`runlight-cookie:${token}`);
}

function readCookie(request: Request, name: string): string {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return "";
}

function bearer(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  return header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
}

function normaliseBase(path: string): string {
  const trimmed = `/${path.replace(/^\/+|\/+$/g, "")}`;
  return trimmed === "/" ? "" : trimmed;
}

function escapeAttr(value: string): string {
  return value.replace(/[&"<>]/g, (c) => `&#${c.charCodeAt(0)};`);
}

function localeUrls(base: string): string {
  return JSON.stringify(Object.fromEntries(Object.keys(LOCALES).map((code) => [code, `${base}/assets/locale.${code}.${LOCALES_HASH}.json`])));
}

export { RUNLIGHT_ICON };

/** The dashboard inside a CMS's admin pages: its session (empty once its ticket was used or ran out) and the admin origin that frames it. */
interface Embedded {
  session: string;
  origin: string;
}

const DASHBOARD = (base: string, share = "", signOut = "", geoCredit = false, accounts = false, signIn = "", embed: Embedded | null = null) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Runlight</title>
<link rel="icon" href="${RUNLIGHT_ICON}">
<link rel="stylesheet" href="${escapeAttr(base)}/assets/app.${DASHBOARD_HASH}.css">
</head>
<body>
<div id="app" data-base="${escapeAttr(base)}"${share ? ` data-share="${escapeAttr(share)}"` : ""}${signOut ? ` data-sign-out="${escapeAttr(signOut)}"` : ""}${signIn ? ` data-sign-in="${escapeAttr(signIn)}"` : ""}${geoCredit ? ` data-geo-credit=""` : ""}${accounts ? ` data-accounts=""` : ""}${embed ? ` data-embed="${escapeAttr(embed.session)}" data-embed-origin="${escapeAttr(embed.origin)}"` : ""} data-world="${escapeAttr(base)}/assets/world.${WORLD_HASH}.json" data-locales="${escapeAttr(localeUrls(base))}"></div>
<script type="module" src="${escapeAttr(base)}/assets/app.${DASHBOARD_HASH}.js"></script>
</body>
</html>
`;

/** API tokens start with this, so they are told apart from the main token. */
const TOKEN_PREFIX = "rl_";

/** The header a shared dashboard sends its share id in. */
const SHARE_HEADER = "x-runlight-share";
/** The header an embedded dashboard sends its session in. */
const EMBED_HEADER = "x-runlight-embed";
/** What a share, or the dashboard inside a CMS, can read: one site's reports, nothing that changes anything. */
const SHARED_PATHS = new Set(["/api/sites", "/api/icon", "/api/realtime", "/api/stats", "/api/series", "/api/rhythm", "/api/breakdown", "/api/goals", "/api/event-props", "/api/export", "/api/funnels", "/api/journeys"]);
const sharedPath = (path: string) => SHARED_PATHS.has(path) || /^\/api\/goals\/[a-f0-9]{24}$/.test(path);

/**
 * What a manage token, held by a Runlight hub, may read and change: one
 * site's goals, funnels, short links, link domains, email reports, and share
 * links, along with its name, timezone, and retention, and tickets for the
 * element picker. It may read which mail service sends reports, through GET
 * /api/mail, which hides the service's keys. Never people, tokens, changes to
 * the mail service, imports, or other sites.
 */
export function managePath(method: string, path: string): boolean {
  if (/^\/api\/links\/import/.test(path)) return false;
  if (/^\/api\/(links|link-domains|reports|goals|funnels|shares)(\/|$)/.test(path)) return true;
  if (path === "/api/pick") return method === "POST";
  if (path === "/api/mail") return method === "GET";
  if (/^\/api\/sites\/[^/]+$/.test(path)) return method === "PATCH";
  return false;
}
/** Where the tracker's click rules go; the script ships with this string in their place. */
const RULES_PLACEHOLDER = '"__RUNLIGHT_RULES__"';
/** Where the picker's one allowed receiver goes, the dashboard origin its ticket names. */
const PICK_TARGET_PLACEHOLDER = '"__RUNLIGHT_PICK_TARGET__"';
/** Where the hostnames of the site its ticket names go, as JSON inside a string. */
const PICK_HOSTS_PLACEHOLDER = '"__RUNLIGHT_PICK_HOSTS__"';
/** A dashboard's origin, which a picker ticket names. */
const ORIGIN = /^https?:\/\/[^/?#\s]+$/;
/** How long a picker ticket works: long enough to find the element, not to be kept. */
const PICK_TICKET_MS = 30 * 60_000;
/** Questions one person may put to the assistant in an hour, and at once. */
const ASK_PER_HOUR = 30;
const ASK_AT_ONCE = 2;
/** Questions each viewer may ask a day, until an owner sets another number. */
const VIEWER_DAILY = 50;
const SHARE_ID = /^[a-f0-9]{32}$/;
/** How long an embed ticket works: long enough for the admin page to load its frame, never to be kept. */
const EMBED_TICKET_MS = 5 * 60_000;
/** How long an embedded dashboard reads before the admin page has to be loaded again for a new ticket. */
const EMBED_SESSION_MS = 60 * 60_000;

const DASHBOARD_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export function createRoutes(runlight: Runlight, options: RoutesOptions = {}): Routes {
  const base = normaliseBase(options.basePath ?? "/runlight");
  const token = options.token === undefined ? env("RUNLIGHT_TOKEN") : options.token;
  const cronSecret = options.cronSecret ?? env("CRON_SECRET");
  const observeKey = options.observeKey ?? env("RUNLIGHT_OBSERVE_KEY");
  const origin = options.origin ? new URL(options.origin).origin : null;
  // A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
  runlight.routeBases.add(base || "/");
  let warned = false;

  // Accounts: the standalone server passes its own, and an app turns them on with true. Sessions need a secret
  // that outlives the process; in development without one, a made-up one does, so a restart signs everyone out.
  // An app left open on purpose (token: null) is treated like development here.
  const openSetup = token === null || (!token && isDevelopment());
  const accountSecret = runlight.secret ?? (openSetup ? randomId(32) : null);
  const web: AccountsWeb | null =
    typeof options.accounts === "object"
      ? options.accounts
      : options.accounts === true && accountSecret
        ? accountsWeb({
            runlight,
            secret: accountSecret,
            base,
            now: () => runlight.now(),
            // The app's token proves who may make the first account; in development without one, anyone may.
            firstAccount: token ? { token } : openSetup ? "open" : "locked",
            ...(options.origin ? { home: async () => new URL(options.origin!).origin } : {}),
            forgot: "https://runlight.sh/docs/configuration/#accounts",
          })
        : null;

  // Requests from a manage token, already checked against its one site, act as the owner's.
  const managed = new WeakMap<Request, TokenRow>();
  // Requests from a member: full access apart from the install-wide controls.
  const members = new WeakSet<Request>();
  /** The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site. */
  const adminOnly = (path: string, method: string) =>
    (path === "/api/mail" && (method === "PUT" || method === "DELETE")) ||
    (path === "/api/assistant" && (method === "PUT" || method === "DELETE")) ||
    (path === "/api/assistant/limits" && method === "PUT") ||
    (path === "/api/assistant/models" && method === "POST") ||
    (/^\/api\/sites\/[^/]+$/.test(path) && method === "DELETE");
  // When each report's last sample went out.
  const sampleSent = new Map<string, number>();
  // Each person's questions to the assistant in the last hour, and how many are being answered now.
  const asked = new Map<string, { at: number[]; open: number }>();

  /** Whether this request acts as the owner. "read" is someone signed in who may only read, such as a viewer. */
  async function canRead(request: Request): Promise<boolean | "unconfigured" | "read"> {
    if (managed.has(request)) return true;
    if (options.authorize || web) {
      // A script's bearer token still has full access beside the sign-ins.
      const given = bearer(request);
      if (!options.authorize && token && given && constantTimeEqual(given, token)) return true;
      const answer = options.authorize ? await options.authorize(request) : await web!.access(request);
      // A member changes things like an owner, apart from the few controls adminOnly() names.
      if (answer === "member") members.add(request);
      return answer === "read" ? "read" : answer === true || answer === "member";
    }
    if (token === null) return true;
    if (!token) {
      // Fails closed: only a process that says it is in development runs open.
      // A plain `node` server or an edge runtime with no NODE_ENV stays locked.
      if (!isDevelopment()) return "unconfigured";
      if (!warned) {
        warned = true;
        console.warn("Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.");
      }
      return true;
    }
    const given = bearer(request);
    if (given && constantTimeEqual(given, token)) return true;
    const cookie = readCookie(request, COOKIE);
    return Boolean(cookie) && constantTimeEqual(cookie, await cookieValue(token));
  }

  /** An API token from the bearer header: read-only, and maybe limited to one site. */
  async function apiToken(request: Request): Promise<TokenRow | null> {
    const given = bearer(request);
    if (!given.startsWith(TOKEN_PREFIX)) return null;
    await runlight.init();
    const row = await runlight.store.tokenByHash(await sha256(given));
    if (!row) return null;
    const now = runlight.now();
    // At most once a minute, so a busy assistant does not write on every call.
    if (row.lastUsedAt === null || now - row.lastUsedAt > 60_000) await runlight.store.touchToken(row.id, now);
    return row;
  }

  /** Who may read stats: the owner (true), an API token or a read-only sign-in, or nobody. */
  async function reader(request: Request): Promise<true | TokenRow | false | "unconfigured"> {
    const token = await apiToken(request);
    // A key for the dashboard inside a CMS gets tickets and reads nothing itself.
    if (token) return token.scope === "embed" ? false : token;
    if (options.authorize || web) {
      const access = await canRead(request);
      // A read-only sign-in reads like an API token for every site.
      return access === "read" ? { id: "", name: "", site: "", scope: "read", hash: "", hint: "", createdAt: 0, lastUsedAt: null } : access === true;
    }
    const access = await canRead(request);
    return access === "read" ? false : access;
  }

  /** The refusal for a hub that asks for something only safe once this app knows its own address. */
  const originNeeded = () =>
    coded("Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.", "origin_needed", 400);

  function denied(result: false | "unconfigured" | "read"): Response {
    if (result === "read") return coded("Only an owner can change this", "owner_only", 403);
    return result === "unconfigured"
      ? coded("Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.", "token_unset", 503)
      : coded("Unauthorized", "unauthorized", 401);
  }

  async function querySite(url: URL): Promise<SiteRow | Response> {
    const site = runlight.site(url.searchParams.get("site"));
    return site ?? coded("Unknown site", "unknown_site", 404);
  }

  async function readQuery(url: URL, site: SiteRow) {
    const filters: Filter[] = [];
    if (url.searchParams.getAll("filter").length > MAX_FILTERS) return coded(`Use at most ${MAX_FILTERS} filters at once.`, "filters_max", 400, { max: String(MAX_FILTERS) });
    for (const raw of url.searchParams.getAll("filter")) {
      const filter = parseFilter(raw);
      if (!filter) return coded(`Bad filter "${raw}". Use dimension:is|not|contains:value.`, "filter_bad", 400, { filter: raw });
      filters.push(filter);
    }
    const now = runlight.now();
    let firstDate: string | undefined;
    if (url.searchParams.get("period") === "all") {
      const first = await runlight.store.firstSeen(site.id);
      if (first !== null) firstDate = localDate(first, site.timezone);
    }
    const range = resolveRange(
      {
        period: url.searchParams.get("period"),
        from: url.searchParams.get("from"),
        to: url.searchParams.get("to"),
        interval: url.searchParams.get("interval"),
      },
      site.timezone,
      now,
      firstDate,
    );
    if (!range) return coded("Bad date range. Use period, or from and to as YYYY-MM-DD.", "range_bad", 400);
    const query: Query = { site: site.id, from: range.from, to: range.to, filters };
    // compare=false is the older spelling of off.
    const raw = url.searchParams.get("compare") ?? "previous";
    const mode = (raw === "false" ? "off" : raw) as CompareMode;
    if (!["previous", "year", "custom", "off"].includes(mode)) return coded(`Bad compare "${raw}". Use previous, year, custom, or off.`, "compare_bad", 400, { compare: raw });
    const compared = compareRange(range, mode, site.timezone, { from: url.searchParams.get("compare_from"), to: url.searchParams.get("compare_to") });
    if (mode === "custom" && !compared) return coded("Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.", "compare_range_bad", 400);
    return { query, range, compared };
  }

  async function readJson(request: Request): Promise<Record<string, unknown> | Response> {
    // A form posted from another site cannot carry this content type without CORS.
    if (!isJson(request)) return coded("Send JSON", "send_json", 415);
    const body = (await request.json().catch(() => null)) as unknown;
    return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : coded("Send a JSON object", "send_object", 400);
  }

  async function linksApi(request: Request, path: string, url: URL): Promise<Response> {
    await runlight.init();
    const site = await querySite(url);
    if (site instanceof Response) return site;
    try {
      if (path === "/api/link-domains") {
        if (request.method === "GET") return json({ domains: (await runlight.store.linkDomains()).filter((d) => d.site === site.id).map((d) => d.domain) });
        if (request.method === "POST") {
          const body = await readJson(request);
          if (body instanceof Response) return body;
          const domain = String(body.domain ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/\.+$/, "").replace(/^www\./, "");
          if (!DOMAIN_NAME.test(domain)) return coded("That is not a domain name", "domain_invalid", 400);
          if (privateName(domain) || (await resolvesPrivately(domain))) return coded(`${domain} is not a public domain name. Use one that browsers anywhere can reach.`, "domain_not_public", 400, { domain });
          // A link domain answers every path on it, so it must never be where the dashboard or a counted site lives.
          // The request's own Host is the caller's to choose, so the configured address and the names people
          // signed in from count too. A hub cannot know every name this app answers on, so it adds none until
          // the app knows its own address.
          if (managed.has(request) && !origin) return originNeeded();
          const here = [request.headers.get("host"), request.headers.get("x-forwarded-host"), url.host].filter((h): h is string => Boolean(h));
          const own = [...(origin ? [new URL(origin).host] : []), ...here, ...((await options.ownHosts?.()) ?? [])].map(hostName);
          const taken = new Set([...own, ...runlight.sites.flatMap((s) => s.hostnames), ...runlight.sites.flatMap((s) => runlight.remote(s.id)?.hostnames ?? [])]);
          if (taken.has(domain)) return coded(`${domain} is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.${domain}.`, "domain_in_use", 400, { domain });
          const owner = (await runlight.store.linkDomains()).find((d) => d.domain === domain);
          if (owner && owner.site !== site.id) return coded(`${domain} already belongs to another site`, "domain_taken", 409, { domain });
          await runlight.store.addLinkDomain(domain, site.id, runlight.now());
          runlight.forgetLinkDomains();
          return json({ domain }, 201);
        }
      }
      const checkMatch = /^\/api\/link-domains\/([^/]+)\/check$/.exec(path);
      if (checkMatch && request.method === "GET") {
        const domain = decodeURIComponent(checkMatch[1]!);
        if (!(await runlight.store.linkDomains()).some((d) => d.domain === domain && d.site === site.id)) return coded("Unknown domain", "unknown_domain", 404);
        // One added before names inside private networks were refused is never fetched.
        // What the check found, as a code the dashboard says in its own words, beside the English reason.
        // Where the domain should point, for the setup steps: this server's name, and its public addresses
        // for a bare domain, which takes an A record. A server reached by its address has no name to give.
        const own = origin ? new URL(origin).hostname : url.hostname;
        const target = { host: own, addresses: await publicAddresses(own) };
        const result = (code: string, reason: string, params?: Record<string, string>) =>
          json({ domain, working: code === "", reason, target, ...(code ? { code, ...(params ? { params } : {}) } : {}) });
        if (!DOMAIN_NAME.test(domain) || privateName(domain)) return result("check_not_public", "is not a public domain name");
        try {
          // Only a public address is fetched, whatever the name resolves to now, so the check cannot be pointed
          // into a private network.
          const answer = await publicFetch(`https://${domain}${LINK_DOMAIN_CHECK}`, { timeoutMs: 5000 });
          const body = (await answer.json().catch(() => null)) as { runlight?: boolean; domain?: string } | null;
          if (answer.ok && body?.runlight === true && body.domain === domain) return result("", "");
          return answer.ok ? result("check_not_runlight", "answered, but not from Runlight") : result("check_status", `answered ${answer.status}`, { status: String(answer.status) });
        } catch (error) {
          // A refused private address answers as a closed port does, so the check tells nothing about a private network.
          return error instanceof Error && error.name === "TimeoutError" ? result("check_timeout", "timed out") : result("check_https", "could not connect over HTTPS");
        }
      }

      const domainMatch = /^\/api\/link-domains\/([^/]+)$/.exec(path);
      if (domainMatch && request.method === "DELETE") {
        const domain = decodeURIComponent(domainMatch[1]!);
        if (!(await runlight.store.linkDomains()).some((d) => d.domain === domain && d.site === site.id)) return coded("Unknown domain", "unknown_domain", 404);
        await runlight.store.removeLinkDomain(domain);
        runlight.forgetLinkDomains();
        return json({ ok: true });
      }

      if (path === "/api/links") {
        if (request.method === "GET") {
          const read = await readQuery(url, site);
          if (read instanceof Response) return read;
          const links = await runlight.store.links(site.id, read.range.from, read.range.to);
          // Links on a removed domain are served from the app's own path until it is added back.
          const domains = (await runlight.store.linkDomains()).filter((d) => d.site === site.id).map((d) => d.domain);
          return json({ prefix: `${url.origin}${runlight.linkPath}`, domains, links });
        }
        if (request.method === "POST") {
          const body = await readJson(request);
          if (body instanceof Response) return body;
          const link = await runlight.links.create(site.id, {
            url: String(body.url ?? ""),
            name: body.name === undefined ? undefined : String(body.name),
            slug: body.slug === undefined ? undefined : String(body.slug),
            domain: body.domain === undefined ? undefined : String(body.domain),
          });
          return json({ link }, 201);
        }
      }

      // One step of an import from another shortener; the page calls again with the cursor.
      const importMatch = /^\/api\/links\/import\/([a-z]+)$/.exec(path);
      if (importMatch && request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        const credentials = (body.credentials && typeof body.credentials === "object" ? body.credentials : {}) as Record<string, string>;
        try {
          const step = await importStep(
            runlight,
            site.id,
            importMatch[1]!,
            Object.fromEntries(Object.entries(credentials).map(([k, v]) => [k, String(v)])),
            typeof body.cursor === "string" ? body.cursor : null,
            Number(body.done) || 0,
          );
          return json(step);
        } catch (error) {
          if (error instanceof ImportError) return refused(error, "import_failed");
          throw error;
        }
      }

      if (path === "/api/links/import" && request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        // Rows that are not objects (null, a number) are dropped rather than failing the import.
        const rows = Array.isArray(body.rows) ? (body.rows as unknown[]).filter((row): row is Record<string, unknown> => Boolean(row) && typeof row === "object" && !Array.isArray(row)).slice(0, 5000) : null;
        if (!rows) return coded("Send rows as a list", "rows_needed", 400);
        return json(await runlight.links.import(site.id, rows));
      }

      const linkMatch = /^\/api\/links\/([a-f0-9]+)$/.exec(path);
      if (linkMatch) {
        const id = linkMatch[1]!;
        if (request.method === "GET") {
          const link = await runlight.store.linkById(id);
          if (!link || link.site !== site.id) return coded("Unknown link", "unknown_link", 404);
          const read = await readQuery(url, site);
          if (read instanceof Response) return read;
          const { range } = read;
          const by = async (dimension: string) =>
            isSessionDimension(dimension) ? runlight.store.linkBreakdown(site.id, id, range.from, range.to, dimension, 10) : [];
          const [series, sources, referrers, countries, devices, browsers] = await Promise.all([
            runlight.store.linkSeries(site.id, id, buckets(range, site.timezone)),
            by("source"),
            by("referrer"),
            by("country"),
            by("device"),
            by("browser"),
          ]);
          const clicks = series.reduce((sum, p) => sum + p.clicks, 0);
          return json({
            link,
            range: { from: range.fromDate, to: range.toDate, interval: range.interval, timezone: site.timezone },
            clicks,
            series,
            sources,
            referrers,
            countries,
            devices,
            browsers,
          });
        }
        const owned = await runlight.store.linkById(id);
        if (!owned || owned.site !== site.id) return coded("Unknown link", "unknown_link", 404);
        if (request.method === "PATCH") {
          const body = await readJson(request);
          if (body instanceof Response) return body;
          const pick = (key: string) => (body[key] === undefined ? undefined : String(body[key]));
          return json({ link: await runlight.links.update(id, { url: pick("url"), name: pick("name"), slug: pick("slug"), domain: pick("domain") }) });
        }
        if (request.method === "DELETE") {
          await runlight.links.remove(id);
          return json({ ok: true });
        }
      }
    } catch (error) {
      if (error instanceof LinkError) return coded(error.message, error.code, 400, error.params);
      if (error instanceof RangeError) return coded(error.message, "unknown_link", 404);
      throw error;
    }
    return coded("Not found", "not_found", 404);
  }

  // The tracker with click rules inside, rebuilt when goals change. With ?site= it
  // carries only that site's rules, so one site's visitors never see another
  // site's domains or goals. The standalone server's snippet always names the
  // site; without a name it serves no rules, and an app's own install, whose
  // sites all belong to one owner, serves every site's.
  const trackers = new Map<string, { body: string; etag: string; at: number }>();
  /** The key picker tickets are signed with, made on first use and kept in the database for every process. */
  async function pickKey(): Promise<string> {
    await runlight.init();
    const saved = await runlight.store.setting("pick-key");
    if (saved) return saved;
    const made = randomId(32);
    await runlight.store.setSetting("pick-key", made);
    return made;
  }

  const hex = (text: string) => Array.from(new TextEncoder().encode(text), (b) => b.toString(16).padStart(2, "0")).join("");
  const unhex = (text: string) => new TextDecoder().decode(new Uint8Array(text.match(/../g)!.map((h) => parseInt(h, 16))));

  /** A ticket that lets the picker, on `site`'s pages, send its choice to `origin`, the dashboard that asked, for half an hour. */
  async function pickTicket(origin: string, site: string): Promise<string> {
    const payload = `${runlight.now() + PICK_TICKET_MS}.${hex(site)}.${hex(origin)}`;
    return `${payload}.${await hmac(await pickKey(), payload)}`;
  }

  /** The dashboard origin and site a picker ticket names, or null when it is not one this install signed or has run out. */
  async function pickTarget(ticket: string): Promise<{ origin: string; site: string } | null> {
    const parts = /^(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})$/.exec(ticket);
    if (!parts || Number(parts[1]) < runlight.now()) return null;
    if (!constantTimeEqual(parts[4]!, await hmac(await pickKey(), `${parts[1]}.${parts[2]}.${parts[3]}`))) return null;
    const origin = unhex(parts[3]!);
    return ORIGIN.test(origin) ? { origin, site: unhex(parts[2]!) } : null;
  }

  /** The key embed tickets and sessions are signed with, made on first use and kept in the database for every process. */
  async function embedKey(): Promise<string> {
    await runlight.init();
    const saved = await runlight.store.setting("embed-key");
    if (saved) return saved;
    const made = randomId(32);
    await runlight.store.setSetting("embed-key", made);
    return made;
  }

  /** An embed token that still exists, for a site that still does. */
  async function embedToken(id: string): Promise<TokenRow | null> {
    const token = (await runlight.store.tokens()).find((t) => t.id === id) ?? null;
    return token && token.scope === "embed" && runlight.site(token.site) ? token : null;
  }

  /**
   * A ticket for one load of the embedded dashboard, signed with when it runs out, a nonce, and the admin origin
   * that may frame it. The nonce is kept, with the token it was made for, until the ticket is used.
   */
  async function embedTicket(origin: string, token: string): Promise<{ ticket: string; expiresAt: number }> {
    const now = runlight.now();
    // Tickets nobody used are cleared as new ones are made.
    for (const { key, value } of await runlight.store.settingsStartingWith("embed-ticket:")) if (Number(value.split(".")[0]) < now) await runlight.store.setSetting(key, null);
    const expiresAt = now + EMBED_TICKET_MS;
    const nonce = randomId(16);
    await runlight.store.setSetting(`embed-ticket:${nonce}`, `${expiresAt}.${token}`);
    const payload = `${expiresAt}.${nonce}.${hex(origin)}`;
    return { ticket: `${payload}.${await hmac(await embedKey(), `ticket.${payload}`)}`, expiresAt };
  }

  /**
   * What a ticket this install signed names: always its origin, and its token only the first time it is used
   * before it runs out. Null for anything else.
   */
  async function redeemEmbed(ticket: string): Promise<{ origin: string; token: TokenRow | null } | null> {
    const parts = /^(\d{1,15})\.([a-f0-9]{32})\.([a-f0-9]{2,512})\.([a-f0-9]{64})$/.exec(ticket);
    if (!parts) return null;
    if (!constantTimeEqual(parts[4]!, await hmac(await embedKey(), `ticket.${parts[1]}.${parts[2]}.${parts[3]}`))) return null;
    const origin = unhex(parts[3]!);
    if (!ORIGIN.test(origin)) return null;
    // A ticket works once: it is gone before anything else is checked.
    const kept = await runlight.store.takeSetting(`embed-ticket:${parts[2]}`);
    const token = kept && Number(parts[1]) >= runlight.now() ? await embedToken(kept.split(".")[1] ?? "") : null;
    return { origin, token };
  }

  /** A session for an embedded dashboard, which its page sends with every read, signed with when it runs out and its token. */
  async function embedSession(token: string): Promise<string> {
    const payload = `${runlight.now() + EMBED_SESSION_MS}.${token}`;
    return `${payload}.${await hmac(await embedKey(), `session.${payload}`)}`;
  }

  /** The embed token a session this install signed was made for, while it lasts and the token still exists. */
  async function embedReader(session: string): Promise<TokenRow | null> {
    const parts = /^(\d{1,15})\.([a-f0-9]{24})\.([a-f0-9]{64})$/.exec(session);
    if (!parts || Number(parts[1]) < runlight.now()) return null;
    if (!constantTimeEqual(parts[3]!, await hmac(await embedKey(), `session.${parts[1]}.${parts[2]}`))) return null;
    return embedToken(parts[2]!);
  }

  async function trackerScript(siteId: string | null): Promise<{ body: string; etag: string }> {
    const key = siteId ?? "";
    const cached = trackers.get(key);
    if (cached && runlight.now() - cached.at < 60_000) return cached;
    await runlight.init();
    const sites = siteId !== null ? runlight.sites.filter((s) => s.id === siteId) : runlight.managedSites ? [] : runlight.sites;
    const rules = JSON.stringify(clickRules(sites, await runlight.store.goals()));
    // A function, not a string: "$'" or "$&" in a selector must not be read as a replacement pattern.
    const body = TRACKER.replace(RULES_PLACEHOLDER, () => rules);
    const script = { body, etag: `"${TRACKER_HASH}-${(await sha256(rules)).slice(0, 8)}"`, at: runlight.now() };
    // One entry per site at most; a query naming no real site gets the empty script without filling the map.
    if (siteId === null || sites.length) trackers.set(key, script);
    return script;
  }

  async function goalWrites(request: Request, path: string, url: URL): Promise<Response> {
    await runlight.init();
    const site = await querySite(url);
    if (site instanceof Response) return site;
    const existing = await runlight.store.goals(site.id);
    const id = path === "/api/goals" ? undefined : decodeURIComponent(path.slice("/api/goals/".length));
    if (id !== undefined && !existing.some((g) => g.id === id)) return coded("Unknown goal", "unknown_goal", 404);
    trackers.clear();
    if (request.method === "DELETE") {
      await runlight.store.deleteGoal(id!);
      return json({ ok: true });
    }
    const body = await readJson(request);
    if (body instanceof Response) return body;
    try {
      const goal = goalFrom(body, site.id, existing, runlight.now(), id);
      await runlight.store.saveGoal(goal, existing.find((g) => g.id === id));
      return json({ goal }, id ? 200 : 201);
    } catch (error) {
      if (error instanceof GoalError) return refused(error, "goal_invalid");
      throw error;
    }
  }

  const reportView = (r: ReportRow) => ({ id: r.id, site: r.site, email: r.email, frequency: r.frequency, lang: r.lang, lastSentAt: r.lastSentAt, createdAt: r.createdAt });

  async function mailApi(request: Request, path: string, url: URL): Promise<Response> {
    await runlight.init();
    try {
      if (path === "/api/mail") {
        if (request.method === "GET") {
          const settings = await runlight.mailSettings();
          const service = SERVICES.find((x) => x.id === settings?.service);
          // Secret fields come back only as "saved", never as their value.
          const fields: Record<string, string> = {};
          const saved: string[] = [];
          for (const f of service?.fields ?? []) {
            if (f.secret) {
              if (settings?.[f.name]) saved.push(f.name);
            } else fields[f.name] = String(settings?.[f.name] ?? "");
          }
          // A hub with a manage token learns which service sends the reports and from where, nothing more.
          const viaManage = managed.has(request);
          return json({
            source: settings?.source ?? null,
            service: settings?.service ?? "",
            from: settings?.from ?? "",
            fromName: settings?.fromName ?? "",
            fields: viaManage ? {} : fields,
            saved: viaManage ? [] : saved,
            encrypted: runlight.secret !== null,
            services: SERVICES,
          });
        }
        if (request.method === "PUT") {
          const body = await readJson(request);
          if (body instanceof Response) return body;
          await runlight.saveMailSettings(body);
          return json({ ok: true });
        }
        if (request.method === "DELETE") {
          await runlight.saveMailSettings(null);
          return json({ ok: true });
        }
        return coded("Method not allowed", "method_not_allowed", 405);
      }

      if (path === "/api/mail/test" && request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        const to = String(body.to ?? "").trim();
        if (!EMAIL.test(to)) return coded("Enter an email address to send the test to", "test_email", 400);
        const settings = await runlight.mailSettings();
        if (!settings) return coded("Set up a mail service first", "mail_unset", 400);
        const { t } = translator(String(body.lang ?? "en"));
        const name = SERVICES.find((x) => x.id === settings.service)?.name ?? "";
        await runlight.sendMail({ to, subject: t("email.test.subject"), text: t("email.test.body", { service: name }), html: `<p style="font-family:sans-serif;font-size:15px">${escapeHtml(t("email.test.body", { service: name }))}</p>` });
        return json({ ok: true });
      }

      const site = await querySite(url);
      if (site instanceof Response) return site;

      if (path === "/api/reports") {
        if (request.method === "GET") return json({ reports: (await runlight.store.reports(site.id)).map(reportView), languages: languages() });
        if (request.method === "POST") {
          const body = await readJson(request);
          if (body instanceof Response) return body;
          const email = String(body.email ?? "").trim().toLowerCase();
          if (!EMAIL.test(email)) return coded("Enter an email address", "email_invalid", 400);
          const frequency = body.frequency === "monthly" ? "monthly" : "weekly";
          const existing = await runlight.store.reports(site.id);
          if (existing.some((r) => r.email === email && r.frequency === frequency)) return coded(`${email} already gets the ${frequency} report`, "report_exists", 400, { email });
          if (existing.length >= 50) return coded("A site can send to at most 50 addresses", "report_limit", 400);
          // Links in the email point back to the configured address, or else to this dashboard as the
          // browser sees it. A report made from a hub needs the configured address, where its unsubscribe
          // link answers, since the Host its request names is the hub's to choose.
          if (managed.has(request) && !origin) return originNeeded();
          const given = origin ? "" : String(body.origin ?? "");
          const home = /^https?:\/\/[^\s]+$/.test(given) ? given.replace(/\/+$/, "") : `${origin ?? url.origin}${base}`;
          // A period already due counts as sent, so a report added mid-week first goes out on the next Monday, as the form says.
          const due = lastPeriod(frequency, runlight.now(), site.timezone);
          const report: ReportRow = {
            id: randomId(),
            site: site.id,
            email,
            frequency,
            lang: languages().includes(String(body.lang)) ? String(body.lang) : "en",
            token: randomId(16),
            origin: home,
            lastPeriod: runlight.now() >= due.dueAt ? due.key : "",
            lastSentAt: null,
            createdAt: runlight.now(),
          };
          await runlight.store.insertReport(report);
          return json({ report: reportView(report) }, 201);
        }
        return coded("Method not allowed", "method_not_allowed", 405);
      }

      const match = /^\/api\/reports\/([a-f0-9]{24})(\/send)?$/.exec(path);
      const report = match ? await runlight.store.reportBy("id", match[1]!) : null;
      if (!report || report.site !== site.id) return coded("Unknown report", "unknown_report", 404);
      if (match![2] && request.method === "POST") {
        // A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub
        // sends one every ten minutes for the whole site, so adding reports again does not start a new count.
        const key = managed.has(request) ? `site:${site.id}` : report.id;
        const wait = managed.has(request) ? 600_000 : 60_000;
        const last = sampleSent.get(key) ?? 0;
        if (runlight.now() - last < wait) {
          return managed.has(request)
            ? coded("A connected hub can send one sample every ten minutes. Wait a few minutes and try again.", "sample_soon_hub", 429)
            : coded("A sample went out a moment ago. Wait a minute and try again.", "sample_soon", 429);
        }
        sampleSent.set(key, runlight.now());
        await runlight.deliverReport(report, site);
        return json({ ok: true });
      }
      if (!match![2] && request.method === "DELETE") {
        await runlight.store.deleteReport(report.id);
        return json({ ok: true });
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    } catch (error) {
      if (error instanceof MailError) return coded(error.message, error.code, 400, error.params);
      throw error;
    }
  }

  /** A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing. */
  async function unsubscribePage(request: Request, token: string): Promise<Response> {
    await runlight.init();
    const report = /^[a-f0-9]{32}$/.test(token) ? await runlight.store.reportBy("token", token) : null;
    const site = report ? runlight.site(report.site) : null;
    const { t, lang } = translator(report?.lang ?? "en");
    const page = (body: string, status = 200) => smallPage(lang, body, status);
    if (!report || !site) return page(`<h1>${escapeHtml(t("email.unsub.goneTitle"))}</h1><p>${escapeHtml(t("email.unsub.gone"))}</p>`, 404);
    if (request.method === "POST") {
      await runlight.store.deleteReport(report.id);
      return page(`<h1>${escapeHtml(t("email.unsub.doneTitle"))}</h1><p>${escapeHtml(t("email.unsub.done", { site: site.name, email: report.email }))}</p>`);
    }
    return page(
      `<h1>${escapeHtml(t("email.unsub.title", { site: site.name }))}</h1><p>${escapeHtml(t("email.unsub.body", { email: report.email }))}</p><form method="post"><button type="submit">${escapeHtml(t("email.unsubscribe"))}</button></form>`,
    );
  }

  async function sharesApi(request: Request, path: string, url: URL): Promise<Response> {
    await runlight.init();
    const site = await querySite(url);
    if (site instanceof Response) return site;
    const view = (share: ShareRow) => ({ ...share, path: `${base}/share/${share.id}` });

    if (path === "/api/shares") {
      if (request.method === "GET") return json({ shares: (await runlight.store.shares(site.id)).map(view) });
      if (request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        const share: ShareRow = { id: randomId(16), site: site.id, name: String(body.name ?? "").trim().slice(0, 100), createdAt: runlight.now() };
        await runlight.store.insertShare(share);
        return json({ share: view(share) }, 201);
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    }

    const id = decodeURIComponent(path.slice("/api/shares/".length));
    const share = SHARE_ID.test(id) ? await runlight.store.shareById(id) : null;
    if (!share || share.site !== site.id) return coded("Unknown share", "unknown_share", 404);
    if (request.method === "PATCH") {
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const name = String(body.name ?? "").trim().slice(0, 100);
      await runlight.store.renameShare(share.id, name);
      return json({ share: view({ ...share, name }) });
    }
    if (request.method === "DELETE") {
      await runlight.store.deleteShare(share.id);
      return json({ ok: true });
    }
    return coded("Method not allowed", "method_not_allowed", 405);
  }

  /** How many questions each viewer may ask the assistant a day, as an owner set it. */
  async function viewerDaily(): Promise<number> {
    const saved = await runlight.store.setting("assistant-viewer-daily");
    return saved === null ? VIEWER_DAILY : Number(saved);
  }

  /**
   * Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past thirty an
   * hour or two at once for anyone, and past the owner's daily number for a viewer. Returns how to finish.
   */
  async function askTurn(who: string, owner: boolean): Promise<Response | (() => void)> {
    const now = runlight.now();
    const mine = asked.get(who) ?? { at: [], open: 0 };
    mine.at = mine.at.filter((at) => now - at < 3_600_000);
    if (mine.at.length >= ASK_PER_HOUR || mine.open >= ASK_AT_ONCE) return coded("You have asked a lot in a short time. Wait a little and ask again.", "assistant_soon", 429);
    if (!owner) {
      const limit = await viewerDaily();
      const day = `assistant-asked:${new Date(now).toISOString().slice(0, 10)}`;
      const counts = JSON.parse((await runlight.store.setting(day)) ?? "{}") as Record<string, number>;
      if ((counts[who] ?? 0) >= limit) return coded(`Viewers can ask ${limit} questions a day. Ask again tomorrow.`, "assistant_daily", 429, { limit: String(limit) });
      counts[who] = (counts[who] ?? 0) + 1;
      await runlight.store.setSetting(day, JSON.stringify(counts));
      for (const { key } of await runlight.store.settingsStartingWith("assistant-asked:")) if (key !== day) await runlight.store.setSetting(key, null);
    }
    mine.at.push(now);
    mine.open++;
    asked.set(who, mine);
    // People who stopped asking are dropped, so the map holds only the last hour's.
    if (asked.size > 1000) for (const [key, value] of asked) if (!value.open && !value.at.some((at) => now - at < 3_600_000)) asked.delete(key);
    return () => {
      mine.open--;
    };
  }

  async function tokensApi(request: Request, path: string): Promise<Response> {
    await runlight.init();
    const view = (t: TokenRow) => ({ id: t.id, name: t.name, site: t.site, scope: t.scope, hint: t.hint, createdAt: t.createdAt, lastUsedAt: t.lastUsedAt });
    if (path === "/api/tokens" && request.method === "GET") return json({ tokens: (await runlight.store.tokens()).map(view) });
    if (path === "/api/tokens" && request.method === "POST") {
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const name = String(body.name ?? "").trim().slice(0, 100);
      if (!name) return coded("Name the token", "token_name", 400);
      const site = String(body.site ?? "");
      if (site && !runlight.sites.some((s) => s.id === site)) return coded("Unknown site", "unknown_site", 404);
      const scope = body.scope === "manage" ? "manage" : body.scope === "embed" ? "embed" : "read";
      if (scope === "manage" && !site) return coded("A token that changes settings is for one site. Pick the site.", "token_site", 400);
      if (scope === "embed" && !site) return coded("A key for the dashboard in a CMS is for one site. Pick the site.", "embed_site", 400);
      const secret = `${TOKEN_PREFIX}${randomId(20)}`;
      const row: TokenRow = { id: randomId(), name, site, scope, hash: await sha256(secret), hint: secret.slice(-4), createdAt: runlight.now(), lastUsedAt: null };
      await runlight.store.insertToken(row);
      const by = (await accountOf?.(request)) ?? null;
      if (by && tokenMade && !(await tokenMade(row, by))) {
        await runlight.store.deleteToken(row.id);
        return denied("read");
      }
      // The only time the token is ever shown.
      return json({ token: view(row), secret }, 201);
    }
    const match = /^\/api\/tokens\/([a-f0-9]{24})$/.exec(path);
    if (match && request.method === "DELETE") {
      return (await runlight.store.deleteToken(match[1]!)) ? json({ ok: true }) : coded("Unknown token", "unknown_token", 404);
    }
    return coded("Not found", "not_found", 404);
  }

  async function api(request: Request, path: string, url: URL): Promise<Response> {
    // An embedded dashboard reads what a share link shows and nothing else, whoever else the request comes from.
    if (request.headers.get(EMBED_HEADER) !== null && !(request.method === "GET" && sharedPath(path))) {
      return coded("Not available on a shared dashboard", "share_not_available", 403);
    }
    // A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
    // That holds without a cookie too, since a browser also sends Basic credentials or comes from an
    // allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
    if (!["GET", "HEAD", "OPTIONS", "DELETE"].includes(request.method) && !bearer(request) && !isJson(request)) {
      return coded("Send JSON", "send_json", 415);
    }
    if (path === "/api" && request.method === "GET") {
      return json({ name: "runlight", version: VERSION, api: API_VERSION, ...IMPLEMENTATION });
    }

    // A hub asks what its token may do before offering to change anything.
    if (path === "/api/token" && request.method === "GET") {
      const token = await apiToken(request);
      if (!token) return denied(false);
      return json({ scope: token.scope, site: token.site });
    }
    // A token can delete itself, which a hub does when it disconnects a site or gets a new token.
    if (path === "/api/token" && request.method === "DELETE") {
      const token = await apiToken(request);
      if (!token) return denied(false);
      await runlight.store.deleteToken(token.id);
      return json({ ok: true });
    }

    // Connecting another Runlight through its consent page, so nobody copies a token.
    if (path === "/api/sites/connect" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      if (!runlight.managedSites) return coded("Sites are set in code", "sites_in_code", 400);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      try {
        return json({ authorize: await startConnect(runlight, body.url, `${url.origin}${base}/api/sites/connect/done`, typeof body.site === "string" ? body.site : "") });
      } catch (error) {
        if (error instanceof ConnectError) return coded(error.message, error.code === "unreachable" ? "unreachable" : `connect_${error.code}`, 400, error.params);
        if (error instanceof RangeError) return refused(error, "connect_failed");
        throw error;
      }
    }
    if (path === "/api/sites/connect/done" && request.method === "GET") {
      const home = base || "/";
      const access = await canRead(request);
      if (access !== true) return new Response(null, { status: 303, headers: { location: home, "cache-control": "no-store" } });
      await runlight.init();
      let to: string;
      try {
        const id = await finishConnect(runlight, url.searchParams);
        // The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
        to = `${home}?site=${encodeURIComponent(id)}&settings=general&connected=1`;
      } catch (error) {
        if (!(error instanceof RangeError)) throw error;
        // A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
        to = `${home}?connect_error=${error instanceof ConnectError ? error.code : "failed"}`;
      }
      return new Response(null, { status: 303, headers: { location: to, "cache-control": "no-store" } });
    }

    // A ticket for one load of the dashboard inside a CMS's admin pages. The plugin's server asks with its embed
    // token on each page view and names the admin's origin, which must be one of the site's domains and alone
    // may frame the page the ticket opens.
    if (path === "/api/embed" && request.method === "POST") {
      const token = await apiToken(request);
      if (!token) return denied(false);
      if (token.scope !== "embed") return coded("Use a key for the dashboard in a CMS, made in Settings, Install", "embed_token", 403);
      const site = runlight.site(token.site);
      if (!site) return coded("Unknown site", "unknown_site", 404);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const origin = String(body.origin ?? "");
      const parsed = ORIGIN.test(origin) && origin.length <= 200 && URL.canParse(origin) ? new URL(origin) : null;
      if (!parsed || parsed.origin !== origin) return coded("Send the admin page's origin, such as https://example.com", "embed_origin", 400);
      const host = hostName(parsed.host);
      if (!(runlight.remote(site.id)?.hostnames ?? site.hostnames).map(hostName).includes(host)) {
        return coded(`${host} is not one of this site's domains. Add it to the site's domains in Runlight's settings.`, "embed_host", 400, { host });
      }
      const { ticket, expiresAt } = await embedTicket(origin, token.id);
      return json({ ticket, site: site.id, expiresAt, path: `${base}/embed?ticket=${ticket}` }, 201);
    }

    const token = bearer(request).startsWith(TOKEN_PREFIX) ? await apiToken(request) : null;
    // An embed token gets tickets and reads nothing itself.
    if (token?.scope === "embed") return coded("This key only opens the dashboard inside a CMS", "token_embed_only", 403);
    if (token?.scope === "manage" && managePath(request.method, path)) {
      const asked = url.searchParams.get("site");
      const siteMatch = /^\/api\/sites\/([^/]+)$/.exec(path);
      if ((asked && asked !== token.site) || (siteMatch && decodeURIComponent(siteMatch[1]!) !== token.site)) return coded("Unknown site", "unknown_site", 404);
      if (siteMatch && isJson(request)) {
        // Where a site lives stays with its owner: a hub may rename it, never move it.
        const body = (await request.clone().json().catch(() => null)) as Record<string, unknown> | null;
        if (body && body.hostnames !== undefined) return coded("A connected hub cannot change a site's domains", "hub_domains", 403);
      }
      url = new URL(url);
      url.searchParams.set("site", token.site);
      managed.set(request, token);
    }
    // A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
    if (token && !managed.has(request) && !["GET", "HEAD", "OPTIONS"].includes(request.method)) {
      return coded(token.scope === "manage" ? "A manage token changes only its own site's settings" : "API tokens can only read", token.scope === "manage" ? "token_manage_only" : "token_read_only", 403);
    }

    // A page another site served to an AI agent, reported by a CMS plugin.
    if (path === "/api/observe" && request.method === "POST") {
      const given = bearer(request);
      // The install-wide key and the owner's access can report for any site.
      const anySite = Boolean(observeKey && given && constantTimeEqual(given, observeKey)) || (await canRead(request)) === true;
      if (!anySite && !given) return coded("Unauthorized", "unauthorized", 401);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
      const list = Array.isArray(body.fetches) ? (body.fetches as Array<Record<string, unknown>>) : [body];
      if (list.length > 500) return coded("Send at most 500 fetches at a time", "observe_many", 413);
      const pages: Array<{ page: URL; userAgent: string; at?: number }> = [];
      for (const item of list) {
        let page: URL;
        try {
          page = new URL(String(item?.url ?? ""));
        } catch {
          return coded("Send the page's url", "observe_url", 400);
        }
        if (page.protocol !== "https:" && page.protocol !== "http:") return coded("Send the page's url", "observe_url", 400);
        const at = typeof item.at === "number" ? item.at : typeof item.at === "string" ? Date.parse(item.at) : undefined;
        pages.push({ page, userAgent: String(item.userAgent ?? "").slice(0, 500), ...(at !== undefined && Number.isFinite(at) ? { at } : {}) });
      }
      await runlight.init();
      let keep = pages;
      if (!anySite) {
        // A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
        // host in the same log, say) are skipped, not a reason to refuse the rest.
        let keySite: string | null = null;
        for (const site of runlight.sites) {
          const key = await runlight.store.setting(`observe-key:${site.id}`);
          if (key && constantTimeEqual(given, key)) keySite = site.id;
        }
        if (!keySite) return coded("Unauthorized", "unauthorized", 401);
        keep = pages.filter((p) => runlight.siteFor(p.page.hostname)?.id === keySite);
        // A single report for another site's page is a misconfigured plugin, which should hear about it.
        if (!Array.isArray(body.fetches) && keep.length === 0) return coded("Unauthorized", "unauthorized", 401);
      }
      let recorded = 0;
      for (const p of keep) if (await runlight.observe(new Request(p.page, { headers: { "user-agent": p.userAgent } }), p.at)) recorded++;
      // A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
      if (!Array.isArray(body.fetches)) return new Response(null, { status: 204 });
      return json({ recorded, skipped: pages.length - recorded });
    }

    // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
    if (path === "/api/check" && (request.method === "POST" || request.method === "GET")) {
      const given = bearer(request);
      const allowed =
        (cronSecret && given && constantTimeEqual(given, cronSecret)) || (await canRead(request)) === true;
      if (!allowed) return coded("Unauthorized", "unauthorized", 401);
      return json(await runlight.check());
    }

    // A site counted by another install is read there. Its settings change there too,
    // through this server when the install gave a manage token, and only by an owner here.
    const asked = url.searchParams.get("site");
    const connected = asked ? runlight.remote(asked) : null;
    if (connected && connected.scope === "manage" && managePath(request.method, path) && !(request.method === "GET" && sharedPath(path))) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      if (request.method !== "GET") runlight.forgetRemoteInfo(asked!);
      return passThrough(connected, path, url, request);
    }
    if (connected && !(request.method === "GET" && (sharedPath(path) || path === "/api/links"))) {
      return coded("This site is counted by its own Runlight. Connect it again from its settings to change it from here.", "site_remote", 400);
    }

    // Visit history from Umami: list the account's websites, then import one a step at a time.
    if ((path === "/api/import/umami/websites" || path === "/api/import/umami/visits") && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const credentials = Object.fromEntries(
        Object.entries((body.credentials && typeof body.credentials === "object" ? body.credentials : {}) as Record<string, unknown>).map(([k, v]) => [k, String(v)]),
      );
      try {
        if (path === "/api/import/umami/websites") return json({ websites: await umamiWebsites(credentials) });
        await runlight.init();
        const site = await querySite(url);
        if (site instanceof Response) return site;
        const step = await importUmamiVisits(runlight, site.id, credentials, String(body.website ?? ""), typeof body.cursor === "string" ? body.cursor : null);
        return json(step);
      } catch (error) {
        if (error instanceof ImportError) return refused(error, "import_failed");
        throw error;
      }
    }

    // Visit history from a CSV file, a batch at a time.
    if (path === "/api/import/csv/visits" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      await runlight.init();
      const site = await querySite(url);
      if (site instanceof Response) return site;
      try {
        return json(await importCsvVisits(runlight, site.id, body.rows));
      } catch (error) {
        if (error instanceof ImportError) return refused(error, "import_failed");
        throw error;
      }
    }

    // Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
    if ((path === "/api/observe-key" && request.method === "GET") || (path === "/api/observe-key/new" && request.method === "POST")) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      const site = await querySite(url);
      if (site instanceof Response) return site;
      const name = `observe-key:${site.id}`;
      let key = path.endsWith("/new") ? null : await runlight.store.setting(name);
      if (!key) {
        key = `rlo_${randomId(20)}`;
        await runlight.store.setSetting(name, key);
      }
      return json({ key });
    }

    // Making, changing, and deleting funnels; reading them is with the other reports.
    if ((path === "/api/funnels" && request.method === "POST") || (/^\/api\/funnels\/[a-f0-9]{24}$/.test(path) && (request.method === "PATCH" || request.method === "DELETE"))) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      const site = await querySite(url);
      if (site instanceof Response) return site;
      const existing = await runlight.store.funnels(site.id);
      const id = path === "/api/funnels" ? undefined : path.slice("/api/funnels/".length);
      if (id !== undefined && !existing.some((f) => f.id === id)) return coded("Unknown funnel", "unknown_funnel", 404);
      if (request.method === "DELETE") {
        await runlight.store.deleteFunnel(id!);
        return json({ ok: true });
      }
      const body = await readJson(request);
      if (body instanceof Response) return body;
      try {
        const funnel = funnelFrom(body, site.id, existing, runlight.now(), id);
        await runlight.store.saveFunnel(funnel);
        return json({ funnel }, id ? 200 : 201);
      } catch (error) {
        if (error instanceof FunnelError) return refused(error, "funnel_invalid");
        throw error;
      }
    }

    // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
    if (path === "/api/assistant") {
      const self = await canRead(request);
      // A member uses the assistant like anyone else, but its settings are for owners and admins.
      const owner = self === true && !members.has(request);
      if (request.method === "GET") {
        const access = await reader(request);
        if (access === false || access === "unconfigured") return denied(access);
        // Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
        if (access !== true && access.id) return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
        await runlight.init();
        const settings = await runlight.assistantSettings();
        if (!owner) return json({ configured: Boolean(settings) });
        return json({
          configured: Boolean(settings),
          viewerDaily: await viewerDaily(),
          provider: settings?.provider ?? "",
          model: settings?.model ?? "",
          baseUrl: settings?.baseUrl ?? "",
          keySaved: Boolean(settings?.key),
          encrypted: runlight.secret !== null,
          providers: PROVIDERS,
        });
      }
      if (!owner) return self === true ? coded("Only an owner or admin can change this", "admin_only", 403) : denied(self);
      await runlight.init();
      if (request.method === "DELETE") {
        await runlight.saveAssistantSettings(null);
        return json({ ok: true });
      }
      if (request.method === "PUT") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        try {
          await runlight.saveAssistantSettings(body);
          return json({ ok: true });
        } catch (error) {
          if (error instanceof RangeError) return refused(error, "assistant_invalid");
          throw error;
        }
      }
      return coded("Method not allowed", "method_not_allowed", 405);
    }
    // How many questions each viewer may ask a day; 0 keeps the assistant for owners.
    if (path === "/api/assistant/limits" && request.method === "PUT") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const daily = Number(body.viewerDaily);
      if (!Number.isInteger(daily) || daily < 0 || daily > 1000) return coded("Use a whole number from 0 to 1,000", "assistant_limit", 400);
      await runlight.store.setSetting("assistant-viewer-daily", String(daily));
      return json({ viewerDaily: daily });
    }
    // The models a service offers, for the setup form's dropdown. The key can be the one already saved.
    if (path === "/api/assistant/models" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const provider = String(body.provider ?? "");
      const saved = await runlight.assistantSettings();
      const baseUrl = String(body.baseUrl ?? "").trim().replace(/\/+$/, "");
      // The saved key only for the address it was saved with.
      const sameAddress = saved?.provider === provider && (saved.baseUrl || "") === baseUrl;
      const key = String(body.key ?? "").trim() || (sameAddress ? saved!.key : "");
      try {
        return json({ models: await listModels({ provider, baseUrl: String(body.baseUrl ?? "").trim(), key }) });
      } catch (error) {
        if (error instanceof AssistantError) return refused(error, "assistant_failed");
        throw error;
      }
    }
    if (path === "/api/assistant/chat" && request.method === "POST") {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      if (access !== true && access.id) return coded("Only the dashboard can use the assistant", "assistant_dashboard", 403);
      if (request.headers.get(SHARE_HEADER) !== null) return coded("Not available on a shared dashboard", "share_not_available", 403);
      await runlight.init();
      const settings = await runlight.assistantSettings();
      if (!settings) return coded("The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.", "assistant_unset", 400);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const site = runlight.site(String(body.site ?? "") || null);
      if (!site) return coded("Unknown site", "unknown_site", 404);
      const messages = Array.isArray(body.messages)
        ? (body.messages as Array<Record<string, unknown> | null>).filter((m): m is Record<string, unknown> => Boolean(m) && (m!.role === "user" || m!.role === "assistant") && typeof m!.content === "string").map((m) => ({ role: m.role as "user" | "assistant", content: String(m.content) }))
        : [];
      if (!messages.length || messages[messages.length - 1]!.role !== "user") return coded("Ask a question", "question_needed", 400);
      const owner = access === true;
      const turn = await askTurn((await accountOf?.(request)) ?? (owner ? "owner" : "viewer"), owner);
      if (turn instanceof Response) return turn;
      // Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
      const headers = new Headers(request.headers);
      for (const name of ["content-type", "content-length", SHARE_HEADER, EMBED_HEADER]) headers.delete(name);
      const readApi = (apiPath: string, params: [string, string][]) => {
        const target = new URL(`${base}${apiPath}`, url.origin);
        for (const [key, value] of params) target.searchParams.append(key, value);
        // A tool that names no site reads the one on screen, not the install's first.
        if (apiPath !== "/api/sites" && !target.searchParams.has("site")) target.searchParams.set("site", site.id);
        // The asker leaving stops the tool's reading too.
        return api(new Request(target, { headers, signal: request.signal }), apiPath, target);
      };
      try {
        const answer = await chat(
          settings,
          messages,
          {
            site: { id: site.id, name: site.name, timezone: site.timezone },
            today: localDate(runlight.now(), site.timezone),
            view: String(body.view ?? "the last 30 days").slice(0, 200),
            language: /^[a-z]{2}$/.test(String(body.language)) ? String(body.language) : "en",
          },
          readApi,
          request.signal,
        );
        return json(answer);
      } catch (error) {
        if (error instanceof AssistantError) return refused(error, "assistant_failed", 502);
        throw error;
      } finally {
        turn();
      }
    }

    // Only the owner manages tokens: an API token cannot make or revoke one.
    if (path === "/api/tokens" || path.startsWith("/api/tokens/")) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      return tokensApi(request, path);
    }

    if (connected && path === "/api/links") {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      // A token limited to one site reads only that site's links, here as everywhere else.
      if (access !== true && access.site && access.site !== asked) return coded("Unknown site", "unknown_site", 404);
      return passThrough(connected, path, url);
    }

    // An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
    if (request.method === "GET" && (path === "/api/links" || /^\/api\/links\/[a-f0-9]+$/.test(path))) {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      if (access !== true) {
        await runlight.init();
        const site = runlight.site(url.searchParams.get("site") ?? (access.site || null));
        if (!site || (access.site && site.id !== access.site)) return coded("Unknown site", "unknown_site", 404);
        const scoped = new URL(url);
        scoped.searchParams.set("site", site.id);
        return linksApi(request, path, scoped);
      }
    }

    if (path === "/api/links" || path.startsWith("/api/links/") || path === "/api/link-domains" || path.startsWith("/api/link-domains/")) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      return linksApi(request, path, url);
    }

    if (path === "/api/mail" || path === "/api/mail/test" || path === "/api/reports" || path.startsWith("/api/reports/")) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      return mailApi(request, path, url);
    }

    // A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
    // that serves the site's script, with its own origin, since that install signs what the script will trust.
    if (path === "/api/pick" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      const site = await querySite(url);
      if (site instanceof Response) return site;
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const origin = String(body.origin ?? "");
      if (!ORIGIN.test(origin)) return coded("Send the dashboard's origin, such as https://stats.example.com", "pick_origin", 400);
      // A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
      const hub = managed.get(request);
      if (hub && (await runlight.store.setting(`token-origin:${hub.id}`)) !== origin) {
        return coded("This hub's address is not the one it connected from. Connect the site again from here.", "pick_hub", 403);
      }
      return json({ ticket: await pickTicket(origin, site.id) });
    }

    if ((path === "/api/goals" && request.method === "POST") || (/^\/api\/goals\/[^/]+$/.test(path) && (request.method === "PATCH" || request.method === "DELETE"))) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      return goalWrites(request, path, url);
    }

    if (path === "/api/shares" || path.startsWith("/api/shares/")) {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      return sharesApi(request, path, url);
    }

    // Adding and deleting sites, when they are managed in the dashboard.
    if (path === "/api/sites" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      try {
        return json({ site: await runlight.addSite(body) }, 201);
      } catch (error) {
        if (error instanceof RangeError) return refused(error, "site_invalid");
        throw error;
      }
    }

    const siteMatch = /^\/api\/sites\/([^/]+)$/.exec(path);
    if (siteMatch && request.method === "DELETE") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      try {
        await runlight.deleteSite(decodeURIComponent(siteMatch[1]!));
        return json({ ok: true });
      } catch (error) {
        if (error instanceof RangeError) return error.message === "Unknown site" ? coded(error.message, "unknown_site", 404) : refused(error, "site_invalid");
        throw error;
      }
    }
    if (siteMatch && request.method === "PATCH") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      // A form posted from another site cannot carry this content type without CORS.
      const body = await readJson(request);
      if (body instanceof Response) return body;
      await runlight.init();
      // Every field is checked before any changes, since a shorter retention deletes visits at once.
      if (body.name !== undefined && !(String(body.name).trim() && String(body.name).trim().length <= 80)) return coded("A site name is 1 to 80 characters", "site_name", 400);
      if (body.timezone !== undefined && !isTimezone(String(body.timezone))) return coded(`Unknown timezone "${body.timezone}"`, "unknown_timezone", 400, { timezone: String(body.timezone) });
      if (body.retentionMonths !== undefined && body.retentionMonths !== null && !RETENTION_MONTHS.includes(Number(body.retentionMonths))) {
        return coded(`Keep visits for ${RETENTION_MONTHS.join(", ")} months, or forever`, "retention_bad", 400, { months: RETENTION_MONTHS.join(", ") });
      }
      try {
        const id = decodeURIComponent(siteMatch[1]!);
        const remote = runlight.remote(id);
        // How long a connected site keeps visits, and the timezone its days follow, are the install's
        // settings: this server passes them on, and changes its own row only once the install took them.
        const forward = {
          ...(body.retentionMonths !== undefined ? { retentionMonths: body.retentionMonths } : {}),
          ...(body.timezone !== undefined && String(body.timezone) !== runlight.site(id)?.timezone ? { timezone: String(body.timezone) } : {}),
        };
        if (remote && Object.keys(forward).length) {
          if (remote.scope !== "manage") return coded("Connect this site again to change it from here", "connect_again", 400);
          const answer = await passThrough(
            remote,
            `/api/sites/${encodeURIComponent(remote.site)}`,
            new URL(url),
            new Request(request.url, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify(forward) }),
          );
          if (!answer.ok) return answer;
          runlight.forgetRemoteInfo(id);
        } else if (!remote && body.retentionMonths !== undefined) {
          await runlight.setRetention(id, body.retentionMonths === null ? null : Number(body.retentionMonths));
        }
        const site = await runlight.updateSite(decodeURIComponent(siteMatch[1]!), {
          ...(body.name !== undefined ? { name: String(body.name) } : {}),
          ...(body.timezone !== undefined ? { timezone: String(body.timezone) } : {}),
          ...(body.hostnames !== undefined && runlight.managedSites ? { hostnames: body.hostnames } : {}),
        });
        // A connected site answers as the list shows it, so the dashboard keeps its install and domains.
        return json({ site: remote ? { ...site, remote: remote.url, remoteSite: remote.site, manage: remote.scope === "manage", hostnames: remote.hostnames } : site });
      } catch (error) {
        if (error instanceof RangeError) return error.message === "Unknown site" ? coded(error.message, "unknown_site", 404) : refused(error, "site_invalid");
        throw error;
      }
    }

    if (request.method !== "GET") return coded("Method not allowed", "method_not_allowed", 405);

    await runlight.init();
    // A shared dashboard sees exactly what its visitors see, even for someone signed in.
    const shareId = request.headers.get(SHARE_HEADER);
    let shared: ShareRow | null = null;
    // The one site a share or a site's API token may read; null for every site.
    let only: string | null = null;
    if (shareId !== null) {
      shared = SHARE_ID.test(shareId) ? await runlight.store.shareById(shareId) : null;
      if (!shared) return coded("This share link no longer works", "share_gone", 404);
      if (!sharedPath(path)) return coded("Not available on a shared dashboard", "share_not_available", 403);
      only = shared.site;
    } else if (request.headers.get(EMBED_HEADER) !== null) {
      const token = await embedReader(request.headers.get(EMBED_HEADER)!);
      if (!token) return coded("This dashboard has expired. Reload the page to open it again.", "embed_expired", 401);
      // An embedded dashboard sees what a share link of its token's site shows.
      shared = { id: "", site: token.site, name: "", createdAt: 0 };
      only = token.site;
    } else {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      if (access !== true) {
        if (!sharedPath(path)) return coded("API tokens can only read", "token_read_only", 403);
        only = access.site || null;
      }
    }

    if (path === "/api/sites") {
      const visible = only ? runlight.sites.filter((s) => s.id === only) : runlight.sites;
      const sites = await Promise.all(
        visible.map(async (site) => ({
          ...site,
          // A connected install's address, so the dashboard can say where the site is counted.
          // Its domains as the install reported them, for the goal picker; tracker hits never match them here.
          ...(runlight.remote(site.id) && !shared
            ? { remote: runlight.remote(site.id)!.url, remoteSite: runlight.remote(site.id)!.site, manage: runlight.remote(site.id)!.scope === "manage", hostnames: runlight.remote(site.id)!.hostnames }
            : {}),
          // Hostnames say where the site lives; a share shows only its name.
          ...(shared ? { hostnames: [] } : {}),
          lastSeen: runlight.remote(site.id) ? await runlight.remoteLastSeen(site.id) : await runlight.store.lastSeen(site.id),
          // Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
          ...(shared ? {} : { retentionMonths: runlight.remote(site.id) ? (await runlight.remoteInfo(site.id))?.retentionMonths : await runlight.retention(site.id) }),
          // Whether a connected install still takes this server's token, so the dashboard offers to connect it
          // again only when it no longer does.
          ...(runlight.remote(site.id) && !shared ? { connection: (await runlight.remoteInfo(site.id))?.connection } : {}),
        })),
      );
      // A share never learns how the install is run.
      return json(shared ? { sites } : { sites, managed: runlight.managedSites });
    }

    const site = shared ? runlight.site(shared.site) : only ? runlight.site(url.searchParams.get("site") ?? only) : await querySite(url);
    if (site instanceof Response) return site;
    if (!site || (only && site.id !== only)) return coded("Unknown site", "unknown_site", 404);
    const remote = runlight.remote(site.id);
    if (remote) return passThrough(remote, path, url, request);

    if (path === "/api/icon") {
      const host = site.hostnames[0];
      // Only a site's own domain, never the request's Host header, which a caller can write.
      const icon = host ? await fetchIcon(`https://${host}`) : null;
      if (!icon) return coded("No icon", "icon_none", 404, undefined, { "cache-control": "private, max-age=3600" });
      return new Response(icon.body, {
        headers: {
          "content-type": icon.type,
          "cache-control": "private, max-age=86400",
          // An SVG served from this origin must never run script.
          "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
          "x-content-type-options": "nosniff",
        },
      });
    }

    if (path === "/api/realtime") {
      return json(await runlight.store.realtime(site.id, runlight.now()));
    }

    const read = await readQuery(url, site);
    if (read instanceof Response) return read;
    const { query, range, compared } = read;
    const rangeOut = { from: range.fromDate, to: range.toDate, interval: range.interval, timezone: site.timezone };
    const compareOut = compared ? { from: compared.fromDate, to: compared.toDate } : undefined;

    if (path === "/api/stats") {
      const stats = await runlight.store.stats(query);
      const previous = compared ? await runlight.store.stats({ ...query, from: compared.from, to: compared.to }) : undefined;
      return json({ site: site.id, range: rangeOut, compare: compareOut, stats, previous });
    }

    if (path === "/api/goals") {
      const goals = await runlight.store.goals(site.id);
      const visitors = await runlight.store.visitors(query);
      const previousVisitors = compared ? await runlight.store.visitors({ ...query, from: compared.from, to: compared.to }) : 0;
      // Every goal in one pass for the range, and one more for the comparison.
      const nowAll = await runlight.store.goalTotalsAll(query, goals);
      const beforeAll = compared ? await runlight.store.goalTotalsAll({ ...query, from: compared.from, to: compared.to }, goals) : null;
      const rows = goals.map((goal) => {
        const now = nowAll.get(goal.id)!;
        const before = beforeAll?.get(goal.id);
        return {
          ...goal,
          ...now,
          rate: visitors ? now.visitors / visitors : 0,
          previous: before ? { ...before, rate: previousVisitors ? before.visitors / previousVisitors : 0 } : undefined,
        };
      });
      return json({ site: site.id, range: rangeOut, compare: compareOut, visitors, goals: rows });
    }

    const goalMatch = /^\/api\/goals\/([a-f0-9]{24})$/.exec(path);
    if (goalMatch) {
      const goal = await runlight.store.goalById(goalMatch[1]!);
      if (!goal || goal.site !== site.id) return coded("Unknown goal", "unknown_goal", 404);
      const visitors = await runlight.store.visitors(query);
      const totals = await runlight.store.goalTotals(query, goal);
      const [series, sources, channels, pages] = await Promise.all([
        runlight.store.goalSeries(query, goal, buckets(range, site.timezone)),
        runlight.store.goalBreakdown(query, goal, "source"),
        runlight.store.goalBreakdown(query, goal, "channel"),
        runlight.store.goalBreakdown(query, goal, "path"),
      ]);
      return json({ site: site.id, range: rangeOut, goal, totals: { ...totals, rate: visitors ? totals.visitors / visitors : 0 }, series, sources, channels, pages });
    }

    if (path === "/api/series") {
      const points = await runlight.store.series(query, buckets(range, site.timezone));
      // Comparison points line up with the main ones by position.
      const previous = compared ? (await runlight.store.series(query, buckets(compared, site.timezone))).slice(0, points.length) : undefined;
      return json({ site: site.id, range: rangeOut, compare: compareOut, points, previous });
    }

    if (path === "/api/rhythm") {
      // Visits per weekday and hour, plus each cell's details for its tooltip.
      // Visitors are summed over the hours folded into a cell, so someone who
      // came on two Tuesdays at 2pm counts twice there.
      const grid = Array.from({ length: 7 }, () => new Array<number>(24).fill(0));
      const cells = Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => ({ visits: 0, visitors: 0, pageviews: 0, bounced: 0 })));
      for (const row of await runlight.store.hourly(query)) {
        const [weekday, h] = localWeekdayHour(row.quarter * 900_000, site.timezone);
        grid[weekday]![h]! += row.visits;
        const cell = cells[weekday]![h]!;
        cell.visits += row.visits;
        cell.visitors += row.visitors;
        cell.pageviews += row.pageviews;
        cell.bounced += row.bounced;
      }
      const details = cells.map((day) =>
        day.map((c) => ({ visits: c.visits, visitors: c.visitors, pageviews: c.pageviews, bounceRate: c.visits ? c.bounced / c.visits : 0 })),
      );
      return json({ site: site.id, range: rangeOut, grid, cells: details });
    }

    if (path === "/api/journeys") {
      const q = url.searchParams;
      const through = /^(\d+):(.+)$/.exec(q.get("through") ?? "");
      // Journeys reads the newest visits up to a cap; say when it was reached.
      const { rows, sampled } = await runlight.store.journeyPages(query, PAGES_PER_VISIT);
      const answer = journeys(rows, {
        steps: Number(q.get("steps") ?? 5),
        ...(q.get("start") ? { start: q.get("start")! } : {}),
        ...(q.get("end") ? { end: q.get("end")! } : {}),
        ...(through ? { through: { step: Number(through[1]), value: through[2]! } } : {}),
      });
      return json({ site: site.id, range: rangeOut, ...answer, ...(sampled ? { sampled: JOURNEY_VISITS } : {}) });
    }

    if (path === "/api/funnels") {
      const funnels = await runlight.store.funnels(site.id);
      // One funnel at a time, so a page of funnels never takes every database connection at once.
      const rows = [];
      for (const funnel of funnels) {
        const counts = await runlight.store.funnelCounts(query, funnel);
        rows.push({ ...funnel, steps: funnel.steps.map((step, i) => ({ ...step, visits: counts[i]! })) });
      }
      return json({ site: site.id, range: rangeOut, funnels: rows });
    }

    if (path === "/api/event-props") {
      const event = url.searchParams.get("event") ?? "";
      if (!event) return coded("Name the event", "event_needed", 400);
      const keys = await runlight.store.eventPropKeys(query, event);
      const asked = url.searchParams.get("key");
      // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
      if (asked !== null && !/^[^"\\]{1,64}$/.test(asked)) return coded("Bad property name", "property_bad", 400);
      const key = asked ?? keys[0]?.key ?? null;
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get("limit")) || 100));
      const rows = key ? await runlight.store.eventPropValues(query, event, key, limit) : [];
      return json({ site: site.id, range: rangeOut, event, keys, key, rows });
    }

    if (path === "/api/breakdown") {
      const dimension = url.searchParams.get("dimension") ?? "";
      if (!isDimension(dimension)) return coded(`Unknown dimension "${dimension}"`, "unknown_dimension", 400, { dimension });
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get("limit")) || 10));
      const page = Math.max(1, Number(url.searchParams.get("page")) || 1);
      const rows = await runlight.store.breakdown(query, dimension, limit, (page - 1) * limit);
      if (url.searchParams.get("format") === "csv") return download(`${site.id}-${dimension}-${range.fromDate}-${range.toDate}.csv`, rowsCsv(rows, { timezone: site.timezone, dimension }), "text/csv; charset=utf-8");
      return json({ site: site.id, range: rangeOut, dimension, rows });
    }

    // Everything the dashboard shows for a view, as a ZIP of CSV files.
    if (path === "/api/export") {
      const files: Array<{ name: string; text: string }> = [];
      const stats = await runlight.store.stats(query);
      const previous = compared ? await runlight.store.stats({ ...query, from: compared.from, to: compared.to }) : null;
      const now = sheetRow(stats as unknown as Record<string, unknown>, { timezone: site.timezone });
      const before = previous ? sheetRow(previous as unknown as Record<string, unknown>, { timezone: site.timezone }) : null;
      files.push({
        name: "overview.csv",
        text: csv(["metric", "value", ...(before ? ["previous"] : [])], Object.keys(now).map((m) => [m, now[m], ...(before ? [before[m]] : [])])),
      });
      const points = await runlight.store.series(query, buckets(range, site.timezone));
      files.push({ name: "over-time.csv", text: rowsCsv(points as unknown as Array<Record<string, unknown>>, { timezone: site.timezone, interval: range.interval }) });
      for (const dimension of DIMENSIONS) {
        const rows = await runlight.store.breakdown(query, dimension, 1000, 0);
        if (rows.length) files.push({ name: `${dimension}.csv`, text: rowsCsv(rows as unknown as Array<Record<string, unknown>>, { timezone: site.timezone, dimension }) });
      }
      const goals = await runlight.store.goals(site.id);
      if (goals.length) {
        const totals = await runlight.store.goalTotalsAll(query, goals);
        files.push({
          name: "goals.csv",
          text: csv(["goal", "conversions", "visitors", "revenue", "currency"], goals.map((g) => [g.name, totals.get(g.id)!.conversions, totals.get(g.id)!.visitors, totals.get(g.id)!.revenue, g.currency])),
        });
      }
      return download(`${site.id}-${range.fromDate}-${range.toDate}.zip`, zip(files, new Date(runlight.now())), "application/zip");
    }

    return coded("Not found", "not_found", 404);
  }

  const signIn = options.signIn ?? (web ? `${base}/login` : undefined);
  const signOut = options.signOut ?? (web ? `${base}/logout` : undefined);
  const accountOf = options.accountOf ?? web?.accountOf;
  const tokenMade = options.tokenMade ?? (web ? (row: TokenRow, by: string) => web.tokenMade(row, by) : undefined);

  const oauth = {
    runlight,
    base,
    isOwner: async (request: Request) => (await canRead(request)) === true,
    isReader: async (request: Request) => (options.authorize ? (await options.authorize(request)) === "read" : web ? (await web.access(request)) === "read" : false),
    ...(signIn ? { signIn } : {}),
    ...(accountOf ? { accountOf } : {}),
    ...(tokenMade ? { tokenMade } : {}),
  };

  const handler: FetchHandler = async (request, context = {}) => {
    const url = new URL(request.url);
    // OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
    if (base && isOauthDocument(url.pathname)) return (await oauthResponse(oauth, request, url.pathname, url, context)) ?? coded("Not found", "not_found", 404);
    if (base && url.pathname !== base && !url.pathname.startsWith(`${base}/`)) return coded("Not found", "not_found", 404);
    const path = url.pathname.slice(base.length) || "/";

    try {
      // Checked before any route, so a connected site's pass-through to its install is held to it too.
      if (adminOnly(path, request.method) && (await canRead(request)) === true && members.has(request)) {
        return coded("Only an owner or admin can change this", "admin_only", 403);
      }
      // Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
      if (web) {
        const answered = await web.handle(request, path, context);
        if (answered) return answered;
      }
      if (path === "/s.js" && request.method === "GET") {
        const script = await trackerScript(url.searchParams.get("site"));
        const headers = {
          "content-type": "application/javascript; charset=utf-8",
          // Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
          "cache-control": "public, max-age=300",
          etag: script.etag,
        };
        if (request.headers.get("if-none-match") === script.etag) return new Response(null, { status: 304, headers });
        return new Response(script.body, { headers });
      }

      if (path === "/pick.js" && request.method === "GET") {
        // The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does nothing.
        // It also runs only on the pages of the site the ticket names.
        const target = await pickTarget(url.searchParams.get("runlight_ticket") ?? "");
        if (target) await runlight.init();
        const hosts = target ? (runlight.site(target.site)?.hostnames ?? null) : [];
        const script = PICKER.replace(PICK_TARGET_PLACEHOLDER, () => JSON.stringify(hosts ? (target?.origin ?? "") : "")).replace(PICK_HOSTS_PLACEHOLDER, () => JSON.stringify(JSON.stringify(hosts ?? [])));
        return new Response(script, { headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "no-store" } });
      }

      if (path === `/assets/world.${WORLD_HASH}.json` && request.method === "GET") {
        return new Response(WORLD_JSON, {
          headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=31536000, immutable" },
        });
      }

      const locale = /^\/assets\/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json$/.exec(path);
      if (locale && locale[2] === LOCALES_HASH && LOCALES[locale[1]!] && request.method === "GET") {
        return new Response(LOCALES[locale[1]!], {
          headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=31536000, immutable" },
        });
      }

      if (path.startsWith("/assets/app.") && request.method === "GET") {
        const asset = path === `/assets/app.${DASHBOARD_HASH}.js` ? DASHBOARD_JS : path === `/assets/app.${DASHBOARD_HASH}.css` ? DASHBOARD_CSS : null;
        if (asset === null) return coded("Not found", "not_found", 404);
        return new Response(asset, {
          headers: {
            "content-type": path.endsWith(".js") ? "application/javascript; charset=utf-8" : "text/css; charset=utf-8",
            "cache-control": "public, max-age=31536000, immutable",
          },
        });
      }

      if (path === "/e") {
        if (request.method === "OPTIONS") {
          return new Response(null, {
            status: 204,
            headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "POST", "access-control-max-age": "86400" },
          });
        }
        if (request.method !== "POST") return coded("Method not allowed", "method_not_allowed", 405);
        try {
          await runlight.collect(request, context);
        } catch (error) {
          console.error("Runlight: could not record an event", error);
        }
        // The same answer whatever happened, so the endpoint reveals nothing.
        return new Response(null, { status: 202, headers: { "access-control-allow-origin": "*" } });
      }

      if (path === "/api" || path.startsWith("/api/")) return await api(request, path, url);

      if (path.startsWith("/oauth/") || isOauthDocument(path)) {
        const answer = await oauthResponse(oauth, request, path, url, context);
        if (answer) return answer;
      }

      if (path === "/mcp") {
        // No server-sent stream and no sessions: every message is one POST.
        if (request.method !== "POST") return coded("Method not allowed", "method_not_allowed", 405, undefined, { allow: "POST" });
        const access = await reader(request);
        if (access === false || access === "unconfigured") {
          const refused = denied(access);
          // Points an OAuth client at the metadata that starts the sign-in.
          refused.headers.set("www-authenticate", `Bearer realm="runlight", resource_metadata="${resourceMetadataUrl(url.origin, base)}"`);
          return refused;
        }
        // Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
        const headers = new Headers(request.headers);
        for (const name of ["content-type", "content-length", SHARE_HEADER, EMBED_HEADER]) headers.delete(name);
        return await mcpResponse(request, (apiPath, params) => {
          const target = new URL(`${base}${apiPath}`, url.origin);
          for (const [key, value] of params) target.searchParams.append(key, value);
          return api(new Request(target, { headers, signal: request.signal }), apiPath, target);
        });
      }

      const unsubscribe = /^\/unsubscribe\/([^/]+)\/?$/.exec(path);
      if (unsubscribe && (request.method === "GET" || request.method === "POST")) return await unsubscribePage(request, unsubscribe[1]!);

      // The dashboard inside a CMS's admin pages, opened with a ticket its plugin just got. Only the admin origin
      // the ticket names may frame it. A ticket used already or run out opens it with no session, so it says it
      // has expired and offers to reload the admin page; anything else is refused and never framed.
      if (path === "/embed" && request.method === "GET") {
        await runlight.init();
        const found = await redeemEmbed(url.searchParams.get("ticket") ?? "");
        if (!found) {
          const { t, lang } = translator(acceptedLanguage(request));
          return smallPage(lang, `<h1>${escapeHtml(t("embed.goneTitle"))}</h1><p>${escapeHtml(t("embed.gone"))}</p>`, 404);
        }
        const session = found.token ? await embedSession(found.token.id) : "";
        return new Response(DASHBOARD(base, "", "", options.geoCredit, false, "", { session, origin: found.origin }), {
          status: session ? 200 : 410,
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            "content-security-policy": DASHBOARD_CSP.replace("frame-ancestors 'none'", `frame-ancestors ${found.origin}`),
            "referrer-policy": "no-referrer",
            "x-robots-tag": "noindex",
          },
        });
      }

      const sharePage = /^\/share\/([^/]+)\/?$/.exec(path);
      if (sharePage && request.method === "GET") {
        await runlight.init();
        const id = sharePage[1]!;
        const share = SHARE_ID.test(id) ? await runlight.store.shareById(id) : null;
        if (!share) {
          const { t, lang } = translator(acceptedLanguage(request));
          return smallPage(lang, `<h1>${escapeHtml(t("share.goneTitle"))}</h1><p>${escapeHtml(t("share.gone"))}</p>`, 404);
        }
        return new Response(DASHBOARD(base, share.id, "", options.geoCredit), {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            "content-security-policy": DASHBOARD_CSP,
            "x-frame-options": "DENY",
            // The share id is the key; never send it on to another site.
            "referrer-policy": "no-referrer",
            "x-robots-tag": "noindex",
          },
        });
      }

      if ((path === "/" || path === "") && request.method === "GET") {
        const given = url.searchParams.get("token");
        if (given && token && constantTimeEqual(given, token)) {
          url.searchParams.delete("token");
          const secure = url.protocol === "https:" ? "; Secure" : "";
          return new Response(null, {
            status: 303,
            headers: {
              location: url.pathname + url.search,
              "set-cookie": `${COOKIE}=${await cookieValue(token)}; Path=${base || "/"}; HttpOnly; SameSite=Lax; Max-Age=2592000${secure}`,
            },
          });
        }
        // The page itself holds no data; the API it calls checks access and
        // the page explains how to sign in when it is refused.
        return new Response(DASHBOARD(base, "", signOut, options.geoCredit, Boolean(web), signIn), {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            "content-security-policy": DASHBOARD_CSP,
            "x-frame-options": "DENY",
            "referrer-policy": "same-origin",
          },
        });
      }

      return coded("Not found", "not_found", 404);
    } catch (error) {
      console.error("Runlight:", error);
      return coded("Internal error", "internal", 500);
    }
  };

  return { handler, GET: handler, POST: handler, PUT: handler, PATCH: handler, DELETE: handler, OPTIONS: handler };
}
