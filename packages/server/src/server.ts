/**
 * The standalone server: Runlight's routes at the root of their own domain,
 * behind a sign-in, with sites managed in the dashboard and short links
 * answered on any domain pointed at it.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import { runlight, type Runlight, type RequestContext, type SqlStore, type GeoLookup } from "@runlight/sdk";
import { Accounts, SESSION_COOKIE, SESSION_MS, Throttle, type Role, type User } from "./auth.js";
import { AUTH_CSS, AUTH_JS, loginPage, setupLockedPage, setupPage } from "./pages.js";

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

const HTML = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'", "x-frame-options": "DENY", "referrer-policy": "same-origin" };

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

/**
 * Only a path on this server, so a sign-in can never send someone elsewhere.
 * Browsers drop tabs and newlines from a URL and read a backslash as a slash,
 * so "/\t/evil.example" would leave; anything with those is refused outright,
 * and what is left must resolve to this origin.
 */
function safeNext(value: string | null): string {
  if (!value || !value.startsWith("/") || /[\u0000-\u001f\u007f\\]/.test(value)) return "/";
  try {
    const url = new URL(value, "http://runlight.invalid");
    return url.origin === "http://runlight.invalid" ? `${url.pathname}${url.search}${url.hash}` : "/";
  } catch {
    return "/";
  }
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
    signIn: "/login",
    geoCredit: options.geoCredit ?? false,
    accounts: true,
    authorize: async (request) => {
      const auth = request.headers.get("authorization") ?? "";
      if (options.token && auth.toLowerCase().startsWith("bearer ") && equal(auth.slice(7).trim(), options.token)) return true;
      const user = await signedIn(request);
      // A viewer reads every site and changes nothing.
      return user ? (user.role === "viewer" ? "read" : true) : false;
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
      if (path === "/auth.js") return new Response(AUTH_JS, { headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600" } });
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

      if (path === "/api/account" || path === "/api/account/password" || path === "/api/people" || path.startsWith("/api/people/")) {
        return await accountsApi(request, path);
      }

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

  const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra } });
  const person = (u: User) => ({ id: u.id, email: u.email, role: u.role, createdAt: u.createdAt });
  /** A JSON body by its media type, which a cross-site form cannot send. */
  const body = async (request: Request): Promise<Record<string, unknown> | null> => {
    if ((request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() !== "application/json") return null;
    const parsed = (await request.json().catch(() => null)) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  };

  /** Your own account, and for owners, everyone else's. */
  async function accountsApi(request: Request, path: string): Promise<Response> {
    const user = await signedIn(request);
    if (!user) return reply({ error: "Sign in first" }, 401);
    if (path === "/api/account" && request.method === "GET") return reply({ account: person(user) });
    if (path === "/api/account/password" && request.method === "POST") {
      const input = await body(request);
      if (!input) return reply({ error: "Send JSON" }, 415);
      if (!(await accounts.signIn(user.email, String(input.current ?? "")))) return reply({ error: "Your current password is not right" }, 400);
      try {
        const updated = await accounts.setPassword(user.email, String(input.next ?? ""), now());
        // The new password ends every other sign-in; this browser gets a fresh one.
        return reply({ ok: true }, 200, { "set-cookie": sessionCookie(request, accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      } catch (error) {
        if (error instanceof RangeError) return reply({ error: error.message }, 400);
        throw error;
      }
    }
    if (user.role !== "owner") return reply({ error: "Only an owner can manage people" }, 403);
    const roleOf = (value: unknown): Role | null => (value === "owner" || value === "viewer" ? value : null);
    if (path === "/api/people" && request.method === "GET") return reply({ people: (await accounts.list()).map(person) });
    if (path === "/api/people" && request.method === "POST") {
      const input = await body(request);
      if (!input) return reply({ error: "Send JSON" }, 415);
      const role = roleOf(input.role);
      if (!role) return reply({ error: "Pick owner or viewer" }, 400);
      const email = String(input.email ?? "").trim().toLowerCase();
      if (await accounts.byEmail(email)) return reply({ error: `${email} already has an account` }, 409);
      const password = randomBytes(12).toString("base64url");
      try {
        const made = await accounts.setPassword(email, password, now(), role);
        // The only time the password is shown; the new person changes it after signing in.
        return reply({ person: person(made), password }, 201);
      } catch (error) {
        if (error instanceof RangeError) return reply({ error: error.message }, 400);
        throw error;
      }
    }
    const match = /^\/api\/people\/([a-f0-9]{24})$/.exec(path);
    if (match && (request.method === "PATCH" || request.method === "DELETE")) {
      try {
        if (request.method === "DELETE") {
          if (match[1] === user.id) return reply({ error: "You cannot remove yourself" }, 400);
          await accounts.remove(match[1]!);
          return reply({ ok: true });
        }
        const input = await body(request);
        if (!input) return reply({ error: "Send JSON" }, 415);
        const role = roleOf(input.role);
        if (!role) return reply({ error: "Pick owner or viewer" }, 400);
        return reply({ person: person(await accounts.setRole(match[1]!, role)) });
      } catch (error) {
        if (error instanceof RangeError) return reply({ error: error.message }, error.message === "Unknown account" ? 404 : 400);
        throw error;
      }
    }
    return reply({ error: "Not found" }, 404);
  }

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
