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
  if (!/^https:\/\/[^/]+|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/.test(url)) throw new RangeError("Enter the install's address, like https://example.com/runlight");
  return url;
}

/** Starts connecting: returns the address of the install's consent page. */
export async function startConnect(runlight: Runlight, input: unknown, back: string): Promise<string> {
  const url = installUrl(input);
  type Meta = { authorization_endpoint?: string; token_endpoint?: string; registration_endpoint?: string; scopes_supported?: string[] };
  const answer = await fetch(`${url}/.well-known/oauth-authorization-server`, { signal: AbortSignal.timeout(10_000) }).catch(() => null);
  if (!answer) throw new RangeError(`Could not reach ${url}`);
  const meta = answer.ok ? ((await answer.json().catch(() => null)) as Meta | null) : null;
  if (!meta?.authorization_endpoint || !meta.token_endpoint || !meta.registration_endpoint) throw new RangeError(`${url} did not answer like a Runlight install`);
  if (!meta.scopes_supported?.includes("manage")) throw new RangeError(`${url} runs an older Runlight. Update it, or connect it with an API token from its Settings.`);

  const registered = await fetch(meta.registration_endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: `Runlight at ${new URL(back).host}`, redirect_uris: [back] }),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  const client = registered?.ok ? ((await registered.json().catch(() => null)) as { client_id?: string } | null) : null;
  if (!client?.client_id) throw new RangeError(`${url} would not let this server connect. Its address must use https.`);

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
  }).toString();
  return to.toString();
}

/** Finishes connecting when the owner comes back from the consent page. Returns the site's id here. */
export async function finishConnect(runlight: Runlight, params: URLSearchParams): Promise<string> {
  const state = params.get("state") ?? "";
  const key = `connect:${state}`;
  const stored = /^[a-f0-9]{32}$/.test(state) ? await runlight.store.setting(key) : null;
  // Each attempt works once.
  if (stored) await runlight.store.setSetting(key, null);
  const pending = stored ? (JSON.parse(stored) as Pending) : null;
  if (!pending || pending.expires < runlight.now()) throw new RangeError("That connection took too long or was already used. Start again.");
  if (params.get("error")) throw new RangeError(params.get("error") === "access_denied" ? "The connection was not allowed." : String(params.get("error_description") ?? params.get("error")));

  const answer = await fetch(pending.token, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code: params.get("code") ?? "", client_id: pending.client, redirect_uri: pending.redirect, code_verifier: pending.verifier }).toString(),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  const granted = answer?.ok ? ((await answer.json().catch(() => null)) as { access_token?: string; site?: string } | null) : null;
  if (!granted?.access_token) throw new RangeError(`${new URL(pending.url).host} did not give this server a token. Start again.`);
  const site = await runlight.addSite({ remote: { url: pending.url, token: granted.access_token, site: granted.site } });
  return site.id;
}
