/**
 * OAuth for the MCP server, so apps that connect only through OAuth (the
 * Claude and ChatGPT web connectors) can reach it. Runlight is both the
 * resource and the authorization server:
 *
 * - /.well-known/oauth-protected-resource names the MCP endpoint and this server.
 * - /.well-known/oauth-authorization-server lists the endpoints below.
 * - POST /oauth/register lets a client register itself (public clients, no secret).
 * - /oauth/authorize asks the signed-in owner to allow the client, every site or one.
 * - POST /oauth/token swaps the one-time code, checked with PKCE, for a token.
 *
 * The token is an ordinary API token, so it appears in Settings, API and AI,
 * beside the others, and deleting it there disconnects the app. It reads
 * stats, or with the "manage" scope (asked for by a Runlight hub) it also
 * changes one site's settings.
 */
import { hmac, randomId, sha256 } from "./hash.js";
import { RateLimit } from "./limit.js";
import type { RequestContext, Runlight } from "./runlight.js";
import type { TokenRow } from "./store.js";

interface Client {
  name: string;
  redirects: string[];
  createdAt: number;
  /** When it was first given a token. Until then, a request it gets wrong ends on a page here. */
  usedAt?: number;
}

interface Code {
  client: string;
  redirect: string;
  challenge: string;
  site: string;
  scope: "read" | "manage";
  expires: number;
  /** Who allowed it, where the app has accounts, so the token goes when they do. */
  by?: string;
}

const CODE_MS = 5 * 60_000;
/** An app stored before client ids were signed, which never finished connecting within a day, is removed. */
const UNUSED_CLIENT_MS = 86_400_000;
/** Registrations one address may make a minute. */
const REGISTRATIONS_PER_MINUTE = 10;
/** The longest client id, which carries the app's name and redirect addresses. */
const MAX_CLIENT_ID = 2048;

/** Per install, the per-address limit on registrations. */
const registrations = new WeakMap<Runlight, RateLimit>();

const base64url = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromBase64url = (text: string) => new TextDecoder().decode(Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)));

/** The key client ids are signed with, made on first use and kept in the database for every process. */
async function clientKey(runlight: Runlight): Promise<string> {
  const saved = await runlight.store.setting("oauth-key");
  if (saved) return saved;
  const made = randomId(32);
  await runlight.store.setSetting("oauth-key", made);
  return made;
}

/**
 * The app a client id names, and where to note that it connected. A new id
 * carries the app's name and addresses, signed, so registering stores
 * nothing and a flood of registrations fills nothing. Ids from before that
 * were stored.
 */
async function clientFor(runlight: Runlight, id: string): Promise<{ client: Client; usedKey: string } | null> {
  if (/^[a-f0-9]{32}$/.test(id)) {
    const stored = await runlight.store.setting(`oauth-client:${id}`);
    return stored ? { client: JSON.parse(stored) as Client, usedKey: `oauth-client:${id}` } : null;
  }
  const parts = /^([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})$/.exec(id);
  if (!parts || id.length > MAX_CLIENT_ID) return null;
  if (!constantTimeEqual(parts[2]!, await hmac(await clientKey(runlight), parts[1]!))) return null;
  const meta = JSON.parse(fromBase64url(parts[1]!)) as { n: string; r: string[]; t: number };
  const usedKey = `oauth-used:${await sha256(id)}`;
  const used = await runlight.store.setting(usedKey);
  return { client: { name: meta.n, redirects: meta.r, createdAt: meta.t, ...(used ? { usedAt: Number(used) } : {}) }, usedKey };
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const esc = (value: string) => value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, content-type, mcp-protocol-version", "access-control-allow-methods": "GET, POST, OPTIONS" };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...CORS } });
}

const oauthError = (error: string, description: string, status = 400) => json({ error, error_description: description }, status);

