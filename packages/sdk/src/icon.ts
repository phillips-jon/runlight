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

async function image(url: string): Promise<Icon | null> {
  const response = await get(url);
  if (!response?.ok) return null;
  const type = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (!type.startsWith("image/")) return null;
  const body = await response.arrayBuffer().catch(() => null);
  if (!body || body.byteLength === 0 || body.byteLength > MAX_BYTES) return null;
  return { body, type };
}

export async function fetchIcon(origin: string, now = Date.now()): Promise<Icon | null> {
  const cached = cache.get(origin);
  if (cached && now - cached.at < (cached.icon ? DAY : DAY / 24)) return cached.icon;

  let icon: Icon | null = null;
  const page = await get(`${origin}/`);
  if (page?.ok && (page.headers.get("content-type") ?? "").includes("html")) {
    const html = (await page.text().catch(() => "")).slice(0, 200_000);
    for (const url of iconLinks(html, page.url || origin).slice(0, 4)) {
      icon = await image(url);
      if (icon) break;
    }
  }
  icon ??= await image(`${origin}/favicon.ico`);
  cache.set(origin, { at: now, icon });
  return icon;
}
