/**
 * Connecting another Runlight to this one (a hub) without copying a token:
 * this server registers itself with the install's OAuth server, sends the
 * owner to that install's consent page, and on the way back swaps the code
 * for a manage token, limited there to the one site the owner picked.
 */
import { randomId } from "./hash.js";
import { s256 } from "./oauth.js";
import type { Runlight } from "./runlight.js";

interface Pending {
  url: string;
  client: string;
  verifier: string;
  redirect: string;
  token: string;
  expires: number;
}

const PENDING_MS = 15 * 60_000;

/** The install's address as its dashboard is, without a trailing slash. */
export function installUrl(value: unknown): string {
  const url = String(value ?? "").trim().replace(/\/+$/, "");
  if (!/^https:\/\/[^/]+|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/.test(url)) throw new ConnectError("Enter the install's address, like https://example.com/runlight", "url");
  return url;
}

/** Attempts nobody came back from are removed, so they do not pile up in settings. */
async function clearExpired(runlight: Runlight): Promise<void> {
  for (const { key, value } of await runlight.store.settingsStartingWith("connect:")) {
    const pending = JSON.parse(value) as Partial<Pending>;
    if (!pending.expires || pending.expires < runlight.now()) await runlight.store.setSetting(key, null);
  }
}

/** Starts connecting: returns the address of the install's consent page. */
export async function startConnect(runlight: Runlight, input: unknown, back: string, site = ""): Promise<string> {
  const url = installUrl(input);
  type Meta = { authorization_endpoint?: string; token_endpoint?: string; registration_endpoint?: string; scopes_supported?: string[] };
  const answer = await fetch(`${url}/.well-known/oauth-authorization-server`, { signal: AbortSignal.timeout(10_000) }).catch(() => null);
  if (!answer) throw new ConnectError(`Could not reach ${url}`, "unreachable", { url });
  const meta = answer.ok ? ((await answer.json().catch(() => null)) as Meta | null) : null;
  if (!meta?.authorization_endpoint || !meta.token_endpoint || !meta.registration_endpoint) throw new ConnectError(`${url} did not answer like a Runlight install`, "not_runlight", { url });
  // Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
  const own = (endpoint: string) => {
    try {
      return new URL(endpoint).origin === new URL(url).origin;
    } catch {
      return false;
    }
  };
  if (![meta.authorization_endpoint, meta.token_endpoint, meta.registration_endpoint].every(own)) throw new ConnectError(`${url} named endpoints on another address`, "endpoints", { url });
  if (!meta.scopes_supported?.includes("manage")) throw new ConnectError(`${url} runs an older Runlight. Update it, or connect it with an API token from its Settings.`, "old", { url });

  const registered = await fetch(meta.registration_endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: `Runlight at ${new URL(back).host}`, redirect_uris: [back] }),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  if (!registered) throw new ConnectError(`Could not reach ${url}`, "unreachable", { url });
  const client = (await registered.json().catch(() => null)) as { client_id?: string; error_description?: string } | null;
  if (!registered.ok || !client?.client_id) {
    // Say why, in the install's own words when it gives them.
    const reason = client?.error_description ? `${String(client.error_description).slice(0, 200)}.` : registered.status === 400 ? "This server's address must use https." : `It answered ${registered.status}.`;
    throw new ConnectError(`${url} would not let this server connect. ${reason}`, "register", { url, reason });
  }
  await clearExpired(runlight);

  const state = randomId(16);
  const verifier = `${randomId(32)}${randomId(32)}`;
  const pending: Pending = { url, client: client.client_id, verifier, redirect: back, token: meta.token_endpoint, expires: runlight.now() + PENDING_MS };
  await runlight.store.setSetting(`connect:${state}`, JSON.stringify(pending));
  const to = new URL(meta.authorization_endpoint);
  to.search = new URLSearchParams({
    response_type: "code",
    client_id: client.client_id,
    redirect_uri: back,
    code_challenge: await s256(verifier),
    code_challenge_method: "S256",
    scope: "manage",
    state,
    // Which of its sites to offer first, when connecting again for a site already here.
    ...(site ? { site } : {}),
  }).toString();
  return to.toString();
}

/**
 * Why connecting failed on the way back from the consent page, as a code the
 * dashboard turns into its own words. The page it lands on is this server's
 * own, so it never shows text that came in the address.
 */
/**
 * Why connecting failed, as a code the dashboard says in its own words. The
 * first four come back from the consent page, the rest from starting.
 */
export class ConnectError extends RangeError {
  constructor(
    message: string,
    readonly code: "expired" | "denied" | "refused" | "token" | "url" | "unreachable" | "not_runlight" | "endpoints" | "old" | "register",
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}

/** Finishes connecting when the owner comes back from the consent page. Returns the site's id here. */
export async function finishConnect(runlight: Runlight, params: URLSearchParams): Promise<string> {
  const state = params.get("state") ?? "";
  const key = `connect:${state}`;
  const stored = /^[a-f0-9]{32}$/.test(state) ? await runlight.store.setting(key) : null;
  // Each attempt works once.
  if (stored) await runlight.store.setSetting(key, null);
  const pending = stored ? (JSON.parse(stored) as Pending) : null;
  if (!pending || pending.expires < runlight.now()) throw new ConnectError("That connection took too long or was already used. Start again.", "expired");
  if (params.get("error") === "access_denied") throw new ConnectError("The connection was not allowed.", "denied");
  if (params.get("error")) throw new ConnectError(String(params.get("error_description") ?? params.get("error")), "refused");

  const answer = await fetch(pending.token, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code: params.get("code") ?? "", client_id: pending.client, redirect_uri: pending.redirect, code_verifier: pending.verifier }).toString(),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  const granted = answer?.ok ? ((await answer.json().catch(() => null)) as { access_token?: string; site?: string } | null) : null;
  if (!granted?.access_token) throw new ConnectError(`${new URL(pending.url).host} did not give this server a token. Start again.`, "token");
  const site = await runlight.addSite({ remote: { url: pending.url, token: granted.access_token, site: granted.site } });
  return site.id;
}
