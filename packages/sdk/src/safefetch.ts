/**
 * Fetches from addresses that other people's input names, such as the icon
 * links on a site's home page or a link domain, and only from the public
 * internet. Only https is fetched, never a private, loopback, link-local,
 * or metadata address, and redirects are followed by hand under the same
 * rules. On Node, Bun, and Deno the check runs on the address the
 * connection uses, so a name that answers differently a moment later gets
 * nowhere. Elsewhere, such as an edge runtime that cannot reach a private
 * network anyway, only the name is checked.
 */
import type { LookupAddress } from "node:dns";

/** Refused before anything was fetched, because the address is not on the public internet. */
export class PrivateAddressError extends Error {
  constructor(what: string) {
    super(`${what} is not a public address`);
    this.name = "PrivateAddressError";
  }
}

const v4 = (text: string): number[] | null => {
  const parts = text.split(".");
  if (parts.length !== 4 || parts.some((p) => !/^\d{1,3}$/.test(p) || Number(p) > 255)) return null;
  return parts.map(Number);
};

function publicV4([a, b, c]: number[]): boolean {
  if (a === 0 || a === 10 || a === 127 || a! >= 224) return false;
  if (a === 100 && b! >= 64 && b! < 128) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b! >= 16 && b! < 32) return false;
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0 && (c === 0 || c === 2)) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if (a === 198 && b === 51 && c === 100) return false;
  if (a === 203 && b === 0 && c === 113) return false;
  return true;
}

