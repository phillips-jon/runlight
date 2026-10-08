import { AssistantError, PROVIDERS, chat, listModels } from "./assistant.js";
import { finishConnect, startConnect } from "./connect.js";
import { PAGES_PER_VISIT, journeys } from "./journeys.js";
import { DASHBOARD_CSS, DASHBOARD_HASH, DASHBOARD_JS, LOCALES, LOCALES_HASH, WORLD_HASH, WORLD_JSON } from "./generated/dashboard.js";
import { PICKER, TRACKER, TRACKER_HASH } from "./generated/tracker.js";
import { sha256 } from "./hash.js";
import { isDimension, parseFilter, type Filter, type Query } from "./query.js";
import { LINK_DOMAIN_CHECK, type RequestContext, type Runlight } from "./runlight.js";
import type { ShareRow, SiteRow, TokenRow } from "./store.js";
import { mcpResponse } from "./mcp.js";
import { oauthResponse, resourceMetadataUrl } from "./oauth.js";
import { csv, zip } from "./zip.js";
import { DIMENSIONS } from "./query.js";
import { randomId } from "./hash.js";
import { GoalError, clickRules, goalFrom } from "./goals.js";
import { FunnelError, funnelFrom } from "./funnels.js";
import { MailError, SERVICES } from "./mail/transports.js";
import { languages, translator } from "./messages.js";
import type { ReportRow } from "./store.js";
import { fetchIcon } from "./icon.js";
import { ImportError, importStep } from "./importers/index.js";
import { importUmamiVisits, umamiWebsites } from "./importers/visits.js";
import { LinkError } from "./links.js";
import { isSessionDimension } from "./query.js";
import { buckets, compareRange, localDate, localWeekdayHour, resolveRange, type CompareMode } from "./time.js";
import { API_VERSION, VERSION } from "./version.js";

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
   * Your own check instead of a token. Return true for full access, "read" to
   * let the request read every site's stats and change nothing (as an API
   * token can), or false to refuse it.
   */
  authorize?: (request: Request) => boolean | "read" | Promise<boolean | "read">;
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
  /** Where an app connecting over OAuth sends the owner to sign in first. The standalone server sets it. */
  signIn?: string;
  /** The standalone server's accounts: the dashboard offers an Account sheet and, to owners, a People section. */
  accounts?: boolean;
  /** Credits DB-IP in the dashboard's footer, as its free location data asks. The standalone server sets it. */
  geoCredit?: boolean;
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

function env(name: string): string | undefined {
  const value = typeof process === "undefined" ? undefined : process.env[name];
  return value?.trim() ? value.trim() : undefined;
}

function isDevelopment(): boolean {
  return env("NODE_ENV") === "development";
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
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
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return json({ error: `Could not reach ${new URL(remote.url).host}` }, 502);
  }
  const back: Record<string, string> = { "cache-control": "private, no-store" };
  for (const name of ["content-type", "content-disposition"]) {
    const value = answer.headers.get(name);
    if (value) back[name] = value;
  }
  // The install's own errors say what went wrong there; a refused token is this server's problem to report.
  if (answer.status === 401) return json({ error: `${new URL(remote.url).host} refused the token. Connect it again from the site's settings.` }, 502);
  return new Response(answer.body, { status: answer.status, headers: back });
}

/** Rows of objects as CSV, with a column for every key the first row has. */
function rowsCsv(rows: ReadonlyArray<object>): string {
  const header = rows.length ? Object.keys(rows[0]!) : ["value"];
  return csv(header, rows.map((r) => header.map((k) => (r as Record<string, unknown>)[k])));
}

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

/** The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. */
export const RUNLIGHT_ICON = "data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2032%2032%22%3E%3Cstyle%3E.h%7Bfill%3A%23000%7D.r%7Bstroke%3A%23fff%7D%40media%20%28prefers-color-scheme%3Adark%29%7B.h%7Bfill%3A%23fff%7D.r%7Bstroke%3A%23000%7D%7D%3C/style%3E%3Crect%20class%3D%22h%22%20x%3D%222.5%22%20y%3D%222.5%22%20width%3D%2227%22%20height%3D%2227%22%20rx%3D%227%22/%3E%3Cpath%20class%3D%22r%22%20d%3D%22M11%2023V9h6.2a4.3%204.3%200%200%201%200%208.6H11m6%200%205%205.4%22%20fill%3D%22none%22%20stroke-width%3D%222.8%22%20stroke-linecap%3D%22round%22%20stroke-linejoin%3D%22round%22/%3E%3Ccircle%20cx%3D%2223.6%22%20cy%3D%228.4%22%20r%3D%222.6%22%20fill%3D%22%2322c55e%22/%3E%3C/svg%3E";

