/** What the tracker sends, after validation. Anything malformed is dropped. */
export interface Payload {
  kind: "pageview" | "event" | "engagement";
  site: string;
  url: URL;
  referrer: string;
  title: string;
  screenWidth: number | undefined;
  screenHeight: number | undefined;
  language: string;
  name: string;
  props: Record<string, string> | null;
  pageviewId: string;
  engagedMs: number;
  scroll: number | undefined;
}

export const MAX_BODY = 8 * 1024;
/** One engagement ping covers at most the 30 minutes a session can idle. */
const MAX_ENGAGED_MS = 30 * 60 * 1000;
const MAX_PROPS = 30;

const str = (value: unknown, max: number): string => (typeof value === "string" ? value.slice(0, max) : "");

function int(value: unknown, min: number, max: number): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return Math.min(max, Math.max(min, Math.round(value)));
}

function props(value: unknown): Record<string, string> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const out: Record<string, string> = {};
  let count = 0;
  for (const [key, raw] of Object.entries(value)) {
    if (count >= MAX_PROPS) break;
    const k = key.trim().slice(0, 60);
    if (!k) continue;
    if (typeof raw === "string") out[k] = raw.slice(0, 500);
    else if (typeof raw === "number" && Number.isFinite(raw)) out[k] = String(raw);
    else if (typeof raw === "boolean") out[k] = String(raw);
    else continue;
    count++;
  }
  return count > 0 ? out : null;
}

export function parsePayload(text: string): Payload | null {
  if (text.length > MAX_BODY) return null;
  let body: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    body = parsed as Record<string, unknown>;
  } catch {
    return null;
  }

  const kind = body.k;
  if (kind !== "pageview" && kind !== "event" && kind !== "engagement") return null;

  let url: URL;
  try {
    url = new URL(str(body.u, 2048));
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;

  const name = str(body.n, 120).trim();
  if (kind === "event" && !name) return null;

  const pageviewId = str(body.i, 32);
  if (pageviewId && !/^[a-z0-9]+$/i.test(pageviewId)) return null;
  if (kind === "engagement" && !pageviewId) return null;

  return {
    kind,
    site: str(body.s, 64),
    url,
    referrer: str(body.r, 2048),
    title: str(body.t, 500),
    screenWidth: int(body.w, 0, 20000),
    screenHeight: int(body.h, 0, 20000),
    language: str(body.l, 35),
    name,
    props: kind === "event" ? props(body.p) : null,
    pageviewId,
    engagedMs: kind === "engagement" ? int(body.e, 0, MAX_ENGAGED_MS) ?? 0 : 0,
    scroll: int(body.d, 0, 100),
  };
}
