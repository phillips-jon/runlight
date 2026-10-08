/**
 * The standalone server: Runlight's routes at the root of their own domain,
 * behind a sign-in, with sites managed in the dashboard and short links
 * answered on any domain pointed at it.
 */
import { randomBytes, timingSafeEqual } from "node:crypto";
import { DOMAIN_NAME, LINK_DOMAIN_CHECK, coded, hostName, runlight, type Runlight, type RequestContext, type SqlStore, type GeoLookup } from "@runlight/sdk";
import { AccountError, Accounts, SESSION_COOKIE, SESSION_MS, Throttle, otpauthUri, type Invite, type Role, type User } from "./auth.js";
import { AUTH_CSS, AUTH_JS, codePage, inviteGonePage, invitePage, loginPage, setupLockedPage, setupPage } from "./pages.js";

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

/** The server's own pages, which answer as the server on every name it is reached at, a link domain too. */
const SERVER_PATHS = new Set(["/login", "/logout", "/setup", "/invite", "/healthz", "/auth.css", "/auth.js", "/api", "/mcp", "/s.js", "/pick.js", "/e"]);

/**
 * The most names remembered as the server's own. The first ones stay and later ones are not learned, so
 * a server reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
 */
const MAX_OWN_HOSTS = 20;

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
  // Each try counts before the password is checked, and a right one is taken back.
  const perAddress = new Throttle(10);
  const perAccount = new Throttle(50);
  // Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
  // Password re-checks in Account: ten.
  const codeTries = new Throttle(5);
  const confirmTries = new Throttle(5);
  const rechecks = new Throttle(10);
  // When each account was last sent a sign-in link, at most one a minute.
  const linkSent = new Map<string, number>();
  const DEVICE_COOKIE = "runlight_device";
  const setupCode = randomBytes(9).toString("base64url");
  let hasAccount = false;
  const publicUrl = options.url ? new URL(options.url) : null;
  const publicHost = publicUrl ? hostName(publicUrl.host) : null;

  /** The name a request came in on, read as link domains read it. */
  const hostOf = (request: Request) => hostName(((options.trustProxy ?? true) ? request.headers.get("x-forwarded-host") : null) ?? request.headers.get("host") ?? new URL(request.url).host);

  // The names owners signed in from, kept in the database, so a link domain can never be one of them even when
  // whoever adds it picks another Host header. Only owners teach them, since anyone else could fill the list
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

  // Who made each token, kept beside it as a setting, so removing someone, or making them a viewer, deletes the
  // tokens they made and the apps they connected. Tokens made with RUNLIGHT_TOKEN, or before this was kept, have no maker.
  const MADE_BY = "token-by:";
  const dropTokensOf = async (id: string) => {
    for (const { key, value } of await options.store.settingsStartingWith(MADE_BY)) {
      if (value !== id) continue;
      await options.store.deleteToken(key.slice(MADE_BY.length));
      await options.store.setSetting(key, null);
    }
  };

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
      if (user?.role === "owner") await learnHost(request);
      // A viewer reads every site and changes nothing.
      return user ? (user.role === "viewer" ? "read" : true) : false;
    },
    ...(publicUrl ? { origin: publicUrl.origin } : {}),
    ownHosts: knownHosts,
    accountOf: async (request) => (await signedIn(request))?.id ?? null,
    // Only an owner makes tokens; one removed or made a viewer since allowing an app gets none for it.
    tokenMade: async (token, by) => {
      if ((await accounts.byId(by))?.role !== "owner") return false;
      await options.store.setSetting(`${MADE_BY}${token.id}`, by);
      return true;
    },
  });
  const links = rl.linkHandler();

  const sessionCookie = (request: Request, value: string, maxAge: number) =>
    `${SESSION_COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${isSecure(request) ? "; Secure" : ""}`;

  const accountExists = async () => (hasAccount ||= (await accounts.count()) > 0);

  /** The redirect after signing in: a session, and the mark that this browser has signed in to the account. */
  const signedInTo = (request: Request, user: User, next: string) => {
    const headers = new Headers({ location: next, "cache-control": "no-store" });
    headers.append("set-cookie", sessionCookie(request, accounts.sessionFor(user, now()), SESSION_MS / 1000));
    headers.append("set-cookie", `${DEVICE_COOKIE}=${encodeURIComponent(accounts.deviceFor(user))}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${365 * 86_400}${isSecure(request) ? "; Secure" : ""}`);
    return new Response(null, { status: 303, headers });
  };

  const html = (body: string, status = 200, extra: Record<string, string> = {}) => new Response(body, { status, headers: { ...HTML, ...extra } });
  const redirect = (location: string, extra: Record<string, string> = {}) => new Response(null, { status: 303, headers: { location, "cache-control": "no-store", ...extra } });

  const handler: Handler = async (request, context = {}) => {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    try {
      // A domain pointed at this server for short links answers at its root, with links one segment deep. The
      // server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
      // signed in, so a link domain added on the dashboard's own name can always be removed again.
      const linkable = path === LINK_DOMAIN_CHECK || (/^\/[^/]*$/.test(path) && !SERVER_PATHS.has(path) && !(path === "/" && (await signedIn(request))));
      if (linkable && !(publicHost && hostOf(request) === publicHost)) {
        const linked = await rl.linkDomainResponse(request, context);
        if (linked) return linked;
      }

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
          // Asked twice, since a typo here would lock the first owner out.
          if ((form.get("password") ?? "") !== (form.get("again") ?? "")) {
            return html(setupPage({ code, error: "The two passwords are not the same.", email: form.get("email") ?? "" }), 400);
          }
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
          const password = form.get("password") ?? "";
          const next = safeNext(form.get("next"));
          const account = email.trim().toLowerCase();
          const pair = `${account}\n${rl.clientIp(request, context) || "unknown"}`;
          const tooMany = () => html(loginPage({ error: "Too many tries. Wait fifteen minutes and try again.", email, next }), 429);
          if (!perAddress.take(pair, now())) return tooMany();
          // A browser that signed in to the account before is never held up by others' failures.
          const known = await accounts.byEmail(account);
          const trusted = Boolean(known && accounts.trustsDevice(readCookie(request, DEVICE_COOKIE), known));
          const over = !trusted && !perAccount.take(account, now());
          // Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
          // addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
          // where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
          if (over && !known?.twoFactor) {
            if (!(await rl.mailSettings())) return tooMany();
            const user = await accounts.signIn(email, password);
            if (user) void sendLink(user, next).catch((error) => console.error("Runlight: could not send a sign-in link", error));
            return html(loginPage({ error: "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.", email, next }), 429);
          }
          const user = await accounts.signIn(email, password);
          if (!user) {
            if (over && known) return html(codePage({ pending: accounts.decoyFor(known, now()), next }));
            return html(loginPage({ error: "That email and password do not match an account.", email, next }), 401);
          }
          perAddress.clear(pair);
          if (!over && !trusted) perAccount.forgive(account);
          // With two-factor on, the password only earns the second step.
          if (user.twoFactor) return html(codePage({ pending: accounts.pendingFor(user, now()), next }));
          return signedInTo(request, user, next);
        }
      }

      // The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
      if (path === "/login/link" && method === "GET") {
        const next = safeNext(url.searchParams.get("next"));
        const user = await accounts.fromLink(url.searchParams.get("ticket") ?? "", now());
        if (!user) return html(loginPage({ error: "That sign-in link has run out. Sign in again.", next }), 410);
        if (user.twoFactor) return html(codePage({ pending: accounts.pendingFor(user, now()), next }));
        return signedInTo(request, user, next);
      }

      if (path === "/login/code" && method === "POST") {
        const form = new URLSearchParams(await request.text());
        const next = safeNext(form.get("next"));
        const pending = await accounts.fromPending(form.get("pending") ?? "", now());
        if (!pending) return redirect(`/login?next=${encodeURIComponent(next)}`);
        const { user, real } = pending;
        // Counted before the check, so a burst cannot get past five.
        if (!codeTries.take(user.id, now())) return html(codePage({ pending: form.get("pending") ?? "", next, error: "Too many tries. Wait fifteen minutes and try again." }), 429);
        if (!real || !(await accounts.checkSecondFactor(user.id, form.get("code") ?? "", now()))) {
          return html(codePage({ pending: form.get("pending") ?? "", next, error: "That code is not right. Check the time on your phone, or use a recovery code." }), 401);
        }
        codeTries.clear(user.id);
        return signedInTo(request, user, next);
      }

      if (path === "/logout") return redirect("/login", { "set-cookie": sessionCookie(request, "", 0) });

      if (path === "/invite") {
        if (method === "GET") {
          const code = url.searchParams.get("code") ?? "";
          const invite = await accounts.inviteByCode(code, now());
          return invite ? html(invitePage({ code, email: invite.email, role: invite.role, host: url.host })) : html(inviteGonePage(), 410);
        }
        if (method === "POST") {
          const form = new URLSearchParams(await request.text());
          const code = form.get("code") ?? "";
          const invite = await accounts.inviteByCode(code, now());
          if (!invite) return html(inviteGonePage(), 410);
          const again = (error: string) => html(invitePage({ code, email: invite.email, role: invite.role, host: url.host, error }), 400);
          if ((form.get("password") ?? "") !== (form.get("again") ?? "")) return again("The two passwords are not the same.");
          try {
            const user = await accounts.acceptInvite(code, form.get("password") ?? "", now());
            hasAccount = true;
            return redirect("/", { "set-cookie": sessionCookie(request, accounts.sessionFor(user, now()), SESSION_MS / 1000) });
          } catch (error) {
            if (error instanceof RangeError) return again(error.message);
            throw error;
          }
        }
      }

      if (path === "/api/account" || path.startsWith("/api/account/") || path === "/api/people" || path.startsWith("/api/people/") || path.startsWith("/api/invites/")) {
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
      return coded("Internal error", "internal", 500);
    }
  };

  const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra } });
  const person = (u: User) => ({ id: u.id, email: u.email, role: u.role, createdAt: u.createdAt, twoFactor: u.twoFactor, recoveryLeft: u.recoveryLeft });
  /** A JSON body by its media type, which a cross-site form cannot send. */
  const body = async (request: Request): Promise<Record<string, unknown> | null> => {
    if ((request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() !== "application/json") return null;
    const parsed = (await request.json().catch(() => null)) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  };

  const inviteView = (i: Invite) => ({ id: i.id, email: i.email, role: i.role, invitedBy: i.invitedBy, createdAt: i.createdAt, expiresAt: i.expiresAt });

  /**
   * Emails an invite through the mail service when there is one. The link
   * always comes back too, for the owner to pass on another way.
   */
  async function sendInvite(
    request: Request,
    invite: Invite,
    code: string,
  ): Promise<{ link: string; emailed: boolean; mailError?: string; mailCode?: string; mailParams?: Record<string, string> }> {
    const home = publicUrl ?? new URL(request.url);
    const link = `${home.origin}/invite?code=${code}`;
    const host = home.host;
    const what = invite.role === "owner" ? "an owner, who can change settings and manage people" : "a viewer, who can read every site's stats";
    const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
    if (!(await rl.mailSettings())) return { link, emailed: false };
    try {
      await rl.sendMail({
        to: invite.email,
        subject: `${invite.invitedBy} invited you to Runlight`,
        text: `${invite.invitedBy} invited you to the Runlight at ${host} as ${what}.\n\nChoose a password to join:\n${link}\n\nThe link works for seven days.\n`,
        html: `<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>${esc(invite.invitedBy)} invited you to the Runlight at ${esc(host)} as ${what}.</p><p><a href="${esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Choose a password and join</a></p><p style="color:#6b7280;font-size:13px">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>`,
      });
      return { link, emailed: true };
    } catch (error) {
      // The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
      const failed = error as Error & { code?: string; params?: Record<string, string> };
      return { link, emailed: false, mailError: failed.message, ...(typeof failed.code === "string" ? { mailCode: failed.code, mailParams: failed.params ?? {} } : {}) };
    }
  }

  /**
   * Emails a sign-in link to an account held up by others' failed tries, at
   * most once a minute. Only to the server's own address: its public one, or
   * the first name an owner signed in from, never the Host of the request.
   */
  async function sendLink(user: User, next: string): Promise<void> {
    const host = publicUrl?.origin ?? [...(await knownHosts())].map((h) => `https://${h}`)[0];
    if (!host || now() - (linkSent.get(user.id) ?? 0) < 60_000) return;
    linkSent.set(user.id, now());
    const link = `${host}/login/link?${new URLSearchParams({ ticket: accounts.linkFor(user, now()), next })}`;
    const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
    await rl.sendMail({
      to: user.email,
      subject: "Sign in to Runlight",
      text: `Someone, most likely you, signed in to Runlight at ${new URL(host).host} with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n${link}\n\nIf this was not you, change your password, since someone knows it.\n`,
      html: `<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>Someone, most likely you, signed in to Runlight at ${esc(new URL(host).host)} with your password while your account was held up by too many failed tries.</p><p><a href="${esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Sign in</a></p><p style="color:#6b7280;font-size:13px">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>`,
    });
  }

  /** Your own account, and for owners, everyone else's. */
  async function accountsApi(request: Request, path: string): Promise<Response> {
    const user = await signedIn(request);
    if (!user) return coded("Sign in first", "sign_in", 401);
    // Writes must be JSON, which a form on another page cannot send, even those with no body.
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (request.method === "POST" && type !== "application/json") return coded("Send JSON", "send_json", 415);
    if (path === "/api/account" && request.method === "GET") return reply({ account: person(user) });
    if (path === "/api/account/password" && request.method === "POST") {
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      if (!rechecks.take(user.id, now())) return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
      if (!(await accounts.signIn(user.email, String(input.current ?? "")))) return coded("Your current password is not right", "password_current_wrong", 400);
      rechecks.forgive(user.id);
      try {
        const updated = await accounts.setPassword(user.email, String(input.next ?? ""), now());
        // The new password ends every other sign-in; this browser gets a fresh one.
        return reply({ ok: true }, 200, { "set-cookie": sessionCookie(request, accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      } catch (error) {
        if (error instanceof AccountError) return coded(error.message, error.code, 400, error.params);
        throw error;
      }
    }
    // Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
    // Each change asks for the password again, so a browser left signed in cannot quietly change it.
    if (path.startsWith("/api/account/2fa") && request.method === "POST") {
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const action = path.slice("/api/account/2fa".length);
      // Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
      if (action === "/confirm") {
        if (!confirmTries.take(user.id, now())) {
          await accounts.cancelTwoFactorSetup(user.id);
          return coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429);
        }
        const codes = await accounts.confirmTwoFactor(user.id, String(input.code ?? "").replace(/\s/g, ""), now());
        if (!codes) return coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400);
        confirmTries.clear(user.id);
        // Turning it on signs out every other browser; this one gets a new session.
        const updated = (await accounts.byId(user.id))!;
        return reply({ recovery: codes }, 200, { "set-cookie": sessionCookie(request, accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      }
      if (!rechecks.take(user.id, now())) return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
      if (!(await accounts.signIn(user.email, String(input.password ?? "")))) return coded("Your password is not right", "password_wrong", 400);
      rechecks.forgive(user.id);
      if (action === "/start") {
        confirmTries.clear(user.id);
        const secret = await accounts.startTwoFactor(user.id);
        return reply({ secret, uri: otpauthUri(secret, user.email, new URL(request.url).host) });
      }
      if (action === "/recovery") {
        if (!user.twoFactor) return coded("Turn on two-factor sign-in first", "twofactor_off", 400);
        return reply({ recovery: await accounts.newRecoveryCodes(user.id) });
      }
      if (action === "/disable") {
        await accounts.disableTwoFactor(user.id);
        // Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
        const updated = (await accounts.byId(user.id))!;
        return reply({ ok: true }, 200, { "set-cookie": sessionCookie(request, accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      }
      return coded("Not found", "not_found", 404);
    }
    if (user.role !== "owner") return coded("Only an owner can manage people", "people_owner", 403);
    // An owner can turn off someone else's two-factor, for a coworker who lost both phone and recovery codes.
    // It asks for the owner's password like every other two-factor change, and their own goes through Account.
    const reset = /^\/api\/people\/([a-f0-9]{24})\/2fa$/.exec(path);
    if (reset && request.method === "DELETE") {
      if (reset[1] === user.id) return coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400);
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      if (!rechecks.take(user.id, now())) return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
      if (!(await accounts.signIn(user.email, String(input.password ?? "")))) return coded("Your password is not right", "password_wrong", 400);
      rechecks.forgive(user.id);
      if (!(await accounts.byId(reset[1]!))) return coded("Unknown account", "unknown_account", 404);
      await accounts.disableTwoFactor(reset[1]!);
      return reply({ ok: true });
    }
    const roleOf = (value: unknown): Role | null => (value === "owner" || value === "viewer" ? value : null);
    if (path === "/api/people" && request.method === "GET") {
      return reply({ people: (await accounts.list()).map(person), invites: (await accounts.invites(now())).map(inviteView) });
    }
    if (path === "/api/people" && request.method === "POST") {
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const role = roleOf(input.role);
      if (!role) return coded("Pick owner or viewer", "role_needed", 400);
      const email = String(input.email ?? "").trim().toLowerCase();
      if (await accounts.byEmail(email)) return coded(`${email} already has an account`, "account_exists", 409, { email });
      try {
        const { invite, code } = await accounts.invite(email, role, user.email, now());
        return reply({ invite: inviteView(invite), ...(await sendInvite(request, invite, code)) }, 201);
      } catch (error) {
        if (error instanceof AccountError) return coded(error.message, error.code, 400, error.params);
        throw error;
      }
    }
    const inviteMatch = /^\/api\/invites\/([a-f0-9]{24})(\/resend)?$/.exec(path);
    if (inviteMatch && request.method === "DELETE" && !inviteMatch[2]) {
      return (await accounts.cancelInvite(inviteMatch[1]!)) ? reply({ ok: true }) : coded("Unknown invite", "unknown_invite", 404);
    }
    if (inviteMatch && request.method === "POST" && inviteMatch[2]) {
      const old = (await accounts.invites(now())).find((i) => i.id === inviteMatch[1]);
      if (!old) return coded("Unknown invite", "unknown_invite", 404);
      // A new link replaces the old one, which stops working.
      const { invite, code } = await accounts.invite(old.email, old.role, user.email, now());
      return reply({ invite: inviteView(invite), ...(await sendInvite(request, invite, code)) });
    }
    const match = /^\/api\/people\/([a-f0-9]{24})$/.exec(path);
    if (match && (request.method === "PATCH" || request.method === "DELETE")) {
      try {
        if (request.method === "DELETE") {
          if (match[1] === user.id) return coded("You cannot remove yourself", "remove_self", 400);
          await accounts.remove(match[1]!);
          // The tokens they made, and the apps they connected, stop working with them.
          await dropTokensOf(match[1]!);
          return reply({ ok: true });
        }
        const input = await body(request);
        if (!input) return coded("Send JSON", "send_json", 415);
        const role = roleOf(input.role);
        if (!role) return coded("Pick owner or viewer", "role_needed", 400);
        const changed = await accounts.setRole(match[1]!, role);
        // A viewer changes nothing, so the tokens they made as an owner go too.
        if (role === "viewer") await dropTokensOf(match[1]!);
        return reply({ person: person(changed) });
      } catch (error) {
        if (error instanceof AccountError) return coded(error.message, error.code, error.code === "unknown_account" ? 404 : 400, error.params);
        throw error;
      }
    }
    return coded("Not found", "not_found", 404);
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
