/**
 * The standalone server: Runlight's routes at the root of their own domain,
 * behind a sign-in, with sites managed in the dashboard and short links
 * answered on any domain pointed at it.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import { runlight, type Runlight, type RequestContext, type SqlStore, type GeoLookup } from "@runlight/sdk";
import { Accounts, SESSION_COOKIE, SESSION_MS, Throttle } from "./auth.js";
import { AUTH_CSS, loginPage, setupLockedPage, setupPage } from "./pages.js";

export interface ServerOptions {
  store: SqlStore;
  /** Signs sessions and encrypts stored mail keys. Keep it stable across restarts. */
  secret: string;
  /** Also accepted as a bearer token on the API, for scripts. */
  token?: string;
  /** Trust X-Forwarded-For and friends for the visitor's address. Default true. */
  trustProxy?: boolean;
  geo?: GeoLookup;
  /** Credit DB-IP in the dashboard, when its free data supplies locations. */
  geoCredit?: boolean;
  now?: () => number;
}

export type Handler = (request: Request, context?: RequestContext) => Promise<Response>;

export interface RunlightServer {
  runlight: Runlight;
  accounts: Accounts;
  handler: Handler;
  /** The one-time code that unlocks /setup while no account exists. */
  setupCode: string;
  /** Runs the scheduled work: salts, and email reports that are due. */
  check(): Promise<void>;
}

const HTML = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'", "x-frame-options": "DENY", "referrer-policy": "same-origin" };

function readCookie(request: Request, name: string): string {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return "";
}

function equal(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Only a path on this server, so a sign-in can never send someone elsewhere. */
function safeNext(value: string | null): string {
  return value && value.startsWith("/") && !value.startsWith("//") && !value.startsWith("/\\") ? value : "/";
}

function isSecure(request: Request): boolean {
  return new URL(request.url).protocol === "https:" || request.headers.get("x-forwarded-proto") === "https";
}

export function createServer(options: ServerOptions): RunlightServer {
  const now = options.now ?? Date.now;
  const accounts = new Accounts(options.store, options.secret);
  // Wrong passwords are counted twice. Per account and address, ten tries;
  // per account from anywhere, fifty, so a caller who invents a new address
  // for every try still cannot guess on and on. Addresses come from
  // forwarding headers a client can write, so they never stand alone.
  const perAddress = new Throttle(10);
  const perAccount = new Throttle(50);
  const setupCode = randomBytes(9).toString("base64url");
  let hasAccount = false;

  const signedIn = async (request: Request) => {
    const value = readCookie(request, SESSION_COOKIE);
    return value ? accounts.fromSession(decodeURIComponent(value), now()) : null;
  };

  const rl = runlight({
    store: options.store,
    managedSites: true,
    secret: options.secret,
    trustProxy: options.trustProxy ?? true,
    ...(options.geo ? { geo: options.geo } : {}),
    now,
  });

  const routes = rl.routes({
    basePath: "",
    // The cron route is never needed: the server runs the check itself.
    cronSecret: randomBytes(32).toString("hex"),
    signOut: "/logout",
    geoCredit: options.geoCredit ?? false,
    authorize: async (request) => {
      const auth = request.headers.get("authorization") ?? "";
      if (options.token && auth.toLowerCase().startsWith("bearer ") && equal(auth.slice(7).trim(), options.token)) return true;
      return Boolean(await signedIn(request));
    },
  });
  const links = rl.linkHandler();

  const sessionCookie = (request: Request, value: string, maxAge: number) =>
    `${SESSION_COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${isSecure(request) ? "; Secure" : ""}`;

  const accountExists = async () => (hasAccount ||= (await accounts.count()) > 0);

  const html = (body: string, status = 200, extra: Record<string, string> = {}) => new Response(body, { status, headers: { ...HTML, ...extra } });
  const redirect = (location: string, extra: Record<string, string> = {}) => new Response(null, { status: 303, headers: { location, "cache-control": "no-store", ...extra } });

  const handler: Handler = async (request, context = {}) => {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    try {
      // A domain pointed at this server for short links answers at its root.
      const linked = await rl.linkDomainResponse(request, context);
      if (linked) return linked;

      if (path === "/healthz") return new Response("ok", { headers: { "content-type": "text/plain", "cache-control": "no-store" } });
      if (path === "/auth.css") return new Response(AUTH_CSS, { headers: { "content-type": "text/css; charset=utf-8", "cache-control": "public, max-age=3600" } });
      if (/^\/go\/[^/]+\/?$/.test(path) && method === "GET") return await links(request, context);

      if (path === "/setup") {
        if (await accountExists()) return redirect("/login");
        if (method === "GET") {
          const code = url.searchParams.get("code") ?? "";
          return html(equal(code, setupCode) ? setupPage({ code }) : setupLockedPage(), equal(code, setupCode) ? 200 : 403);
        }
        if (method === "POST") {
          const form = new URLSearchParams(await request.text());
          const code = form.get("code") ?? "";
          if (!equal(code, setupCode)) return html(setupLockedPage(), 403);
          try {
            const user = await accounts.setPassword(form.get("email") ?? "", form.get("password") ?? "", now());
            hasAccount = true;
            return redirect("/", { "set-cookie": sessionCookie(request, accounts.sessionFor(user, now()), SESSION_MS / 1000) });
          } catch (error) {
            if (error instanceof RangeError) return html(setupPage({ code, error: error.message, email: form.get("email") ?? "" }), 400);
            throw error;
          }
        }
      }

      if (path === "/login") {
        if (!(await accountExists())) return html(setupLockedPage(), 403);
        if (method === "GET") return html(loginPage({ next: safeNext(url.searchParams.get("next")) }));
        if (method === "POST") {
          const form = new URLSearchParams(await request.text());
          const email = form.get("email") ?? "";
          const next = safeNext(form.get("next"));
          const account = email.trim().toLowerCase();
          const pair = `${account}\n${rl.clientIp(request, context) || "unknown"}`;
          if (perAddress.blocked(pair, now()) || perAccount.blocked(account, now())) {
            return html(loginPage({ error: "Too many tries. Wait fifteen minutes and try again.", email, next }), 429);
          }
          const user = await accounts.signIn(email, form.get("password") ?? "");
          if (!user) {
            perAddress.fail(pair, now());
            perAccount.fail(account, now());
            return html(loginPage({ error: "That email and password do not match an account.", email, next }), 401);
          }
          perAddress.clear(pair);
          return redirect(next, { "set-cookie": sessionCookie(request, accounts.sessionFor(user, now()), SESSION_MS / 1000) });
        }
      }

      if (path === "/logout") return redirect("/login", { "set-cookie": sessionCookie(request, "", 0) });

      // The dashboard page itself: straight to sign-in, or to setup on a new server.
      if (path === "/" && method === "GET" && !(await signedIn(request))) {
        if (!(await accountExists())) return html(setupLockedPage(), 403);
        return redirect(`/login${url.search ? `?next=${encodeURIComponent(`/${url.search}`)}` : ""}`);
      }

      return await routes.handler(request, context);
    } catch (error) {
      console.error("Runlight:", error);
      return new Response(JSON.stringify({ error: "Internal error" }), { status: 500, headers: { "content-type": "application/json" } });
    }
  };

  return {
    runlight: rl,
    accounts,
    handler,
    setupCode,
    async check() {
      await rl.check();
    },
  };
}