const DASHBOARD = (base: string, share = "", signOut = "", geoCredit = false, accounts = false) => `<!doctype html>
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
<div id="app" data-base="${escapeAttr(base)}"${share ? ` data-share="${escapeAttr(share)}"` : ""}${signOut ? ` data-sign-out="${escapeAttr(signOut)}"` : ""}${geoCredit ? ` data-geo-credit=""` : ""}${accounts ? ` data-accounts=""` : ""} data-world="${escapeAttr(base)}/assets/world.${WORLD_HASH}.json" data-locales="${escapeAttr(localeUrls(base))}"></div>
<script type="module" src="${escapeAttr(base)}/assets/app.${DASHBOARD_HASH}.js"></script>
</body>
</html>
`;

/** API tokens start with this, so they are told apart from the main token. */
const TOKEN_PREFIX = "rl_";

/** The header a shared dashboard sends its share id in. */
const SHARE_HEADER = "x-runlight-share";
/** What a share can read: one site's reports, nothing that changes anything. */
const SHARED_PATHS = new Set(["/api/sites", "/api/icon", "/api/realtime", "/api/stats", "/api/series", "/api/rhythm", "/api/breakdown", "/api/goals", "/api/event-props", "/api/export", "/api/funnels", "/api/journeys"]);
const sharedPath = (path: string) => SHARED_PATHS.has(path) || /^\/api\/goals\/[a-f0-9]{24}$/.test(path);

/**
 * What a manage token, held by a Runlight hub, may read and change: one
 * site's goals, funnels, short links, link domains, email reports, and share
 * links, and its name, timezone, and retention. Never people, tokens, the
 * mail service, imports, or other sites.
 */
export function managePath(method: string, path: string): boolean {
  if (/^\/api\/links\/import/.test(path)) return false;
  if (/^\/api\/(links|link-domains|reports|goals|funnels|shares)(\/|$)/.test(path)) return true;
  if (path === "/api/mail") return method === "GET";
  if (/^\/api\/sites\/[^/]+$/.test(path)) return method === "PATCH";
  return false;
}
/** Where the tracker's click rules go; the script ships with this string in their place. */
const RULES_PLACEHOLDER = '"__RUNLIGHT_RULES__"';
const SHARE_ID = /^[a-f0-9]{32}$/;

