/**
 * Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
 * the base path the routes answer at. The standalone server and an app with routes({ accounts: true }) share it.
 */
import type { Runlight, RequestContext } from "../runlight.js";
import type { TokenRow } from "../store.js";
import { AccountError, Accounts, SESSION_COOKIE, SESSION_MS, Throttle, otpauthUri, type Invite, type Role, type User } from "./auth.js";
import { randomBytes, base64url, sameText } from "./crypto.js";
import { AUTH_CSS, AUTH_JS, codePage, inviteGonePage, invitePage, loginPage, roleText, setupLockedPage, setupNeedsTokenPage, setupPage } from "./pages.js";

/** Who may create the first account: the server's printed one-time code, the app's token, or anyone (development). */
export type FirstAccount = { code: string } | { token: string } | "open" | "locked";

export interface AccountsWebOptions {
  runlight: Runlight;
  /** Signs sessions and seals two-factor secrets. Keep it stable across restarts. */
  secret: string;
  /** The path the routes answer under: "" on the standalone server, "/runlight" in an app. */
  base: string;
  now: () => number;
  firstAccount: FirstAccount;
  /** The address emails link to: the install's public one when known. Without it, a locked account gets no link. */
  home?: () => Promise<string | null>;
  /** Where the sign-in page sends someone who forgot their password. */
  forgot: string;
}

export interface AccountsWeb {
  accounts: Accounts;
  signedIn(request: Request): Promise<User | null>;
  /** What a signed-in person may do: everything (owner and admin), "member", "read" (viewer), or nothing. */
  access(request: Request): Promise<boolean | "member" | "read">;
  accountOf(request: Request): Promise<string | null>;
  tokenMade(token: TokenRow, by: string): Promise<boolean>;
  hasAccount(): Promise<boolean>;
  /** Answers an account page or API request at a path under the base, or null for anything else. */
  handle(request: Request, path: string, context?: RequestContext): Promise<Response | null>;
}

const HTML = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "content-security-policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  "x-frame-options": "DENY",
  "referrer-policy": "same-origin",
};

const DEVICE_COOKIE = "runlight_device";
/** Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them. */
const MADE_BY = "token-by:";

function readCookie(request: Request, name: string): string {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return "";
}

function isSecure(request: Request): boolean {
  return new URL(request.url).protocol === "https:" || request.headers.get("x-forwarded-proto") === "https";
}

