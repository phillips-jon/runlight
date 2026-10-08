/**
 * Fetches made on behalf of a site's settings (its icon, a link domain's check) reach only the
 * public internet: https, and never an address inside a private network, the machine itself, or a
 * cloud's metadata service, at every redirect. Names are resolved first where the runtime can resolve
 * them (Node, Bun, and Deno); Workers cannot reach private networks in the first place.
 */

export class PrivateAddressError extends Error {
  constructor(host: string) {
    super(`${host} is not a public address`);
    this.name = "PrivateAddressError";
  }
}

/** True for an IPv4 or IPv6 address outside the public internet. */
export function isPrivateAddress(address: string): boolean {
  const ip = address.replace(/^\[|\]$/g, "").toLowerCase();
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    return (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 0 && Number(v4[3]) === 0) ||
      (a === 192 && b === 168) ||
      (a === 198 && (b === 18 || b === 19)) ||
      a >= 224
    );
  }
  if (!ip.includes(":")) return false;
  // An IPv4 address carried in IPv6 is judged as itself.
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(ip);
  if (mapped) return isPrivateAddress(mapped[1]!);
  if (/^::ffff:[0-9a-f]{1,4}:[0-9a-f]{1,4}$/.test(ip)) {
    const [hi, lo] = ip.slice(7).split(":").map((h) => parseInt(h, 16));
    return isPrivateAddress(`${hi! >> 8}.${hi! & 255}.${lo! >> 8}.${lo! & 255}`);
  }
  return ip === "::" || ip === "::1" || /^f[cd]/.test(ip) || /^fe[89ab]/.test(ip) || ip.startsWith("ff") || ip.startsWith("64:ff9b:");
}

type Lookup = (host: string) => Promise<string[]>;
let lookup: Lookup | null | undefined;

/** The addresses a name resolves to, or null where the runtime has no resolver. */
async function resolve(host: string): Promise<string[] | null> {
  if (lookup === undefined) {
    try {
      const dns = await import("node:dns/promises");
      lookup = async (name) => (await dns.lookup(name, { all: true, verbatim: true })).map((a) => a.address);
    } catch {
      lookup = null;
    }
  }
  return lookup ? lookup(host) : null;
}

/** Throws unless a URL is https on a name or address of the public internet. */
export async function checkPublic(url: URL): Promise<void> {
  if (url.protocol !== "https:") throw new PrivateAddressError(url.host);
  const host = url.hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") || isPrivateAddress(host)) throw new PrivateAddressError(url.host);
  const addresses = await resolve(host.replace(/^\[|\]$/g, ""));
  if (addresses && addresses.some(isPrivateAddress)) throw new PrivateAddressError(url.host);
}

/**
 * A GET to the public internet, following up to `redirects` redirects by hand so each hop is
 * checked. Throws PrivateAddressError for a hop that is not public, and whatever fetch throws.
 */
export async function publicFetch(target: string, init: { signal?: AbortSignal; headers?: Record<string, string>; redirects?: number } = {}): Promise<Response> {
  let url = new URL(target);
  for (let hop = 0; ; hop++) {
    await checkPublic(url);
    const answer = await fetch(url, { redirect: "manual", ...(init.signal ? { signal: init.signal } : {}), ...(init.headers ? { headers: init.headers } : {}) });
    const location = answer.status >= 300 && answer.status < 400 ? answer.headers.get("location") : null;
    if (!location || hop >= (init.redirects ?? 0)) return answer;
    await answer.body?.cancel().catch(() => {});
    url = new URL(location, url);
  }
}