/** base64url of SHA-256, as PKCE's S256 method compares. */
export async function s256(verifier: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  let text = "";
  for (const b of digest) text += String.fromCharCode(b);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Redirect addresses a client may register: https, or a local app's own loopback address. */
const allowedRedirect = (value: string) => /^https:\/\/[^/]+/.test(value) || /^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?\//.test(value);

export interface OAuthContext {
  runlight: Runlight;
  base: string;
  /** Whether the request comes from the signed-in owner. */
  isOwner: (request: Request) => Promise<boolean>;
  /** Where to send someone to sign in, when there is such a page (the standalone server's). */
  signIn?: string;
  /** Whether the request comes from someone signed in who may only read, such as a viewer. */
  isReader?: (request: Request) => Promise<boolean>;
  /** The account a request comes from, where the app has accounts. */
  accountOf?: (request: Request) => Promise<string | null>;
  /** Notes who made a token; false when they can no longer make one, which takes it back. */
  tokenMade?: (token: TokenRow, by: string) => Promise<boolean>;
}

/** The URL that a 401 from the MCP endpoint points clients at, to start OAuth. */
export const resourceMetadataUrl = (origin: string, base: string) => `${origin}${base}/.well-known/oauth-protected-resource`;

/**
 * Answers the OAuth paths, or returns null for anything else. `path` is
 * relative to the routes' base; the two well-known documents are also answered
 * at the site's root (`/.well-known/...`) for clients that look there.
 */
export async function oauthResponse(ctx: OAuthContext, request: Request, path: string, url: URL, context: RequestContext = {}): Promise<Response | null> {
  const { runlight, base } = ctx;
  const issuer = `${url.origin}${base}`;
  const known = path;
  if (request.method === "OPTIONS" && (known.startsWith("/.well-known/oauth-") || path.startsWith("/oauth/"))) return new Response(null, { status: 204, headers: CORS });

  if (known.startsWith("/.well-known/oauth-protected-resource")) {
    return json({ resource: `${issuer}/mcp`, authorization_servers: [issuer], scopes_supported: ["read", "manage"], bearer_methods_supported: ["header"] });
  }
  if (known.startsWith("/.well-known/oauth-authorization-server") || known.startsWith("/.well-known/openid-configuration")) {
    return json({
      issuer,
      authorization_endpoint: `${issuer}/oauth/authorize`,
      token_endpoint: `${issuer}/oauth/token`,
      registration_endpoint: `${issuer}/oauth/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["read", "manage"],
    });
  }

  if (path === "/oauth/register" && request.method === "POST") {
    await runlight.init();
    let limit = registrations.get(runlight);
    if (!limit) registrations.set(runlight, (limit = new RateLimit(REGISTRATIONS_PER_MINUTE, () => runlight.now())));
    if (!(await limit.allow(runlight.clientIp(request, context)))) return oauthError("invalid_client_metadata", "Too many registrations from this address. Wait a minute and try again.", 429);
    const body = (await request.json().catch(() => null)) as { client_name?: unknown; redirect_uris?: unknown } | null;
    const redirects = Array.isArray(body?.redirect_uris) ? body!.redirect_uris.map(String).filter(allowedRedirect).slice(0, 10) : [];
    if (!redirects.length) return oauthError("invalid_redirect_uri", "Register at least one https redirect address");
    return register(runlight, String(body?.client_name ?? "An app"), redirects);
  }

  if (path === "/oauth/authorize" && (request.method === "GET" || request.method === "POST")) {
    await runlight.init();
    const form = request.method === "POST" ? new URLSearchParams(await request.text()) : url.searchParams;
    const clientId = form.get("client_id") ?? "";
    const client = (await clientFor(runlight, clientId))?.client ?? null;
    const redirect = form.get("redirect_uri") ?? "";
    // Without a known client and one of its own addresses there is nowhere safe to send an answer.
    if (!client || !client.redirects.includes(redirect)) return page("This app is not registered", "<p>Start connecting again from the app.</p>", 400);
    const back = (params: Record<string, string>) => {
      const to = new URL(redirect);
      for (const [k, v] of Object.entries(params)) to.searchParams.set(k, v);
      const state = form.get("state");
      if (state) to.searchParams.set("state", state);
      return new Response(null, { status: 303, headers: { location: to.toString(), "cache-control": "no-store" } });
    };
    // Anyone can register an app with any address, so until an owner has allowed it once, a request
    // it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
    const refuse = (params: Record<string, string>) =>
      client.usedAt ? back(params) : page("This app asked in a way Runlight does not support", `<p>${esc(client.name)} sent ${esc(params.error_description ?? params.error!)}. Start connecting again from the app.</p>`, 400);
    if (form.get("response_type") !== "code") return refuse({ error: "unsupported_response_type" });
    const challenge = form.get("code_challenge") ?? "";
    if (form.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) return refuse({ error: "invalid_request", error_description: "PKCE with S256 is required" });
    const manage = (form.get("scope") ?? "").split(/\s+/).includes("manage");

    if (!(await ctx.isOwner(request))) {
      // Someone signed in who may only read would be sent to sign in again and again.
      if (ctx.isReader && (await ctx.isReader(request))) {
        return page("Ask an owner to connect this", `<p>You are signed in as a viewer, and only an owner of this Runlight can connect ${esc(client.name)}.</p>`, 403);
      }
      // The site stays, since on the way in it only says which one to offer first.
      const here = `${url.pathname}?${new URLSearchParams([...form.entries()].filter(([k]) => k !== "decision")).toString()}`;
      if (ctx.signIn) return new Response(null, { status: 303, headers: { location: `${ctx.signIn}?next=${encodeURIComponent(here)}`, "cache-control": "no-store" } });
      return page("Sign in first", `<p>Open your Runlight dashboard at <a href="${esc(base || "/")}">${esc(url.host + (base || "/"))}</a> and sign in, then connect ${esc(client.name)} again.</p>`, 401);
    }

    if (request.method === "GET") {
      const hidden = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource"]
        .map((k) => (form.get(k) !== null ? `<input type="hidden" name="${k}" value="${esc(form.get(k)!)}">` : ""))
        .join("");
      // The app names itself, so the page also shows where the answer goes, which it cannot fake.
      const sendsTo = `<p class="note">Allowing sends you back to <strong>${esc(new URL(redirect).host)}</strong>. Only allow it if you started connecting there.</p>`;
      if (manage) {
        // Changing settings is for one site at a time, so there is no "every site" here.
        const sites = runlight.sites.filter((s) => !runlight.remote(s.id));
        const wanted = form.get("site") ?? "";
        const choices = sites.map((s) => `<option value="${esc(s.id)}"${s.id === wanted ? " selected" : ""}>${esc(s.name)}</option>`).join("");
        return page(
          `Connect ${esc(client.name)}`,
          `<p><strong>${esc(client.name)}</strong> wants to show this site’s stats and change its settings, so you can manage it from there.</p>
<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>
${sendsTo}
<form method="post" action="${esc(base)}/oauth/authorize">${hidden}
<label>Site<select name="site">${choices}</select></label>
<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects ${esc(client.name)}.</p>
<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>`,
        );
      }
      const options = runlight.sites.map((s) => `<option value="${esc(s.id)}">${esc(s.name)} only</option>`).join("");
      return page(
        `Connect ${esc(client.name)}`,
        `<p><strong>${esc(client.name)}</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>
${sendsTo}
<form method="post" action="${esc(base)}/oauth/authorize">${hidden}
<label>Which sites it can read<select name="site"><option value="">Every site</option>${runlight.sites.length > 1 ? options : ""}</select></label>
<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>
<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>`,
      );
    }
    // The consent form posts here from this page only; a form from another site is refused.
    const origin = request.headers.get("origin");
    if (origin && origin !== url.origin) return page("This request came from another site", "<p>Start connecting again from the app.</p>", 403);
    if (form.get("decision") !== "allow") return back({ error: "access_denied" });
    const site = form.get("site") ?? "";
    if (site && !runlight.site(site)) return back({ error: "invalid_request", error_description: "Unknown site" });
    if (manage && (!site || runlight.remote(site))) return back({ error: "invalid_request", error_description: "Pick the site to manage" });
    const code = randomId(32);
    const by = (await ctx.accountOf?.(request)) ?? null;
    const grant: Code = { client: clientId, redirect, challenge, site, scope: manage ? "manage" : "read", expires: runlight.now() + CODE_MS, ...(by ? { by } : {}) };
    await runlight.store.setSetting(`oauth-code:${await sha256(code)}`, JSON.stringify(grant));
    return back({ code });
  }

  if (path === "/oauth/token" && request.method === "POST") {
    await runlight.init();
    const type = (request.headers.get("content-type") ?? "").split(";")[0]!.trim();
    const form = type === "application/json" ? new URLSearchParams(Object.entries(((await request.json().catch(() => ({}))) as Record<string, string>) ?? {})) : new URLSearchParams(await request.text());
    if (form.get("grant_type") !== "authorization_code") return oauthError("unsupported_grant_type", "Only authorization_code is supported");
    const key = `oauth-code:${await sha256(form.get("code") ?? "")}`;
    const stored = await runlight.store.setting(key);
    // A code works once: it is gone before anything else is checked.
    if (stored) await runlight.store.setSetting(key, null);
    const grant = stored ? (JSON.parse(stored) as Code) : null;
    if (!grant || grant.expires < runlight.now()) return oauthError("invalid_grant", "The code has expired or was already used");
    if (grant.client !== form.get("client_id") || grant.redirect !== form.get("redirect_uri")) return oauthError("invalid_grant", "The code was issued to another app");
    if ((await s256(form.get("code_verifier") ?? "")) !== grant.challenge) return oauthError("invalid_grant", "The code verifier does not match");
    // The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
    const found = await clientFor(runlight, grant.client);
    const client: Partial<Client> = found?.client ?? {};
    if (found && !found.client.usedAt) {
      const stored = found.usedKey.startsWith("oauth-client:");
      await runlight.store.setSetting(found.usedKey, stored ? JSON.stringify({ ...found.client, usedAt: runlight.now() }) : String(runlight.now()));
    }
    const secret = `rl_${randomId(20)}`;
    const scope = grant.scope === "manage" ? "manage" : "read";
    const row: TokenRow = { id: randomId(), name: `${client.name ?? "An app"} (OAuth)`.slice(0, 100), site: grant.site, scope, hash: await sha256(secret), hint: secret.slice(-4), createdAt: runlight.now(), lastUsedAt: null };
    await runlight.store.insertToken(row);
    // Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
    if (grant.by && ctx.tokenMade && !(await ctx.tokenMade(row, grant.by))) {
      await runlight.store.deleteToken(row.id);
      return oauthError("invalid_grant", "Whoever allowed this app can no longer connect it");
    }
    // A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
    if (scope === "manage") await runlight.store.setSetting(`token-origin:${row.id}`, new URL(grant.redirect).origin);
    // site is not part of OAuth, but a hub needs to know which site it was given.
    return json({ access_token: secret, token_type: "Bearer", scope, ...(grant.site ? { site: grant.site } : {}) });
  }

  return null;
}

/**
 * Registers a client by signing its name and addresses into its id, so
 * nothing is stored until an owner allows it and the app swaps its code.
 */
async function register(runlight: Runlight, name: string, redirects: string[]): Promise<Response> {
  const now = runlight.now();
  // Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
  for (const { key, value } of await runlight.store.settingsStartingWith("oauth-client:")) {
    const client = JSON.parse(value) as Client;
    if (!client.usedAt && now - client.createdAt >= UNUSED_CLIENT_MS) await runlight.store.setSetting(key, null);
  }
  for (const { key, value } of await runlight.store.settingsStartingWith("oauth-code:")) {
    if (((JSON.parse(value) as Partial<Code>).expires ?? 0) < now) await runlight.store.setSetting(key, null);
  }
  const client: Client = { name: name.trim().slice(0, 80) || "An app", redirects, createdAt: now };
  const payload = base64url(JSON.stringify({ n: client.name, r: redirects, t: now }));
  const id = `${payload}.${await hmac(await clientKey(runlight), payload)}`;
  if (id.length > MAX_CLIENT_ID) return oauthError("invalid_client_metadata", "Register fewer or shorter redirect addresses");
  return json({ client_id: id, client_name: client.name, redirect_uris: redirects, token_endpoint_auth_method: "none", grant_types: ["authorization_code"], response_types: ["code"] }, 201);
}

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>${title} | Runlight</title>
<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style></head><body><main><h1>${title}</h1>${body}</main></body></html>`,
    {
      status,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        // No form-action rule: browsers apply it to the redirect back to the app after Allow.
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
        "x-frame-options": "DENY",
        // same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
        "referrer-policy": "same-origin",
      },
    },
  );
}
