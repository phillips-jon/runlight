export interface Site {
  id: string;
  name: string;
  hostnames: string[];
  timezone: string;
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
  fetches?: number;
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
  if (view.compare !== "previous") params.set("compare", view.compare);
  if (view.compare === "custom") {
    params.set("compare_from", view.compareFrom);
    params.set("compare_to", view.compareTo);
  }
  return params;
}

export const api = {
  sites: () => get<{ sites: Site[] }>("sites", new URLSearchParams()),
  stats: (view: View) => get<{ range: Range; compare?: { from: string; to: string }; stats: Stats; previous?: Stats }>("stats", viewParams(view)),
  series: (view: View) => get<{ range: Range; points: Point[]; previous?: Point[] }>("series", viewParams(view)),
  breakdown: (view: View, dimension: string, limit: number) => {
    const params = viewParams(view);
    params.set("dimension", dimension);
    params.set("limit", String(limit));
    return get<{ rows: Row[] }>("breakdown", params);
  },
  rhythm: (view: View) => get<{ grid: number[][] }>("rhythm", viewParams(view)),
  realtime: (site: string) => get<Realtime>("realtime", new URLSearchParams(site ? { site } : {})),
};
