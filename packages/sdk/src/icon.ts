/**
 * A site's icon, for the dashboard header: the best icon its home page
 * links to, or /favicon.ico. Fetched from the site's own configured origin
 * (never from request input), cached in memory for a day.
 */
const TIMEOUT_MS = 4000;
const MAX_BYTES = 256 * 1024;
const DAY = 86_400_000;

interface Icon {
  body: ArrayBuffer;
  type: string;
}

const cache = new Map<string, { at: number; icon: Icon | null }>();

function attr(tag: string, name: string): string {
  const match = new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
  return (match?.[2] ?? match?.[3] ?? match?.[4] ?? "").trim();
}

/** Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon. */
export function iconLinks(html: string, base: string): string[] {
  const found: Array<{ url: string; score: number }> = [];
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) {
    const rel = attr(tag, "rel").toLowerCase().split(/\s+/);
    const href = attr(tag, "href");
    if (!href || !(rel.includes("icon") || rel.includes("apple-touch-icon"))) continue;
    let url: string;
    try {
      url = new URL(href, base).toString();
    } catch {
      continue;
    }
    if (!url.startsWith("https://") && !url.startsWith("http://")) continue;
    const type = attr(tag, "type").toLowerCase();
    const score = rel.includes("apple-touch-icon") ? 3 : type.includes("svg") || url.endsWith(".svg") ? 2 : type.includes("png") || url.endsWith(".png") ? 1 : 0;
    found.push({ url, score });
  }
  return found.sort((a, b) => b.score - a.score).map((f) => f.url);
}

async function get(url: string): Promise<Response | null> {
  try {
    return await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "follow", headers: { "user-agent": "Runlight (+https://runlight.sh)" } });
  } catch {
    return null;
  }
}

/** A response body, stopping as soon as it passes `max` bytes rather than reading it all. Null past that. */
async function capped(response: Response, max: number): Promise<Uint8Array | null> {
  if (!response.body) return new Uint8Array();
  if (Number(response.headers.get("content-length") ?? 0) > max) {
    await response.body.cancel().catch(() => {});
    return null;
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > max) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.length;
  }
  return all;
}

async function image(url: string): Promise<Icon | null> {
  const response = await get(url);
  if (!response?.ok) return null;
  const type = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (!type.startsWith("image/")) {
    await response.body?.cancel().catch(() => {});
    return null;
  }
  const bytes = await capped(response, MAX_BYTES);
  if (!bytes || bytes.byteLength === 0) return null;
  return { body: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer, type };
}

/** Up to `max` bytes of a body, then stops reading. */
async function readHead(response: Response, max: number): Promise<Uint8Array> {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const out = new Uint8Array(max);
  let size = 0;
  try {
    while (size < max) {
      const { done, value } = await reader.read();
      if (done) break;
      const take = Math.min(value.length, max - size);
      out.set(value.subarray(0, take), size);
      size += take;
    }
  } catch {
    // What arrived is enough to look through.
  }
  await reader.cancel().catch(() => {});
  return out.subarray(0, size);
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
    const bytes = await readHead(page, 200_000);
    const html = new TextDecoder().decode(bytes);
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
