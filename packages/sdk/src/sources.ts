import { SOURCE_PATTERNS, SOURCES, type KnownSource, type SourceKind } from "./data/sources.js";

export type Channel = "Direct" | "Organic Search" | "Paid Search" | "Social" | "Email" | "AI" | "Referral" | "Campaign";

export interface Page {
  hostname: string;
  path: string;
  utm: Utm;
  /** A `ref` or `source` query parameter, used when there is no utm_source. */
  ref: string;
  /** A click id such as gclid was present. The id itself is never kept. */
  paid: boolean;
}

export interface Utm {
  source: string;
  medium: string;
  campaign: string;
  term: string;
  content: string;
}

export interface Attribution {
  referrerHost: string;
  referrerPath: string;
  source: string;
  channel: Channel;
}

const CLICK_IDS = ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"];
const PAID_MEDIUMS = /^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)$/;
const EMAIL_MEDIUMS = /^(e-?mail|newsletter|mail)$/;
const SOCIAL_MEDIUMS = /^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)$/;

const byHost = new Map<string, KnownSource>();
const byAlias = new Map<string, KnownSource>();
for (const source of SOURCES) {
  for (const host of source.hosts) byHost.set(host, source);
  for (const alias of source.aliases ?? []) byAlias.set(alias, source);
}

const clip = (value: string | null, max = 200): string => (value ?? "").trim().slice(0, max);

export function stripWww(host: string): string {
  return host.toLowerCase().replace(/^www\./, "");
}

/**
 * The most specific known source for a host: mail.google.com before
 * google.com. Android apps send their package name as the referrer
 * (com.google.android.gm for Gmail), which is matched the same way. Hosts
 * known only by their shape (click trackers, webmail) come last.
 */
export function sourceForHost(host: string): KnownSource | null {
  const clean = stripWww(host);
  let candidate = clean;
  while (candidate.includes(".")) {
    const found = byHost.get(candidate);
    if (found) return found;
    candidate = candidate.slice(candidate.indexOf(".") + 1);
  }
  for (const rule of SOURCE_PATTERNS) {
    if (rule.pattern.test(clean)) return { name: rule.name ?? clean, kind: rule.kind, hosts: [] };
  }
  return null;
}

export function sourceForAlias(value: string): KnownSource | null {
  const key = value.toLowerCase().trim();
  return byAlias.get(key) ?? byHost.get(stripWww(key)) ?? null;
}

/**
 * A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a leading
 * slash, percent-encoded as the browser's URL parser encodes it, and with a hash route kept, as
 * parsePage keeps it. Null when it is not a path or a URL.
 */
export function recordedPath(input: string): string | null {
  try {
    const url = /^https?:\/\//i.test(input) ? new URL(input) : new URL(input.startsWith("/") ? input : `/${input}`, "https://x.invalid");
    return parsePage(url).path;
  } catch {
    return null;
  }
}

/**
 * A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text is
 * decoded; an encoded slash, space, or other mark that would change the path's meaning stays as it is.
 */
export function readablePath(path: string): string {
  return path.replace(/(?:%[0-9A-Fa-f]{2})+/g, (run) => {
    try {
      const text = decodeURIComponent(run);
      return /[\s/?#%\p{C}]/u.test(text) ? run : text;
    } catch {
      return run;
    }
  });
}

export function parsePage(url: URL): Page {
  const q = url.searchParams;
  let path = url.pathname || "/";
  // The tracker only sends a hash when the site asked for hash routing.
  if (url.hash.length > 1) path += url.hash;
  return {
    hostname: stripWww(url.hostname),
    path: path.slice(0, 1000),
    utm: {
      source: clip(q.get("utm_source")),
      medium: clip(q.get("utm_medium")).toLowerCase(),
      campaign: clip(q.get("utm_campaign")),
      term: clip(q.get("utm_term")),
      content: clip(q.get("utm_content")),
    },
    ref: clip(q.get("ref") ?? q.get("source")),
    paid: CLICK_IDS.some((id) => q.has(id)),
  };
}

/**
 * Where a visit came from. `internalHosts` are the site's own hostnames: a
 * referrer on one of them is navigation within the site, not a source.
 */
export function attribute(page: Page, referrer: string, internalHosts: string[]): Attribution {
  let referrerHost = "";
  let referrerPath = "";
  if (referrer) {
    try {
      const url = new URL(referrer);
      // Android apps refer as android-app://<package>/.
      if (url.protocol === "http:" || url.protocol === "https:" || url.protocol === "android-app:") {
        const host = stripWww(url.hostname);
        if (host !== page.hostname && !internalHosts.includes(host)) {
          referrerHost = host;
          referrerPath = url.protocol === "android-app:" ? "" : url.pathname.slice(0, 500);
        }
      }
    } catch {
      // Not a URL; treat as no referrer.
    }
  }

  const tagged = page.utm.source || page.ref;
  const known = tagged ? sourceForAlias(tagged) : referrerHost ? sourceForHost(referrerHost) : null;
  const source = known?.name ?? (tagged || referrerHost);
  const kind: SourceKind | null = known?.kind ?? (referrerHost ? sourceForHost(referrerHost)?.kind ?? null : null);
  const medium = page.utm.medium;

  let channel: Channel;
  if ((page.paid || PAID_MEDIUMS.test(medium)) && kind === "search") channel = "Paid Search";
  else if (kind === "ai") channel = "AI";
  else if (EMAIL_MEDIUMS.test(medium) || kind === "email") channel = "Email";
  else if (kind === "search") channel = "Organic Search";
  else if (SOCIAL_MEDIUMS.test(medium) || kind === "social") channel = "Social";
  else if (page.utm.source || page.utm.medium || page.utm.campaign) channel = "Campaign";
  else if (referrerHost || page.ref) channel = "Referral";
  else channel = "Direct";

  return { referrerHost, referrerPath, source, channel };
}
