/**
 * The standalone server: Runlight's routes at the root of their own domain,
 * behind a sign-in, with sites managed in the dashboard and short links
 * answered on any domain pointed at it.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import { DOMAIN_NAME, LINK_DOMAIN_CHECK, accountsWeb, coded, hostName, runlight, setupCode as newSetupCode, type Accounts, type Runlight, type RequestContext, type SqlStore, type GeoLookup } from "@runlight/sdk";

export interface ServerOptions {
  store: SqlStore;
  /** Signs sessions and encrypts saved keys, such as the mail service's and two-factor secrets. Keep it stable across restarts. */
  secret: string;
  /** Also accepted as a bearer token on the API, for scripts. */
  token?: string;
  /**
   * The dashboard's public address, such as https://stats.example.com. It can
   * never become a link domain, short links never answer on it, and emails
   * link to it whatever Host header a request carries.
   */
  url?: string;
  /** Trust X-Forwarded-For and friends for the visitor's address. Default true. */
  trustProxy?: boolean | "x-forwarded-for" | "x-real-ip" | "cf-connecting-ip";
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

function equal(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** The server's own pages, which answer as the server on every name it is reached at, a link domain too. */
const SERVER_PATHS = new Set(["/login", "/logout", "/setup", "/invite", "/healthz", "/auth.css", "/auth.js", "/api", "/mcp", "/s.js", "/pick.js", "/e", "/embed"]);

/**
 * The most names remembered as the server's own. The first ones stay and later ones are not learned, so
 * a server reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
 */
const MAX_OWN_HOSTS = 20;

export function createServer(options: ServerOptions): RunlightServer {
  const now = options.now ?? Date.now;
  const setupCode = newSetupCode();
  const publicUrl = options.url ? new URL(options.url) : null;
  const publicHost = publicUrl ? hostName(publicUrl.host) : null;

  /** The name a request came in on, read as link domains read it. */
  const hostOf = (request: Request) => hostName(((options.trustProxy ?? true) ? request.headers.get("x-forwarded-host") : null) ?? request.headers.get("host") ?? new URL(request.url).host);

  // The names the owner and admins signed in from, kept in the database, so a link domain can never be one of them
  // even when whoever adds it picks another Host header. Only they teach them, since anyone else could fill the list
  // with made-up names, and only real domain names. Names that are already link domains are left out.
  let ownHosts: Set<string> | null = null;
  const savedHosts = async () => {
    await rl.init();
    try {
      return JSON.parse((await options.store.setting("server-hosts")) ?? "[]") as string[];
    } catch {
      return [];
    }
  };
  const knownHosts = async () => (ownHosts ??= new Set(await savedHosts()));
  const learnHost = async (request: Request) => {
    const host = hostOf(request);
    const known = await knownHosts();
    if (!DOMAIN_NAME.test(host) || known.has(host) || known.size >= MAX_OWN_HOSTS) return;
    if ((await options.store.linkDomains()).some((d) => d.domain === host)) return;
    // Another copy of the server may have saved names since this one read them.
    for (const saved of await savedHosts()) known.add(saved);
    known.add(host);
    await options.store.setSetting("server-hosts", JSON.stringify([...known].slice(0, MAX_OWN_HOSTS)));
  };

  const rl = runlight({
    store: options.store,
    managedSites: true,
    secret: options.secret,
    trustProxy: options.trustProxy ?? true,
    ...(options.geo ? { geo: options.geo } : {}),
    now,
  });

  // Accounts, shared with apps that turn them on. The first one is made with the code the server prints at start,
  // and emails link to its public address, or else the first name the owner or an admin signed in from.
  const web = accountsWeb({
    runlight: rl,
    secret: options.secret,
    base: "",
    now,
    firstAccount: { code: setupCode },
    home: async () => publicUrl?.origin ?? [...(await knownHosts())].map((h) => `https://${h}`)[0] ?? null,
    forgot: "https://runlight.sh/docs/server/#forgotten-passwords",
  });

  const routes = rl.routes({
    basePath: "",
    // The cron route is never needed: the server runs the check itself.
    cronSecret: randomBytes(32).toString("hex"),
    signOut: "/logout",
    signIn: "/login",
    geoCredit: options.geoCredit ?? false,
    accounts: web,
    authorize: async (request) => {
      const auth = request.headers.get("authorization") ?? "";
      if (options.token && auth.toLowerCase().startsWith("bearer ") && equal(auth.slice(7).trim(), options.token)) return true;
      const access = await web.access(request);
      if (access === true) await learnHost(request);
      return access;
    },
    ...(publicUrl ? { origin: publicUrl.origin } : {}),
    ownHosts: knownHosts,
  });
  const links = rl.linkHandler();

  const handler: Handler = async (request, context = {}) => {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      // A domain pointed at this server for short links answers at its root, with links one segment deep. The
      // server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
      // signed in, so a link domain added on the dashboard's own name can always be removed again.
      const linkable = path === LINK_DOMAIN_CHECK || (/^\/[^/]*$/.test(path) && !SERVER_PATHS.has(path) && !(path === "/" && (await web.signedIn(request))));
      if (linkable && !(publicHost && hostOf(request) === publicHost)) {
        const linked = await rl.linkDomainResponse(request, context);
        if (linked) return linked;
      }
      if (path === "/healthz") return new Response("ok", { headers: { "content-type": "text/plain", "cache-control": "no-store" } });
      if (/^\/go\/[^/]+\/?$/.test(path) && request.method === "GET") return await links(request, context);
      // Everything else, the sign-in pages and People included, is the routes'.
      return await routes.handler(request, context);
    } catch (error) {
      console.error("Runlight:", error);
      return coded("Internal error", "internal", 500);
    }
  };

  return {
    runlight: rl,
    accounts: web.accounts,
    handler,
    setupCode,
    async check() {
      await rl.check();
    },
  };
}