const DASHBOARD_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export function createRoutes(runlight: Runlight, options: RoutesOptions = {}): Routes {
  const base = normaliseBase(options.basePath ?? "/runlight");
  const token = options.token === undefined ? env("RUNLIGHT_TOKEN") : options.token;
  const cronSecret = options.cronSecret ?? env("CRON_SECRET");
  const observeKey = options.observeKey ?? env("RUNLIGHT_OBSERVE_KEY");
  let warned = false;

  // Requests from a manage token, already checked against its one site, act as the owner's.
  const managed = new WeakSet<Request>();

  async function canRead(request: Request): Promise<boolean | "unconfigured"> {
    if (managed.has(request)) return true;
    if (options.authorize) return (await options.authorize(request)) === true;
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
    if (token) return token;
    if (options.authorize) {
      const answer = await options.authorize(request);
      // A read-only sign-in reads like an API token for every site.
      return answer === "read" ? { id: "", name: "", site: "", scope: "read", hash: "", hint: "", createdAt: 0, lastUsedAt: null } : answer === true;
    }
    return canRead(request);
  }

  function denied(result: false | "unconfigured"): Response {
    return result === "unconfigured"
      ? json({ error: "Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development." }, 503)
      : json({ error: "Unauthorized" }, 401);
  }

  async function querySite(url: URL): Promise<SiteRow | Response> {
    const site = runlight.site(url.searchParams.get("site"));
    return site ?? json({ error: "Unknown site" }, 404);
  }

  async function readQuery(url: URL, site: SiteRow) {
    const filters: Filter[] = [];
    for (const raw of url.searchParams.getAll("filter")) {
      const filter = parseFilter(raw);
      if (!filter) return json({ error: `Bad filter "${raw}". Use dimension:is|not|contains:value.` }, 400);
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
    if (!range) return json({ error: "Bad date range. Use period, or from and to as YYYY-MM-DD." }, 400);
    const query: Query = { site: site.id, from: range.from, to: range.to, filters };
    // compare=false is the older spelling of off.
    const raw = url.searchParams.get("compare") ?? "previous";
    const mode = (raw === "false" ? "off" : raw) as CompareMode;
    if (!["previous", "year", "custom", "off"].includes(mode)) return json({ error: `Bad compare "${raw}". Use previous, year, custom, or off.` }, 400);
    const compared = compareRange(range, mode, site.timezone, { from: url.searchParams.get("compare_from"), to: url.searchParams.get("compare_to") });
    if (mode === "custom" && !compared) return json({ error: "Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD." }, 400);
    return { query, range, compared };
  }

  async function readJson(request: Request): Promise<Record<string, unknown> | Response> {
    // A form posted from another site cannot carry this content type without CORS.
    if (!isJson(request)) return json({ error: "Send JSON" }, 415);
    const body = (await request.json().catch(() => null)) as unknown;
    return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : json({ error: "Send a JSON object" }, 400);
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
          const domain = String(body.domain ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/^www\./, "");
          if (!/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(domain)) return json({ error: "That is not a domain name" }, 400);
          const owner = (await runlight.store.linkDomains()).find((d) => d.domain === domain);
          if (owner && owner.site !== site.id) return json({ error: `${domain} already belongs to another site` }, 409);
          await runlight.store.addLinkDomain(domain, site.id, runlight.now());
          runlight.forgetLinkDomains();
          return json({ domain }, 201);
        }
      }
      const checkMatch = /^\/api\/link-domains\/([^/]+)\/check$/.exec(path);
      if (checkMatch && request.method === "GET") {
        const domain = decodeURIComponent(checkMatch[1]!);
        if (!(await runlight.store.linkDomains()).some((d) => d.domain === domain && d.site === site.id)) return json({ error: "Unknown domain" }, 404);
        let working = false;
        let reason = "";
        try {
          const answer = await fetch(`https://${domain}${LINK_DOMAIN_CHECK}`, { signal: AbortSignal.timeout(5000), redirect: "manual" });
          const body = (await answer.json().catch(() => null)) as { runlight?: boolean; domain?: string } | null;
          working = answer.ok && body?.runlight === true && body.domain === domain;
          if (!working) reason = answer.ok ? "answered, but not from Runlight" : `answered ${answer.status}`;
        } catch (error) {
          reason = error instanceof Error && error.name === "TimeoutError" ? "timed out" : "could not connect over HTTPS";
        }
        return json({ domain, working, reason });
      }

      const domainMatch = /^\/api\/link-domains\/([^/]+)$/.exec(path);
      if (domainMatch && request.method === "DELETE") {
        const domain = decodeURIComponent(domainMatch[1]!);
        if (!(await runlight.store.linkDomains()).some((d) => d.domain === domain && d.site === site.id)) return json({ error: "Unknown domain" }, 404);
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
          if (error instanceof ImportError) return json({ error: error.message }, 400);
          throw error;
        }
      }

      if (path === "/api/links/import" && request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        const rows = Array.isArray(body.rows) ? (body.rows as Array<Record<string, unknown>>).slice(0, 5000) : null;
        if (!rows) return json({ error: "Send rows as a list" }, 400);
        return json(await runlight.links.import(site.id, rows));
      }

      const linkMatch = /^\/api\/links\/([a-f0-9]+)$/.exec(path);
      if (linkMatch) {
        const id = linkMatch[1]!;
        if (request.method === "GET") {
          const link = await runlight.store.linkById(id);
          if (!link || link.site !== site.id) return json({ error: "Unknown link" }, 404);
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
        if (!owned || owned.site !== site.id) return json({ error: "Unknown link" }, 404);
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
      if (error instanceof LinkError) return json({ error: error.message }, 400);
      if (error instanceof RangeError) return json({ error: error.message }, 404);
      throw error;
    }
    return json({ error: "Not found" }, 404);
  }

  // The tracker with click rules inside, rebuilt when goals change. With ?site= it
  // carries only that site's rules, so one site's visitors never see another
  // site's domains or goals. The standalone server's snippet always names the
  // site; without a name it serves no rules, and an app's own install, whose
  // sites all belong to one owner, serves every site's.
  const trackers = new Map<string, { body: string; etag: string; at: number }>();
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
    if (id !== undefined && !existing.some((g) => g.id === id)) return json({ error: "Unknown goal" }, 404);
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
      if (error instanceof GoalError) return json({ error: error.message }, 400);
      throw error;
    }
  }

  const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/;
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
          return json({
            source: settings?.source ?? null,
            service: settings?.service ?? "",
            from: settings?.from ?? "",
            fromName: settings?.fromName ?? "",
            fields,
            saved,
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
        return json({ error: "Method not allowed" }, 405);
      }

      if (path === "/api/mail/test" && request.method === "POST") {
        const body = await readJson(request);
        if (body instanceof Response) return body;
        const to = String(body.to ?? "").trim();
        if (!EMAIL.test(to)) return json({ error: "Enter an email address to send the test to" }, 400);
        const { t } = translator(String(body.lang ?? "en"));
        const settings = await runlight.mailSettings();
        const name = SERVICES.find((x) => x.id === settings?.service)?.name ?? "";
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
          if (!EMAIL.test(email)) return json({ error: "Enter an email address" }, 400);
          const frequency = body.frequency === "monthly" ? "monthly" : "weekly";
          const existing = await runlight.store.reports(site.id);
          if (existing.some((r) => r.email === email && r.frequency === frequency)) return json({ error: `${email} already gets the ${frequency} report` }, 400);
          if (existing.length >= 50) return json({ error: "A site can send to at most 50 addresses" }, 400);
          // Links in the email point back to this dashboard, as the browser sees it.
          const given = String(body.origin ?? "");
          const origin = /^https?:\/\/[^\s]+$/.test(given) ? given.replace(/\/+$/, "") : `${url.origin}${base}`;
          const report: ReportRow = {
            id: randomId(),
            site: site.id,
            email,
            frequency,
            lang: languages().includes(String(body.lang)) ? String(body.lang) : "en",
            token: randomId(16),
            origin,
            lastPeriod: "",
            lastSentAt: null,
            createdAt: runlight.now(),
          };
          await runlight.store.insertReport(report);
          return json({ report: reportView(report) }, 201);
        }
        return json({ error: "Method not allowed" }, 405);
      }

      const match = /^\/api\/reports\/([a-f0-9]{24})(\/send)?$/.exec(path);
      const report = match ? await runlight.store.reportBy("id", match[1]!) : null;
      if (!report || report.site !== site.id) return json({ error: "Unknown report" }, 404);
      if (match![2] && request.method === "POST") {
        await runlight.deliverReport(report, site);
        return json({ ok: true });
      }
      if (!match![2] && request.method === "DELETE") {
        await runlight.store.deleteReport(report.id);
        return json({ ok: true });
      }
      return json({ error: "Method not allowed" }, 405);
    } catch (error) {
      if (error instanceof MailError) return json({ error: error.message }, 400);
      throw error;
    }
  }

  /** A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing. */
  async function unsubscribePage(request: Request, token: string): Promise<Response> {
    await runlight.init();
    const report = /^[a-f0-9]{32}$/.test(token) ? await runlight.store.reportBy("token", token) : null;
    const site = report ? runlight.site(report.site) : null;
    const { t, lang } = translator(report?.lang ?? "en");
    const page = (body: string, status = 200) =>
      new Response(
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
      return json({ error: "Method not allowed" }, 405);
    }

    const id = decodeURIComponent(path.slice("/api/shares/".length));
    const share = SHARE_ID.test(id) ? await runlight.store.shareById(id) : null;
    if (!share || share.site !== site.id) return json({ error: "Unknown share" }, 404);
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
    return json({ error: "Method not allowed" }, 405);
  }

  async function tokensApi(request: Request, path: string): Promise<Response> {
    await runlight.init();
    const view = (t: TokenRow) => ({ id: t.id, name: t.name, site: t.site, scope: t.scope, hint: t.hint, createdAt: t.createdAt, lastUsedAt: t.lastUsedAt });
    if (path === "/api/tokens" && request.method === "GET") return json({ tokens: (await runlight.store.tokens()).map(view) });
    if (path === "/api/tokens" && request.method === "POST") {
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const name = String(body.name ?? "").trim().slice(0, 100);
      if (!name) return json({ error: "Name the token" }, 400);
      const site = String(body.site ?? "");
      if (site && !runlight.sites.some((s) => s.id === site)) return json({ error: "Unknown site" }, 404);
      const scope = body.scope === "manage" ? "manage" : "read";
      if (scope === "manage" && !site) return json({ error: "A token that changes settings is for one site. Pick the site." }, 400);
      const secret = `${TOKEN_PREFIX}${randomId(20)}`;
      const row: TokenRow = { id: randomId(), name, site, scope, hash: await sha256(secret), hint: secret.slice(-4), createdAt: runlight.now(), lastUsedAt: null };
      await runlight.store.insertToken(row);
      // The only time the token is ever shown.
      return json({ token: view(row), secret }, 201);
    }
    const match = /^\/api\/tokens\/([a-f0-9]{24})$/.exec(path);
    if (match && request.method === "DELETE") {
      return (await runlight.store.deleteToken(match[1]!)) ? json({ ok: true }) : json({ error: "Unknown token" }, 404);
    }
    return json({ error: "Not found" }, 404);
  }

  async function api(request: Request, path: string, url: URL): Promise<Response> {
    if (path === "/api" && request.method === "GET") {
      return json({ name: "runlight", version: VERSION, api: API_VERSION, ...IMPLEMENTATION });
    }

    // A hub asks what its token may do before offering to change anything.
    if (path === "/api/token" && request.method === "GET") {
      const token = await apiToken(request);
      if (!token) return denied(false);
      return json({ scope: token.scope, site: token.site });
    }

    // Connecting another Runlight through its consent page, so nobody copies a token.
    if (path === "/api/sites/connect" && request.method === "POST") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      await runlight.init();
      if (!runlight.managedSites) return json({ error: "Sites are set in code" }, 400);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      try {
        return json({ authorize: await startConnect(runlight, body.url, `${url.origin}${base}/api/sites/connect/done`) });
      } catch (error) {
        if (error instanceof RangeError) return json({ error: error.message }, 400);
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
        to = `${home}?site=${encodeURIComponent(id)}&settings=general`;
      } catch (error) {
        if (!(error instanceof RangeError)) throw error;
        to = `${home}?connect_error=${encodeURIComponent(error.message)}`;
      }
      return new Response(null, { status: 303, headers: { location: to, "cache-control": "no-store" } });
    }

    const token = bearer(request).startsWith(TOKEN_PREFIX) ? await apiToken(request) : null;
    if (token?.scope === "manage" && managePath(request.method, path)) {
      const asked = url.searchParams.get("site");
      const siteMatch = /^\/api\/sites\/([^/]+)$/.exec(path);
      if ((asked && asked !== token.site) || (siteMatch && decodeURIComponent(siteMatch[1]!) !== token.site)) return json({ error: "Unknown site" }, 404);
      if (siteMatch && request.headers.get("content-type")?.includes("json")) {
        // Where a site lives stays with its owner: a hub may rename it, never move it.
        const body = (await request.clone().json().catch(() => null)) as Record<string, unknown> | null;
        if (body && body.hostnames !== undefined) return json({ error: "A connected hub cannot change a site's domains" }, 403);
      }
      url = new URL(url);
      url.searchParams.set("site", token.site);
      managed.add(request);
    }

    // A page another site served to an AI agent, reported by a CMS plugin.
    if (path === "/api/observe" && request.method === "POST") {
      const given = bearer(request);
      // The install-wide key and the owner's access can report for any site.
      const anySite = Boolean(observeKey && given && constantTimeEqual(given, observeKey)) || (await canRead(request)) === true;
      if (!anySite && !given) return json({ error: "Unauthorized" }, 401);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
      const list = Array.isArray(body.fetches) ? (body.fetches as Array<Record<string, unknown>>) : [body];
      if (list.length > 500) return json({ error: "Send at most 500 fetches at a time" }, 413);
      const pages: Array<{ page: URL; userAgent: string; at?: number }> = [];
      for (const item of list) {
        let page: URL;
        try {
          page = new URL(String(item?.url ?? ""));
        } catch {
          return json({ error: "Send the page's url" }, 400);
        }
        if (page.protocol !== "https:" && page.protocol !== "http:") return json({ error: "Send the page's url" }, 400);
        const at = typeof item.at === "number" ? item.at : typeof item.at === "string" ? Date.parse(item.at) : undefined;
        pages.push({ page, userAgent: String(item.userAgent ?? "").slice(0, 500), ...(at !== undefined && Number.isFinite(at) ? { at } : {}) });
      }
      if (!anySite) {
        // A site's own key reports only pages on that site's domains.
        await runlight.init();
        for (const host of new Set(pages.map((p) => p.page.hostname))) {
          const site = runlight.siteFor(host);
          const key = site ? await runlight.store.setting(`observe-key:${site.id}`) : null;
          if (!key || !constantTimeEqual(given, key)) return json({ error: "Unauthorized" }, 401);
        }
      }
      for (const p of pages) await runlight.observe(new Request(p.page, { headers: { "user-agent": p.userAgent } }), p.at);
      return new Response(null, { status: 204 });
    }

    // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
    if (path === "/api/check" && (request.method === "POST" || request.method === "GET")) {
      const given = bearer(request);
      const allowed =
        (cronSecret && given && constantTimeEqual(given, cronSecret)) || (await canRead(request)) === true;
      if (!allowed) return json({ error: "Unauthorized" }, 401);
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
      return json({ error: "This site is counted by its own Runlight. Connect it again from its settings to change it from here." }, 400);
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
        if (error instanceof ImportError) return json({ error: error.message }, 400);
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
      if (id !== undefined && !existing.some((f) => f.id === id)) return json({ error: "Unknown funnel" }, 404);
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
        if (error instanceof FunnelError) return json({ error: error.message }, 400);
        throw error;
      }
    }

    // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
    if (path === "/api/assistant") {
      const owner = (await canRead(request)) === true;
      if (request.method === "GET") {
        const access = await reader(request);
        if (access === false || access === "unconfigured") return denied(access);
        // Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
        if (access !== true && access.id) return json({ error: "Only the dashboard can use the assistant" }, 403);
        await runlight.init();
        const settings = await runlight.assistantSettings();
        if (!owner) return json({ configured: Boolean(settings) });
        return json({
          configured: Boolean(settings),
          provider: settings?.provider ?? "",
          model: settings?.model ?? "",
          baseUrl: settings?.baseUrl ?? "",
          keySaved: Boolean(settings?.key),
          encrypted: runlight.secret !== null,
          providers: PROVIDERS,
        });
      }
      if (!owner) return denied(false);
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
          if (error instanceof RangeError) return json({ error: error.message }, 400);
          throw error;
        }
      }
      return json({ error: "Method not allowed" }, 405);
    }
    // The models a service offers, for the setup form's dropdown. The key can be the one already saved.
    if (path === "/api/assistant/models" && request.method === "POST") {
      if ((await canRead(request)) !== true) return denied(false);
      await runlight.init();
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const provider = String(body.provider ?? "");
      const saved = await runlight.assistantSettings();
      const key = String(body.key ?? "").trim() || (saved?.provider === provider ? saved.key : "");
      try {
        return json({ models: await listModels({ provider, baseUrl: String(body.baseUrl ?? "").trim(), key }) });
      } catch (error) {
        if (error instanceof AssistantError) return json({ error: error.message }, 400);
        throw error;
      }
    }
    if (path === "/api/assistant/chat" && request.method === "POST") {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      if (access !== true && access.id) return json({ error: "Only the dashboard can use the assistant" }, 403);
      if (request.headers.get(SHARE_HEADER) !== null) return json({ error: "Not available on a shared dashboard" }, 403);
      await runlight.init();
      const settings = await runlight.assistantSettings();
      if (!settings) return json({ error: "The assistant is not set up yet. An owner can set it up in Settings, AI Assistant." }, 400);
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const site = runlight.site(String(body.site ?? "") || null);
      if (!site) return json({ error: "Unknown site" }, 404);
      const messages = Array.isArray(body.messages)
        ? (body.messages as Array<Record<string, unknown>>).filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string").map((m) => ({ role: m.role as "user" | "assistant", content: String(m.content) }))
        : [];
      if (!messages.length || messages[messages.length - 1]!.role !== "user") return json({ error: "Ask a question" }, 400);
      // Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
      const headers = new Headers(request.headers);
      for (const name of ["content-type", "content-length", SHARE_HEADER]) headers.delete(name);
      const readApi = (apiPath: string, params: [string, string][]) => {
        const target = new URL(`${base}${apiPath}`, url.origin);
        for (const [key, value] of params) target.searchParams.append(key, value);
        // A tool that names no site reads the one on screen, not the install's first.
        if (apiPath !== "/api/sites" && !target.searchParams.has("site")) target.searchParams.set("site", site.id);
        return api(new Request(target, { headers }), apiPath, target);
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
        );
        return json(answer);
      } catch (error) {
        if (error instanceof AssistantError) return json({ error: error.message }, 502);
        throw error;
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
      return passThrough(connected, path, url);
    }

    // An API token may list links and their clicks, but not change them.
    if (path === "/api/links" && request.method === "GET" && bearer(request).startsWith(TOKEN_PREFIX)) {
      const token = await apiToken(request);
      if (!token) return denied(false);
      await runlight.init();
      const site = runlight.site(url.searchParams.get("site") ?? (token.site || null));
      if (!site || (token.site && site.id !== token.site)) return json({ error: "Unknown site" }, 404);
      const scoped = new URL(url);
      scoped.searchParams.set("site", site.id);
      return linksApi(request, path, scoped);
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
        if (error instanceof RangeError) return json({ error: error.message }, 400);
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
        if (error instanceof RangeError) return json({ error: error.message }, error.message === "Unknown site" ? 404 : 400);
        throw error;
      }
    }
    if (siteMatch && request.method === "PATCH") {
      const access = await canRead(request);
      if (access !== true) return denied(access);
      // A form posted from another site cannot carry this content type without CORS.
      const body = await readJson(request);
      if (body instanceof Response) return body;
      try {
        const id = decodeURIComponent(siteMatch[1]!);
        const remote = runlight.remote(id);
        if (body.retentionMonths !== undefined && remote) {
          // How long a connected site keeps visits is the install's setting; this server only passes it on.
          if (remote.scope !== "manage") return json({ error: "Connect this site again to change it from here" }, 400);
          const answer = await passThrough(
            remote,
            `/api/sites/${encodeURIComponent(remote.site)}`,
            new URL(url),
            new Request(request.url, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ retentionMonths: body.retentionMonths }) }),
          );
          if (!answer.ok) return answer;
          runlight.forgetRemoteInfo(id);
        } else if (body.retentionMonths !== undefined) {
          await runlight.setRetention(id, body.retentionMonths === null ? null : Number(body.retentionMonths));
        }
        const site = await runlight.updateSite(decodeURIComponent(siteMatch[1]!), {
          ...(body.name !== undefined ? { name: String(body.name) } : {}),
          ...(body.timezone !== undefined ? { timezone: String(body.timezone) } : {}),
          ...(body.hostnames !== undefined && runlight.managedSites ? { hostnames: body.hostnames } : {}),
        });
        return json({ site });
      } catch (error) {
        if (error instanceof RangeError) return json({ error: error.message }, error.message === "Unknown site" ? 404 : 400);
        throw error;
      }
    }

    if (request.method !== "GET") return json({ error: "Method not allowed" }, 405);

    await runlight.init();
    // A shared dashboard sees exactly what its visitors see, even for someone signed in.
    const shareId = request.headers.get(SHARE_HEADER);
    let shared: ShareRow | null = null;
    // The one site a share or a site's API token may read; null for every site.
    let only: string | null = null;
    if (shareId !== null) {
      shared = SHARE_ID.test(shareId) ? await runlight.store.shareById(shareId) : null;
      if (!shared) return json({ error: "This share link no longer works" }, 404);
      if (!sharedPath(path)) return json({ error: "Not available on a shared dashboard" }, 403);
      only = shared.site;
    } else {
      const access = await reader(request);
      if (access === false || access === "unconfigured") return denied(access);
      if (access !== true) {
        if (!sharedPath(path)) return json({ error: "API tokens can only read" }, 403);
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
          ...(runlight.remote(site.id) && !shared ? { remote: runlight.remote(site.id)!.url, manage: runlight.remote(site.id)!.scope === "manage", hostnames: runlight.remote(site.id)!.hostnames } : {}),
          // Hostnames say where the site lives; a share shows only its name.
          ...(shared ? { hostnames: [] } : {}),
          lastSeen: runlight.remote(site.id) ? await runlight.remoteLastSeen(site.id) : await runlight.store.lastSeen(site.id),
          ...(shared ? {} : { retentionMonths: runlight.remote(site.id) ? ((await runlight.remoteInfo(site.id))?.retentionMonths ?? null) : await runlight.retention(site.id) }),
        })),
      );
      // A share never learns how the install is run.
      return json(shared ? { sites } : { sites, managed: runlight.managedSites });
    }

    const site = shared ? runlight.site(shared.site) : only ? runlight.site(url.searchParams.get("site") ?? only) : await querySite(url);
    if (site instanceof Response) return site;
    if (!site || (only && site.id !== only)) return json({ error: "Unknown site" }, 404);
    const remote = runlight.remote(site.id);
    if (remote) return passThrough(remote, path, url);

    if (path === "/api/icon") {
      const host = site.hostnames[0];
      // Only a site's own domain, never the request's Host header, which a caller can write.
      const icon = host ? await fetchIcon(`https://${host}`) : null;
      if (!icon) return json({ error: "No icon" }, 404, { "cache-control": "private, max-age=3600" });
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
      if (!goal || goal.site !== site.id) return json({ error: "Unknown goal" }, 404);
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
      const answer = journeys(await runlight.store.journeyPages(query, PAGES_PER_VISIT), {
        steps: Number(q.get("steps") ?? 5),
        ...(q.get("start") ? { start: q.get("start")! } : {}),
        ...(q.get("end") ? { end: q.get("end")! } : {}),
        ...(through ? { through: { step: Number(through[1]), value: through[2]! } } : {}),
      });
      return json({ site: site.id, range: rangeOut, ...answer });
    }

    if (path === "/api/funnels") {
      const funnels = await runlight.store.funnels(site.id);
      const rows = await Promise.all(
        funnels.map(async (funnel) => {
          const counts = await runlight.store.funnelCounts(query, funnel);
          return { ...funnel, steps: funnel.steps.map((step, i) => ({ ...step, visits: counts[i]! })) };
        }),
      );
      return json({ site: site.id, range: rangeOut, funnels: rows });
    }

    if (path === "/api/event-props") {
      const event = url.searchParams.get("event") ?? "";
      if (!event) return json({ error: "Name the event" }, 400);
      const keys = await runlight.store.eventPropKeys(query, event);
      const asked = url.searchParams.get("key");
      // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
      if (asked !== null && !/^[^"\\]{1,64}$/.test(asked)) return json({ error: "Bad property name" }, 400);
      const key = asked ?? keys[0]?.key ?? null;
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get("limit")) || 100));
      const rows = key ? await runlight.store.eventPropValues(query, event, key, limit) : [];
      return json({ site: site.id, range: rangeOut, event, keys, key, rows });
    }

    if (path === "/api/breakdown") {
      const dimension = url.searchParams.get("dimension") ?? "";
      if (!isDimension(dimension)) return json({ error: `Unknown dimension "${dimension}"` }, 400);
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get("limit")) || 10));
      const page = Math.max(1, Number(url.searchParams.get("page")) || 1);
      const rows = await runlight.store.breakdown(query, dimension, limit, (page - 1) * limit);
      if (url.searchParams.get("format") === "csv") return download(`${site.id}-${dimension}-${range.fromDate}-${range.toDate}.csv`, rowsCsv(rows), "text/csv; charset=utf-8");
      return json({ site: site.id, range: rangeOut, dimension, rows });
    }

    // Everything the dashboard shows for a view, as a ZIP of CSV files.
    if (path === "/api/export") {
      const files: Array<{ name: string; text: string }> = [];
      const stats = await runlight.store.stats(query);
      const previous = compared ? await runlight.store.stats({ ...query, from: compared.from, to: compared.to }) : null;
      const metrics = Object.keys(stats) as Array<keyof typeof stats>;
      files.push({
        name: "overview.csv",
        text: csv(["metric", "value", ...(previous ? ["previous"] : [])], metrics.map((m) => [m, stats[m], ...(previous ? [previous[m]] : [])])),
      });
      const points = await runlight.store.series(query, buckets(range, site.timezone));
      files.push({ name: "over-time.csv", text: rowsCsv(points as unknown as Array<Record<string, unknown>>) });
      for (const dimension of DIMENSIONS) {
        const rows = await runlight.store.breakdown(query, dimension, 1000, 0);
        if (rows.length) files.push({ name: `${dimension}.csv`, text: rowsCsv(rows as unknown as Array<Record<string, unknown>>) });
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

    return json({ error: "Not found" }, 404);
  }

  const oauth = { runlight, base, isOwner: async (request: Request) => (await canRead(request)) === true, ...(options.signIn ? { signIn: options.signIn } : {}) };

  const handler: FetchHandler = async (request, context = {}) => {
    const url = new URL(request.url);
    // OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
    if (base && url.pathname.startsWith("/.well-known/oauth-")) return (await oauthResponse(oauth, request, url.pathname, url)) ?? json({ error: "Not found" }, 404);
    if (base && url.pathname !== base && !url.pathname.startsWith(`${base}/`)) return json({ error: "Not found" }, 404);
    const path = url.pathname.slice(base.length) || "/";

    try {
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
        return new Response(PICKER, { headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600" } });
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
        if (asset === null) return json({ error: "Not found" }, 404);
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
        if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
        try {
          await runlight.collect(request, context);
        } catch (error) {
          console.error("Runlight: could not record an event", error);
        }
        // The same answer whatever happened, so the endpoint reveals nothing.
        return new Response(null, { status: 202, headers: { "access-control-allow-origin": "*" } });
      }

      if (path === "/api" || path.startsWith("/api/")) return await api(request, path, url);

      if (path.startsWith("/oauth/") || path.startsWith("/.well-known/oauth-")) {
        const answer = await oauthResponse(oauth, request, path, url);
        if (answer) return answer;
      }

      if (path === "/mcp") {
        // No server-sent stream and no sessions: every message is one POST.
        if (request.method !== "POST") return json({ error: "Method not allowed" }, 405, { allow: "POST" });
        const access = await reader(request);
        if (access === false || access === "unconfigured") {
          const refused = denied(access);
          // Points an OAuth client at the metadata that starts the sign-in.
          refused.headers.set("www-authenticate", `Bearer realm="runlight", resource_metadata="${resourceMetadataUrl(url.origin, base)}"`);
          return refused;
        }
        // Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
        const headers = new Headers(request.headers);
        for (const name of ["content-type", "content-length", SHARE_HEADER]) headers.delete(name);
        return await mcpResponse(request, (apiPath, params) => {
          const target = new URL(`${base}${apiPath}`, url.origin);
          for (const [key, value] of params) target.searchParams.append(key, value);
          return api(new Request(target, { headers }), apiPath, target);
        });
      }

      const unsubscribe = /^\/unsubscribe\/([^/]+)\/?$/.exec(path);
      if (unsubscribe && (request.method === "GET" || request.method === "POST")) return await unsubscribePage(request, unsubscribe[1]!);

      const sharePage = /^\/share\/([^/]+)\/?$/.exec(path);
      if (sharePage && request.method === "GET") {
        await runlight.init();
        const id = sharePage[1]!;
        const share = SHARE_ID.test(id) ? await runlight.store.shareById(id) : null;
        if (!share) return new Response("This share link no longer works.", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
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
        return new Response(DASHBOARD(base, "", options.signOut, options.geoCredit, options.accounts), {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "cache-control": "no-store",
            "content-security-policy": DASHBOARD_CSP,
            "x-frame-options": "DENY",
            "referrer-policy": "same-origin",
          },
        });
      }

      return json({ error: "Not found" }, 404);
    } catch (error) {
      console.error("Runlight:", error);
      return json({ error: "Internal error" }, 500);
    }
  };

  return { handler, GET: handler, POST: handler, PUT: handler, PATCH: handler, DELETE: handler, OPTIONS: handler };
}
