export interface Site {
  id: string;
  name: string;
  hostnames: string[];
  timezone: string;
  /** When the site last recorded a visit, epoch milliseconds. */
  lastSeen?: number | null;
}

export interface Stats {
  visitors: number;
  visits: number;
  pageviews: number;
  viewsPerVisit: number;
  bounceRate: number;
  visitDuration: number;
}

export interface Range {
  from: string;
  to: string;
  interval: "hour" | "day" | "week" | "month";
  timezone: string;
}

export interface Point {
  start: number;
  visitors: number;
  visits: number;
  pageviews: number;
  viewsPerVisit: number;
  bounceRate: number;
  visitDuration: number;
}

export interface Row {
  value: string;
  visitors: number;
  visits?: number;
  pageviews?: number;
  events?: number;
  bounceRate?: number;
  timeOnPage?: number;
  scrollDepth?: number;
  visitDuration?: number;
  fetches?: number;
}

export interface RhythmCell {
  visits: number;
  visitors: number;
  pageviews: number;
  bounceRate: number;
}

export interface Link {
  id: string;
  site: string;
  domain: string;
  slug: string;
  name: string;
  url: string;
  createdAt: number;
  clicks?: number;
  visitors?: number;
}

export interface LinkStats {
  link: Link;
  range: Range;
  clicks: number;
  series: Array<{ start: number; clicks: number; visitors: number }>;
  sources: Row[];
  referrers: Row[];
  countries: Row[];
  devices: Row[];
  browsers: Row[];
}

export interface Realtime {
  visitors: number;
  pages: Array<{ value: string; visitors: number }>;
  sources: Array<{ value: string; visitors: number }>;
  minutes: number[];
}

export interface Filter {
  dimension: string;
  op: "is" | "not" | "contains";
  value: string;
}

export interface View {
  site: string;
  period: string;
  from: string;
  to: string;
  filters: Filter[];
  compare: "previous" | "year" | "custom" | "off";
  compareFrom: string;
  compareTo: string;
}

export const base = document.getElementById("app")?.dataset.base ?? "";

export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

async function get<T>(path: string, params: URLSearchParams): Promise<T> {
  const response = await fetch(`${base}/api/${path}?${params}`, { credentials: "same-origin" });
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new ApiError(response.status, body?.error ?? response.statusText);
  }
  return response.json() as Promise<T>;
}

export function viewParams(view: View): URLSearchParams {
  const params = new URLSearchParams();
  if (view.site) params.set("site", view.site);
  if (view.from && view.to) {
    params.set("from", view.from);
    params.set("to", view.to);
  } else {
    params.set("period", view.period);
  }
  for (const f of view.filters) params.append("filter", `${f.dimension}:${f.op}:${f.value}`);
  // Always sent: the dashboard's default (no comparison) is not the API's.
  params.set("compare", view.compare);
  if (view.compare === "custom") {
    params.set("compare_from", view.compareFrom);
    params.set("compare_to", view.compareTo);
  }
  return params;
}

async function send<T>(method: string, path: string, body: unknown): Promise<T> {
  const response = await fetch(`${base}/api/${path}`, {
    method,
    credentials: "same-origin",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const result = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new ApiError(response.status, result?.error ?? response.statusText);
  }
  return response.json() as Promise<T>;
}

const del = async (path: string) => {
  const response = await fetch(`${base}/api/${path}`, { method: "DELETE", credentials: "same-origin" });
  if (!response.ok) {
    const result = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new ApiError(response.status, result?.error ?? response.statusText);
  }
};

const siteQuery = (site: string) => (site ? `?site=${encodeURIComponent(site)}` : "");

export const api = {
  links: (view: View) => get<{ prefix: string; domains: string[]; links: Link[] }>("links", viewParams(view)),
  link: (view: View, id: string) => get<LinkStats>(`links/${id}`, viewParams(view)),
  createLink: (site: string, input: { url: string; name?: string; slug?: string; domain?: string }) => send<{ link: Link }>("POST", `links${siteQuery(site)}`, input),
  updateLink: (site: string, id: string, input: { url?: string; name?: string; slug?: string; domain?: string }) => send<{ link: Link }>("PATCH", `links/${id}${siteQuery(site)}`, input),
  deleteLink: (site: string, id: string) => del(`links/${id}${siteQuery(site)}`),
  importLinks: (site: string, rows: Array<Record<string, string>>) =>
    send<{ created: number; failed: Array<{ row: number; reason: string }> }>("POST", `links/import${siteQuery(site)}`, { rows }),
  importStep: (site: string, source: string, credentials: Record<string, string>, cursor: string | null, done: number) =>
    send<{ cursor: string | null; done: number; total: number | null; links: number; clicks: number; skipped: number; failed: Array<{ slug: string; reason: string }> }>(
      "POST",
      `links/import/${source}${siteQuery(site)}`,
      { credentials, cursor, done },
    ),
  linkDomains: (site: string) => get<{ domains: string[] }>("link-domains", new URLSearchParams(site ? { site } : {})),
  addLinkDomain: (site: string, domain: string) => send<{ domain: string }>("POST", `link-domains${siteQuery(site)}`, { domain }),
  checkLinkDomain: (site: string, domain: string) =>
    get<{ domain: string; working: boolean; reason: string }>(`link-domains/${encodeURIComponent(domain)}/check`, new URLSearchParams(site ? { site } : {})),
  removeLinkDomain: (site: string, domain: string) => del(`link-domains/${encodeURIComponent(domain)}${siteQuery(site)}`),
  updateSite: (id: string, patch: { name?: string; timezone?: string }) => send<{ site: Site }>("PATCH", `sites/${encodeURIComponent(id)}`, patch),
  sites: () => get<{ sites: Site[] }>("sites", new URLSearchParams()),
  stats: (view: View) => get<{ range: Range; compare?: { from: string; to: string }; stats: Stats; previous?: Stats }>("stats", viewParams(view)),
  series: (view: View) => get<{ range: Range; points: Point[]; previous?: Point[] }>("series", viewParams(view)),
  breakdown: (view: View, dimension: string, limit: number) => {
    const params = viewParams(view);
    params.set("dimension", dimension);
    params.set("limit", String(limit));
    return get<{ rows: Row[] }>("breakdown", params);
  },
  rhythm: (view: View) => get<{ grid: number[][]; cells: RhythmCell[][] }>("rhythm", viewParams(view)),
  realtime: (site: string) => get<Realtime>("realtime", new URLSearchParams(site ? { site } : {})),
};
