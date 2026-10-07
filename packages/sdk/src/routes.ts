import { DASHBOARD_CSS, DASHBOARD_HASH, DASHBOARD_JS, WORLD_HASH, WORLD_JSON } from "./generated/dashboard.js";
import { TRACKER, TRACKER_HASH } from "./generated/tracker.js";
import { sha256 } from "./hash.js";
import { isDimension, parseFilter, type Filter, type Query } from "./query.js";
import type { RequestContext, Runlight } from "./runlight.js";
import type { SiteRow } from "./store.js";
import { fetchIcon } from "./icon.js";
import { buckets, localDate, localWeekdayHour, previousRange, resolveRange } from "./time.js";
import { API_VERSION, VERSION } from "./version.js";

export interface RoutesOptions {
  /** Where the routes are mounted. Default "/runlight". */
  basePath?: string;
  /**
   * Required to read stats. Send it as `Authorization: Bearer <token>`, or
   * open the dashboard once with `?token=<token>` and a cookie is set.
   * Defaults to process.env.RUNLIGHT_TOKEN. Without one, stats are open in
   * development and answer 503 in production. Pass `null` to leave them
   * open everywhere, for example behind your own auth middleware.
   */
  token?: string | null;
  /** Your own check instead of a token. Return true to let the request read stats. */
  authorize?: (request: Request) => boolean | Promise<boolean>;
  /**
   * Also accepted as a bearer token on POST /api/check, so a platform cron
   * can run scheduled work. Defaults to process.env.CRON_SECRET.
   */
  cronSecret?: string;
}

export type FetchHandler = (request: Request, context?: RequestContext) => Promise<Response>;

export interface Routes {
  handler: FetchHandler;
  GET: FetchHandler;
  POST: FetchHandler;
  OPTIONS: FetchHandler;
}

const COOKIE = "runlight_token";
const IMPLEMENTATION = { library: "@runlight/sdk", language: "typescript" };

function env(name: string): string | undefined {
  const value = typeof process === "undefined" ? undefined : process.env[name];
  return value?.trim() ? value.trim() : undefined;
}

function isProduction(): boolean {
  return env("NODE_ENV") === "production";
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
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

const DASHBOARD = (base: string) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Runlight</title>
<link rel="stylesheet" href="${escapeAttr(base)}/assets/app.${DASHBOARD_HASH}.css">
</head>
<body>
<div id="app" data-base="${escapeAttr(base)}" data-world="${escapeAttr(base)}/assets/world.${WORLD_HASH}.json"></div>
<script type="module" src="${escapeAttr(base)}/assets/app.${DASHBOARD_HASH}.js"></script>
</body>
</html>
`;

const DASHBOARD_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export function createRoutes(runlight: Runlight, options: RoutesOptions = {}): Routes {
  const base = normaliseBase(options.basePath ?? "/runlight");
  const token = options.token === undefined ? env("RUNLIGHT_TOKEN") : options.token;
  const cronSecret = options.cronSecret ?? env("CRON_SECRET");
  let warned = false;

  async function canRead(request: Request): Promise<boolean | "unconfigured"> {
    if (options.authorize) return Boolean(await options.authorize(request));
    if (token === null) return true;
    if (!token) {
      if (isProduction()) return "unconfigured";
      if (!warned) {
        warned = true;
        console.warn("Runlight: no RUNLIGHT_TOKEN set, so stats are open. That is fine in development; production answers 503 until one is set.");
      }
      return true;
    }
    const given = bearer(request);
    if (given && constantTimeEqual(given, token)) return true;
    const cookie = readCookie(request, COOKIE);
    return Boolean(cookie) && constantTimeEqual(cookie, await cookieValue(token));
  }

  function denied(result: false | "unconfigured"): Response {
    return result === "unconfigured"
      ? json({ error: "Set RUNLIGHT_TOKEN, or pass token or authorize to routes()." }, 503)
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
    return { query, range };
  }

  async function api(request: Request, path: string, url: URL): Promise<Response> {
    if (path === "/api" && request.method === "GET") {
      return json({ name: "runlight", version: VERSION, api: API_VERSION, ...IMPLEMENTATION });
    }

    if (path === "/api/check" && request.method === "POST") {
      const given = bearer(request);
      const allowed =
        (cronSecret && given && constantTimeEqual(given, cronSecret)) || (await canRead(request)) === true;
      if (!allowed) return json({ error: "Unauthorized" }, 401);
      return json(await runlight.check());
    }

    if (request.method !== "GET") return json({ error: "Method not allowed" }, 405);

    const access = await canRead(request);
    if (access !== true) return denied(access);
    await runlight.init();

    if (path === "/api/sites") {
      return json({ sites: runlight.sites });
    }

    const site = await querySite(url);
    if (site instanceof Response) return site;

    if (path === "/api/icon") {
      const host = site.hostnames[0];
      const icon = await fetchIcon(host ? `https://${host}` : url.origin);
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
    const { query, range } = read;
    const rangeOut = { from: range.fromDate, to: range.toDate, interval: range.interval, timezone: site.timezone };

    if (path === "/api/stats") {
      const stats = await runlight.store.stats(query);
      const compare = url.searchParams.get("compare");
      const previous = compare === "false" ? undefined : await runlight.store.stats({ ...query, ...previousRange(range) });
      return json({ site: site.id, range: rangeOut, stats, previous });
    }

    if (path === "/api/series") {
      const points = await runlight.store.series(query, buckets(range, site.timezone));
      return json({ site: site.id, range: rangeOut, points });
    }

    if (path === "/api/rhythm") {
      const grid = Array.from({ length: 7 }, () => new Array<number>(24).fill(0));
      for (const { hour, visits } of await runlight.store.hourly(query)) {
        const [weekday, h] = localWeekdayHour(hour * 3_600_000, site.timezone);
        grid[weekday]![h]! += visits;
      }
      return json({ site: site.id, range: rangeOut, grid });
    }

    if (path === "/api/breakdown") {
      const dimension = url.searchParams.get("dimension") ?? "";
      if (!isDimension(dimension)) return json({ error: `Unknown dimension "${dimension}"` }, 400);
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get("limit")) || 10));
      const page = Math.max(1, Number(url.searchParams.get("page")) || 1);
      const rows = await runlight.store.breakdown(query, dimension, limit, (page - 1) * limit);
      return json({ site: site.id, range: rangeOut, dimension, rows });
    }

    return json({ error: "Not found" }, 404);
  }

  const handler: FetchHandler = async (request, context = {}) => {
    const url = new URL(request.url);
    if (base && url.pathname !== base && !url.pathname.startsWith(`${base}/`)) return json({ error: "Not found" }, 404);
    const path = url.pathname.slice(base.length) || "/";

    try {
      if (path === "/s.js" && request.method === "GET") {
        const etag = `"${TRACKER_HASH}"`;
        const headers = {
          "content-type": "application/javascript; charset=utf-8",
          "cache-control": "public, max-age=3600",
          etag,
        };
        if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers });
        return new Response(TRACKER, { headers });
      }

      if (path === `/assets/world.${WORLD_HASH}.json` && request.method === "GET") {
        return new Response(WORLD_JSON, {
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
        return new Response(DASHBOARD(base), {
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

  return { handler, GET: handler, POST: handler, OPTIONS: handler };
}
