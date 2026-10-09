/**
 * A site's icon, for the dashboard header: the best icon its home page
 * links to, or /favicon.ico. Fetched from the site's own configured origin
 * (never from request input), cached in memory for a day.
 */
import { publicFetch } from "./safefetch.js";

const TIMEOUT_MS = 4000;
const MAX_BYTES = 256 * 1024;
const DAY = 86_400_000;

interface Icon {
  body: ArrayBuffer;
  type: string;
}

const cache = new Map<string, { at: number; icon: Icon | null }>();

/**
 * A tag's attributes, read one after another so a name inside another
 * (data-rel) or inside a value (title="rel=icon") is never taken for one.
 * The first of a repeated name counts, as in a browser.
 */
function attrs(tag: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const m of tag.slice("<link".length).matchAll(/([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
    const name = m[1]!.toLowerCase();
    if (!out.has(name)) out.set(name, (m[2] ?? m[3] ?? m[4] ?? "").trim());
  }
  return out;
}

/** Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon. */
export function iconLinks(html: string, base: string): string[] {
  const found: Array<{ url: string; score: number }> = [];
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) {
    const attributes = attrs(tag);
    const rel = (attributes.get("rel") ?? "").toLowerCase().split(/\s+/);
    const href = attributes.get("href") ?? "";
    if (!href || !(rel.includes("icon") || rel.includes("apple-touch-icon"))) continue;
    let url: string;
    try {
      url = new URL(href, base).toString();
    } catch {
      continue;
    }
    // Only https, which is all the fetch below takes.
    if (!url.startsWith("https://")) continue;
    const type = (attributes.get("type") ?? "").toLowerCase();
    const score = rel.includes("apple-touch-icon") ? 3 : type.includes("svg") || url.endsWith(".svg") ? 2 : type.includes("png") || url.endsWith(".png") ? 1 : 0;
    found.push({ url, score });
  }
  return found.sort((a, b) => b.score - a.score).map((f) => f.url);
}

/** A GET of a public https address, with redirects followed only to public addresses too. */
async function get(url: string): Promise<Response | null> {
  try {
    return await publicFetch(url, { timeoutMs: TIMEOUT_MS, redirects: 3, headers: { "user-agent": "Runlight (+https://runlight.sh)" } });
  } catch {
    return null;
  }
}

/**
 * Up to `max` bytes of a body, reading no further. With `whole`, null when the body is longer, for an
 * image that must arrive complete; without, the start of it, enough for a page's head.
 */
async function readUpTo(response: Response, max: number, whole: boolean): Promise<Uint8Array | null> {
  if (!response.body) return new Uint8Array();
  if (whole && Number(response.headers.get("content-length") ?? 0) > max) {
    await response.body.cancel().catch(() => {});
    return null;
  }
  const reader = response.body.getReader();
  const out = new Uint8Array(max);
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.length > max) {
        await reader.cancel().catch(() => {});
        if (whole) return null;
        out.set(value.subarray(0, max - size), size);
        return out;
      }
      out.set(value, size);
      size += value.length;
    }
  } catch {
    // A body cut off part way: an image is no use, a page's start still is.
    if (whole) return null;
  }
  return out.subarray(0, size);
}

async function image(url: string): Promise<Icon | null> {
  const response = await get(url);
  if (!response?.ok) return null;
  const type = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (!type.startsWith("image/")) {
    await response.body?.cancel().catch(() => {});
    return null;
  }
  const bytes = await readUpTo(response, MAX_BYTES, true);
  if (!bytes || bytes.byteLength === 0) return null;
  return { body: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer, type };
}

/** Lookups under way, so many dashboards opening at once share one. */
const pending = new Map<string, Promise<Icon | null>>();

export async function fetchIcon(origin: string, now = Date.now()): Promise<Icon | null> {
  const cached = cache.get(origin);
  if (cached && now - cached.at < (cached.icon ? DAY : DAY / 24)) return cached.icon;
  let lookup = pending.get(origin);
  if (!lookup) {
    lookup = lookUp(origin, now).finally(() => pending.delete(origin));
    pending.set(origin, lookup);
  }
  return lookup;
}

async function lookUp(origin: string, now: number): Promise<Icon | null> {
  let icon: Icon | null = null;
  const page = await get(`${origin}/`);
  if (page?.ok && (page.headers.get("content-type") ?? "").includes("html")) {
    // The head is all that is needed, so a huge page is not read to the end.
    const html = new TextDecoder().decode((await readUpTo(page, 200_000, false)) ?? new Uint8Array());
    for (const url of iconLinks(html, page.url || origin).slice(0, 4)) {
      icon = await image(url);
      if (icon) break;
    }
  }
  icon ??= await image(`${origin}/favicon.ico`);
  cache.set(origin, { at: now, icon });
  // A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.
  if (cache.size > 500) cache.delete(cache.keys().next().value!);
  return icon;
}