/** An error the dashboard words in its own language, as routes.ts sends them. */
const coded = (error: string, code: string, status: number, params?: Record<string, string>) =>
  new Response(JSON.stringify({ error, code, ...(params ? { params } : {}) }), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" } });

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export function accountsWeb(options: AccountsWebOptions): AccountsWeb {
  const { runlight: rl, base, now } = options;
  const store = rl.store;
  const accounts = new Accounts(store, options.secret);
  const cookiePath = base || "/";
  const home = `${base}/`;
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
  let existing = false;
  const hasAccount = async () => (existing ||= (await accounts.count()) > 0);

  /**
   * Only a path on this install, so a sign-in can never send someone elsewhere.
   * Browsers drop tabs and newlines from a URL and read a backslash as a slash,
   * so "/\t/evil.example" would leave; anything with those is refused outright,
   * and what is left must resolve to this origin.
   */
  const safeNext = (value: string | null): string => {
    if (!value || !value.startsWith("/") || /[\u0000-\u001f\u007f\\]/.test(value)) return home;
    try {
      const url = new URL(value, "http://runlight.invalid");
      return url.origin === "http://runlight.invalid" ? `${url.pathname}${url.search}${url.hash}` : home;
    } catch {
      return home;
    }
  };

  const signedIn = async (request: Request) => {
    const value = readCookie(request, SESSION_COOKIE);
    return value ? accounts.fromSession(decodeURIComponent(value), now()) : null;
  };

  const dropTokensOf = async (id: string) => {
    for (const { key, value } of await store.settingsStartingWith(MADE_BY)) {
      if (value !== id) continue;
      await store.deleteToken(key.slice(MADE_BY.length));
      await store.setSetting(key, null);
    }
  };

  const sessionCookie = (request: Request, value: string, maxAge: number) =>
    `${SESSION_COOKIE}=${encodeURIComponent(value)}; Path=${cookiePath}; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${isSecure(request) ? "; Secure" : ""}`;

  /** The redirect after signing in: a session, and the mark that this browser has signed in to the account. */
  const signedInTo = async (request: Request, user: User, next: string) => {
    const headers = new Headers({ location: next, "cache-control": "no-store" });
    headers.append("set-cookie", sessionCookie(request, await accounts.sessionFor(user, now()), SESSION_MS / 1000));
    headers.append("set-cookie", `${DEVICE_COOKIE}=${encodeURIComponent(await accounts.deviceFor(user))}; Path=${cookiePath}; HttpOnly; SameSite=Lax; Max-Age=${365 * 86_400}${isSecure(request) ? "; Secure" : ""}`);
    return new Response(null, { status: 303, headers });
  };

  const html = (body: string, status = 200, extra: Record<string, string> = {}) => new Response(body, { status, headers: { ...HTML, ...extra } });
  const redirect = (location: string, extra: Record<string, string> = {}) => new Response(null, { status: 303, headers: { location, "cache-control": "no-store", ...extra } });
  const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra } });
  const person = (u: User) => ({ id: u.id, email: u.email, role: u.role, createdAt: u.createdAt, twoFactor: u.twoFactor, recoveryLeft: u.recoveryLeft });
  const inviteView = (i: Invite) => ({ id: i.id, email: i.email, role: i.role, invitedBy: i.invitedBy, createdAt: i.createdAt, expiresAt: i.expiresAt });
  /** A JSON body by its media type, which a cross-site form cannot send. */
  const body = async (request: Request): Promise<Record<string, unknown> | null> => {
    if ((request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase() !== "application/json") return null;
    const parsed = (await request.json().catch(() => null)) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  };

  /** The first account's gate: what the setup form must carry, or why there is no form. */
  const first = options.firstAccount;
  const setupOk = (given: string) => {
    if (first === "open") return true;
    if (first === "locked") return false;
    return sameText(given, "code" in first ? first.code : first.token);
  };
  const setupLocked = () => html(first === "locked" ? setupNeedsTokenPage(base) : setupLockedPage(base), 403);
  const asksForToken = typeof first === "object" && "token" in first;

  /**
   * Emails an invite through the mail service when there is one. The link
   * always comes back too, for the inviter to pass on another way.
   */
  async function sendInvite(request: Request, invite: Invite, code: string) {
    const origin = (await options.home?.()) ?? new URL(request.url).origin;
    const link = `${origin}${base}/invite?code=${code}`;
    const host = new URL(origin).host;
    const what = roleText(invite.role);
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
   * most once a minute. Only to the install's own address, never the Host of
   * the request, so without one known there is no link.
   */
  async function sendLink(user: User, next: string): Promise<boolean> {
    const origin = await options.home?.();
    if (!origin) return false;
    if (now() - (linkSent.get(user.id) ?? 0) < 60_000) return true;
    linkSent.set(user.id, now());
    const link = `${origin}${base}/login/link?${new URLSearchParams({ ticket: await accounts.linkFor(user, now()), next })}`;
    const host = new URL(origin).host;
    await rl.sendMail({
      to: user.email,
      subject: "Sign in to Runlight",
      text: `Someone, most likely you, signed in to Runlight at ${host} with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n${link}\n\nIf this was not you, change your password, since someone knows it.\n`,
      html: `<div style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px"><p>Someone, most likely you, signed in to Runlight at ${esc(host)} with your password while your account was held up by too many failed tries.</p><p><a href="${esc(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Sign in</a></p><p style="color:#6b7280;font-size:13px">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>`,
    });
    return true;
  }

  async function pages(request: Request, path: string, context: RequestContext): Promise<Response | null> {
    const url = new URL(request.url);
    const method = request.method;
    if (path === "/auth.css") return new Response(AUTH_CSS, { headers: { "content-type": "text/css; charset=utf-8", "cache-control": "public, max-age=3600" } });
    if (path === "/auth.js") return new Response(AUTH_JS, { headers: { "content-type": "application/javascript; charset=utf-8", "cache-control": "public, max-age=3600" } });

    if (path === "/setup") {
      if (await hasAccount()) return redirect(`${base}/login`);
      if (method === "GET") {
        const code = url.searchParams.get("code") ?? "";
        if (first === "locked") return setupLocked();
        // The app's token is typed in; the server's code comes in the link it printed.
        if (asksForToken || first === "open") return html(setupPage(base, { code: "", askCode: asksForToken }));
        return setupOk(code) ? html(setupPage(base, { code })) : setupLocked();
      }
      if (method === "POST") {
        const form = new URLSearchParams(await request.text());
        const code = form.get("code") ?? "";
        if (!setupOk(code)) {
          if (asksForToken) return html(setupPage(base, { code: "", askCode: true, error: "That is not this app's RUNLIGHT_TOKEN.", email: form.get("email") ?? "" }), 403);
          return setupLocked();
        }
        // Asked twice, since a typo here would lock the first owner out.
        if ((form.get("password") ?? "") !== (form.get("again") ?? "")) {
          return html(setupPage(base, { code: asksForToken ? "" : code, askCode: asksForToken, error: "The two passwords are not the same.", email: form.get("email") ?? "" }), 400);
        }
        try {
          const user = await accounts.setPassword(form.get("email") ?? "", form.get("password") ?? "", now());
          existing = true;
          return redirect(home, { "set-cookie": sessionCookie(request, await accounts.sessionFor(user, now()), SESSION_MS / 1000) });
        } catch (error) {
          if (error instanceof RangeError) return html(setupPage(base, { code: asksForToken ? "" : code, askCode: asksForToken, error: error.message, email: form.get("email") ?? "" }), 400);
          throw error;
        }
      }
    }

    if (path === "/login") {
      if (!(await hasAccount())) return first === "locked" ? setupLocked() : first === "open" || asksForToken ? redirect(`${base}/setup`) : setupLocked();
      if (method === "GET") return html(loginPage(base, { next: safeNext(url.searchParams.get("next")), forgot: options.forgot }));
      if (method === "POST") {
        const form = new URLSearchParams(await request.text());
        const email = form.get("email") ?? "";
        const password = form.get("password") ?? "";
        const next = safeNext(form.get("next"));
        const account = email.trim().toLowerCase();
        const pair = `${account}\n${rl.clientIp(request, context) || "unknown"}`;
        const login = (opts: { error?: string; email?: string }) => loginPage(base, { ...opts, next, forgot: options.forgot });
        const tooMany = () => html(login({ error: "Too many tries. Wait fifteen minutes and try again.", email }), 429);
        if (!(await perAddress.take(pair, now()))) return tooMany();
        // A browser that signed in to the account before is never held up by others' failures.
        const known = await accounts.byEmail(account);
        const trusted = Boolean(known && (await accounts.trustsDevice(readCookie(request, DEVICE_COOKIE), known)));
        const over = !trusted && !(await perAccount.take(account, now()));
        // Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        // addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        // where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if (over && !known?.twoFactor) {
          if (!(await rl.mailSettings()) || !(await options.home?.())) return tooMany();
          const user = await accounts.signIn(email, password);
          if (user) void sendLink(user, next).catch((error) => console.error("Runlight: could not send a sign-in link", error));
          return html(login({ error: "Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.", email }), 429);
        }
        const user = await accounts.signIn(email, password);
        if (!user) {
          if (over && known) return html(codePage(base, { pending: await accounts.decoyFor(known, now()), next }));
          return html(login({ error: "That email and password do not match an account.", email }), 401);
        }
        await perAddress.clear(pair);
        if (!over && !trusted) await perAccount.forgive(account);
        // With two-factor on, the password only earns the second step.
        if (user.twoFactor) return html(codePage(base, { pending: await accounts.pendingFor(user, now()), next }));
        return signedInTo(request, user, next);
      }
    }

    // The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
    if (path === "/login/link" && method === "GET") {
      const next = safeNext(url.searchParams.get("next"));
      const user = await accounts.fromLink(url.searchParams.get("ticket") ?? "", now());
      if (!user) return html(loginPage(base, { error: "That sign-in link has run out. Sign in again.", next, forgot: options.forgot }), 410);
      if (user.twoFactor) return html(codePage(base, { pending: await accounts.pendingFor(user, now()), next }));
      return signedInTo(request, user, next);
    }

    if (path === "/login/code" && method === "POST") {
      const form = new URLSearchParams(await request.text());
      const next = safeNext(form.get("next"));
      const pending = await accounts.fromPending(form.get("pending") ?? "", now());
      if (!pending) return redirect(`${base}/login?next=${encodeURIComponent(next)}`);
      const { user, real } = pending;
      // Counted before the check, so a burst cannot get past five.
      if (!(await codeTries.take(user.id, now()))) return html(codePage(base, { pending: form.get("pending") ?? "", next, error: "Too many tries. Wait fifteen minutes and try again." }), 429);
      if (!real || !(await accounts.checkSecondFactor(user.id, form.get("code") ?? "", now()))) {
        return html(codePage(base, { pending: form.get("pending") ?? "", next, error: "That code is not right. Check the time on your phone, or use a recovery code." }), 401);
      }
      await codeTries.clear(user.id);
      return signedInTo(request, user, next);
    }

    if (path === "/logout") return redirect(`${base}/login`, { "set-cookie": sessionCookie(request, "", 0) });

    if (path === "/invite") {
      if (method === "GET") {
        const code = url.searchParams.get("code") ?? "";
        const invite = await accounts.inviteByCode(code, now());
        return invite ? html(invitePage(base, { code, email: invite.email, role: invite.role, host: url.host })) : html(inviteGonePage(base), 410);
      }
      if (method === "POST") {
        const form = new URLSearchParams(await request.text());
        const code = form.get("code") ?? "";
        const invite = await accounts.inviteByCode(code, now());
        if (!invite) return html(inviteGonePage(base), 410);
        const again = (error: string) => html(invitePage(base, { code, email: invite.email, role: invite.role, host: url.host, error }), 400);
        if ((form.get("password") ?? "") !== (form.get("again") ?? "")) return again("The two passwords are not the same.");
        try {
          const user = await accounts.acceptInvite(code, form.get("password") ?? "", now());
          existing = true;
          return redirect(home, { "set-cookie": sessionCookie(request, await accounts.sessionFor(user, now()), SESSION_MS / 1000) });
        } catch (error) {
          if (error instanceof RangeError) return again(error.message);
          throw error;
        }
      }
    }
    return null;
  }

  /** Your own account, and for the owner and admins, everyone else's. */
  async function api(request: Request, path: string): Promise<Response> {
    const user = await signedIn(request);
    if (!user) return coded("Sign in first", "sign_in", 401);
    // Writes must be JSON, which a form on another page cannot send, even those with no body.
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (request.method === "POST" && type !== "application/json") return coded("Send JSON", "send_json", 415);
    if (path === "/api/account" && request.method === "GET") return reply({ account: person(user) });
    const recheck = async (input: Record<string, unknown>, field: string, wrong: [string, string]): Promise<Response | null> => {
      if (!(await rechecks.take(user.id, now()))) return coded("Too many tries. Wait fifteen minutes and try again.", "too_many_tries", 429);
      if (!(await accounts.signIn(user.email, String(input[field] ?? "")))) return coded(wrong[0], wrong[1], 400);
      await rechecks.forgive(user.id);
      return null;
    };
    if (path === "/api/account/password" && request.method === "POST") {
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const refused = await recheck(input, "current", ["Your current password is not right", "password_current_wrong"]);
      if (refused) return refused;
      try {
        const updated = await accounts.setPassword(user.email, String(input.next ?? ""), now());
        // The new password ends every other sign-in; this browser gets a fresh one.
        return reply({ ok: true }, 200, { "set-cookie": sessionCookie(request, await accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
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
        if (!(await confirmTries.take(user.id, now()))) {
          await accounts.cancelTwoFactorSetup(user.id);
          return coded("Too many wrong codes. Start turning on two-factor sign-in again.", "twofactor_restart", 429);
        }
        const codes = await accounts.confirmTwoFactor(user.id, String(input.code ?? "").replace(/\s/g, ""), now());
        if (!codes) return coded("That code is not right. Check the time on your phone and try the next one.", "code_wrong", 400);
        await confirmTries.clear(user.id);
        // Turning it on signs out every other browser; this one gets a new session.
        const updated = (await accounts.byId(user.id))!;
        return reply({ recovery: codes }, 200, { "set-cookie": sessionCookie(request, await accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      }
      const refused = await recheck(input, "password", ["Your password is not right", "password_wrong"]);
      if (refused) return refused;
      if (action === "/start") {
        await confirmTries.clear(user.id);
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
        return reply({ ok: true }, 200, { "set-cookie": sessionCookie(request, await accounts.sessionFor(updated, now()), SESSION_MS / 1000) });
      }
      return coded("Not found", "not_found", 404);
    }
    if (user.role !== "owner" && user.role !== "admin") return coded("Only the owner or an admin can manage people", "people_owner", 403);
    // The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and recovery
    // codes, though never the owner's. It asks for their password like every other two-factor change, and their own
    // goes through Account.
    const reset = /^\/api\/people\/([a-f0-9]{24})\/2fa$/.exec(path);
    if (reset && request.method === "DELETE") {
      if (reset[1] === user.id) return coded("Turn off your own two-factor sign-in under Account", "twofactor_self", 400);
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const refused = await recheck(input, "password", ["Your password is not right", "password_wrong"]);
      if (refused) return refused;
      const target = await accounts.byId(reset[1]!);
      if (!target) return coded("Unknown account", "unknown_account", 404);
      if (target.role === "owner") return coded("Only the owner can change the owner's account", "owner_protected", 403);
      await accounts.disableTwoFactor(reset[1]!);
      return reply({ ok: true });
    }
    // The owner hands ownership to an admin and becomes an admin, after typing their password again.
    const handOver = /^\/api\/people\/([a-f0-9]{24})\/owner$/.exec(path);
    if (handOver && request.method === "POST") {
      if (user.role !== "owner") return coded("Only the owner can hand over ownership", "owner_hand_over", 403);
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const refused = await recheck(input, "password", ["Your password is not right", "password_wrong"]);
      if (refused) return refused;
      try {
        await accounts.handOver(user.id, handOver[1]!);
        return reply({ people: (await accounts.list()).map(person) });
      } catch (error) {
        if (error instanceof AccountError) return coded(error.message, error.code, error.code === "unknown_account" ? 404 : 400, error.params);
        throw error;
      }
    }
    // Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
    const roleOf = (value: unknown): Role | null => (value === "admin" || value === "member" || value === "viewer" ? value : null);
    if (path === "/api/people" && request.method === "GET") {
      return reply({ people: (await accounts.list()).map(person), invites: (await accounts.invites(now())).map(inviteView) });
    }
    if (path === "/api/people" && request.method === "POST") {
      const input = await body(request);
      if (!input) return coded("Send JSON", "send_json", 415);
      const role = roleOf(input.role);
      if (!role) return coded("Pick admin, member, or viewer", "role_needed", 400);
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
        if (!role) return coded("Pick admin, member, or viewer", "role_needed", 400);
        const changed = await accounts.setRole(match[1]!, role);
        // A viewer changes nothing, so the tokens they made before go too.
        if (role === "viewer") await dropTokensOf(match[1]!);
        return reply({ person: person(changed) });
      } catch (error) {
        if (error instanceof AccountError) return coded(error.message, error.code, error.code === "unknown_account" ? 404 : error.code === "owner_protected" ? 403 : 400, error.params);
        throw error;
      }
    }
    return coded("Not found", "not_found", 404);
  }

  return {
    accounts,
    signedIn,
    hasAccount,
    async access(request) {
      const user = await signedIn(request);
      if (!user) return false;
      // A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
      return user.role === "owner" || user.role === "admin" ? true : user.role === "member" ? "member" : "read";
    },
    accountOf: async (request) => (await signedIn(request))?.id ?? null,
    // A viewer makes no tokens; someone removed or made a viewer since allowing an app gets none for it.
    async tokenMade(token, by) {
      const role = (await accounts.byId(by))?.role;
      if (!role || role === "viewer") return false;
      await store.setSetting(`${MADE_BY}${token.id}`, by);
      return true;
    },
    async handle(request, path, context = {}) {
      if (path === "/api/account" || path.startsWith("/api/account/") || path === "/api/people" || path.startsWith("/api/people/") || path.startsWith("/api/invites/")) {
        return api(request, path);
      }
      const page = await pages(request, path, context);
      if (page) return page;
      // The dashboard itself: straight to sign-in, or to setting up the first account.
      if ((path === "/" || path === "") && request.method === "GET" && !(await signedIn(request))) {
        if (!(await hasAccount())) return first === "open" || asksForToken ? redirect(`${base}/setup`) : setupLocked();
        const search = new URL(request.url).search;
        return redirect(`${base}/login${search ? `?next=${encodeURIComponent(`${home}${search}`)}` : ""}`);
      }
      return null;
    },
  };
}

/** A random one-time code, such as the one a server prints to unlock its first account. */
export function setupCode(): string {
  return base64url(randomBytes(9));
}