/** An IPv6 address as eight 16-bit groups, or null when it is not one. */
function v6(text: string): number[] | null {
  let address = text.replace(/^\[|\]$/g, "").split("%")[0]!.toLowerCase();
  // A trailing IPv4 address becomes the last two groups.
  const tail = /(\d{1,3}(?:\.\d{1,3}){3})$/.exec(address);
  if (tail) {
    const four = v4(tail[1]!);
    if (!four) return null;
    address = `${address.slice(0, -tail[1]!.length)}${((four[0]! << 8) | four[1]!).toString(16)}:${((four[2]! << 8) | four[3]!).toString(16)}`;
  }
  const halves = address.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...rest];
  if (groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

/** Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not. */
export function publicAddress(ip: string): boolean {
  const four = v4(ip);
  if (four) return publicV4(four);
  const g = v6(ip);
  if (!g) return false;
  const embedded = (hi: number, lo: number) => [hi >> 8, hi & 255, lo >> 8, lo & 255];
  // IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
  if (g.slice(0, 5).every((x) => x === 0) && (g[5] === 0xffff || g[5] === 0)) return g[5] === 0 && g[6] === 0 && g[7]! <= 1 ? false : publicV4(embedded(g[6]!, g[7]!));
  if (g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((x) => x === 0)) return publicV4(embedded(g[6]!, g[7]!));
  // 6to4 carries an IPv4 address in its second and third groups.
  if (g[0] === 0x2002) return publicV4(embedded(g[1]!, g[2]!));
  if ((g[0]! & 0xfe00) === 0xfc00 || (g[0]! & 0xffc0) === 0xfe80 || (g[0]! & 0xff00) === 0xff00) return false;
  // Teredo, documentation, and discard prefixes.
  if (g[0] === 0x2001 && (g[1] === 0 || g[1] === 0xdb8)) return false;
  if (g[0] === 0x100 && g.slice(1, 4).every((x) => x === 0)) return false;
  return true;
}

type Https = typeof import("node:https");
type Dns = typeof import("node:dns");
type Stream = typeof import("node:stream");

/**
 * Node's own modules where the runtime has them, found without an import a bundler would follow.
 * Workers reach no private network, and their https module may only be a stand-in, so they use fetch.
 */
function builtins(): { https: Https; dns: Dns; stream: Stream } | null {
  const scope = globalThis as { process?: { getBuiltinModule?: (id: string) => unknown }; navigator?: { userAgent?: string } };
  const get = scope.process?.getBuiltinModule;
  if (typeof get !== "function" || scope.navigator?.userAgent === "Cloudflare-Workers") return null;
  try {
    const https = get("node:https") as Https | undefined;
    const dns = get("node:dns") as Dns | undefined;
    const stream = get("node:stream") as Stream | undefined;
    return typeof https?.request === "function" && typeof dns?.lookup === "function" && typeof stream?.Readable?.toWeb === "function" ? { https, dns, stream } : null;
  } catch {
    return null;
  }
}

/** A resolver for names, where the runtime has one, even without the rest of Node's modules. */
async function resolver(): Promise<Dns["promises"] | null> {
  const node = builtins();
  if (node) return node.dns.promises;
  try {
    // A name in a variable, so a bundler for an edge runtime leaves the import alone.
    const id = "node:dns";
    const dns = (await import(id)) as Dns;
    return typeof dns.promises?.lookup === "function" ? dns.promises : null;
  } catch {
    return null;
  }
}

/** Whether a name resolves to an address off the public internet. False when it does not resolve, or cannot be looked up here. */
export async function resolvesPrivately(name: string): Promise<boolean> {
  const dns = await resolver();
  if (!dns) return false;
  try {
    const found = await dns.lookup(name, { all: true });
    return found.some((a) => !publicAddress(a.address));
  } catch {
    return false;
  }
}

/** One request with no redirects, connecting only to public addresses. */
function once(node: NonNullable<ReturnType<typeof builtins>>, url: URL, headers: Record<string, string>, signal: AbortSignal): Promise<Response> {
  // The lookup Node calls when it connects, so the address checked is the address used.
  const lookup = (hostname: string, options: { all?: boolean }, callback: (error: Error | null, address?: string | LookupAddress[], family?: number) => void) => {
    node.dns.lookup(hostname, { all: true }, (error, addresses) => {
      if (error) return callback(error);
      const bad = addresses.find((a) => !publicAddress(a.address));
      if (bad || !addresses.length) return callback(new PrivateAddressError(hostname));
      if (options.all) return callback(null, addresses);
      callback(null, addresses[0]!.address, addresses[0]!.family);
    });
  };
  return new Promise((resolve, reject) => {
    const request = node.https.request(url, { method: "GET", headers, signal, lookup: lookup as never }, (answer) => {
      const back = new Headers();
      for (const [name, value] of Object.entries(answer.headers)) {
        for (const one of Array.isArray(value) ? value : value === undefined ? [] : [value]) back.append(name, one);
      }
      const status = answer.statusCode ?? 502;
      const empty = status === 204 || status === 205 || status === 304;
      if (empty) answer.resume();
      resolve(new Response(empty ? null : (node.stream.Readable.toWeb(answer) as ReadableStream), { status, headers: back }));
    });
    request.on("error", reject);
    request.end();
  });
}

/**
 * GETs an https URL on the public internet, following up to `redirects`
 * redirects that stay on it, within `timeoutMs` in all. Throws a
 * PrivateAddressError for an address off it, and the timeout's own error
 * when time runs out. A redirect past the last one comes back as it is.
 * `fetch` stands in for the runtime's, in tests, and checks names before
 * each hop the way a runtime without Node's https module does.
 */
export async function publicFetch(target: string, init: { timeoutMs: number; headers?: Record<string, string>; redirects?: number; fetch?: typeof fetch }): Promise<Response> {
  const signal = AbortSignal.timeout(init.timeoutMs);
  const node = init.fetch ? null : builtins();
  let url = new URL(target);
  for (let hop = 0; ; hop++) {
    if (url.protocol !== "https:") throw new PrivateAddressError(url.href);
    const host = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
    if ((v4(host) || v6(host)) && !publicAddress(host)) throw new PrivateAddressError(host);
    if (host === "localhost" || host.endsWith(".localhost")) throw new PrivateAddressError(host);
    // Without a connection of its own to check, the name is resolved first where the runtime can.
    if (!node && (await resolvesPrivately(host))) throw new PrivateAddressError(host);
    let answer: Response;
    try {
      answer = node ? await once(node, url, init.headers ?? {}, signal) : await (init.fetch ?? fetch)(url, { headers: init.headers ?? {}, redirect: "manual", signal });
    } catch (error) {
      // Whichever way the runtime says it gave up, the caller hears that time ran out.
      if (signal.aborted) throw signal.reason;
      throw error;
    }
    const location = answer.headers.get("location");
    if (answer.status < 300 || answer.status >= 400 || !location || hop >= (init.redirects ?? 0)) return answer;
    await answer.body?.cancel().catch(() => {});
    url = new URL(location, url);
  }
}
