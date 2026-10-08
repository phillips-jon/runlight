export interface Site {
  id: string;
  name: string;
  hostnames: string[];
  timezone: string;
  /** When the site last recorded a visit, epoch milliseconds. */
  lastSeen?: number | null;
  /** The address of the Runlight install this site is counted by, when it is connected rather than counted here. */
  remote?: string;
  /** True when the connected install lets this server change the site's settings. */
  manage?: boolean;
  /** How many months of visits the site keeps; null keeps everything. */
  retentionMonths?: number | null;
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
  countries: Array<{ value: string; visitors: number }>;
  minutes: number[];
  recent: Array<{ ts: number; kind: string; path: string; name: string; country: string; city: string; source: string; device: string }>;
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
/** Set when this page is a shared, read-only dashboard; every request carries it. */
export const share = document.getElementById("app")?.dataset.share ?? "";
/** Where the standalone server signs people out; empty in library mode. */
export const signOut = document.getElementById("app")?.dataset.signOut ?? "";
/** Whether this is the standalone server, with accounts and roles. */
export const accounts = document.getElementById("app")?.dataset.accounts !== undefined;

export interface FunnelStep {
  kind: "page" | "event";
  match: string;
}

export interface Funnel {
  id: string;
  name: string;
  steps: Array<FunnelStep & { visits?: number }>;
}

export interface Person {
  id: string;
  email: string;
  role: "owner" | "viewer";
  createdAt: number;
}

/** Whether locations come from DB-IP's free data, which asks to be credited. */
export const geoCredit = document.getElementById("app")?.dataset.geoCredit !== undefined;
/** How this install is run, learned from the sites list: sites managed in the dashboard (the standalone server) or set in code. */
export const install = { managed: false };

export interface Goal {
  id: string;
  site: string;
  name: string;
  kind: "event" | "page" | "click";
  match: string;
  clickBy: "selector" | "link" | "";
  valueMode: "none" | "fixed" | "prop";
  value: number;
  valueProp: string;
  currency: string;
  createdAt: number;
}

export interface GoalTotals {
  conversions: number;
  visitors: number;
  revenue: number;
  rate: number;
}

export type GoalInput = Omit<Goal, "id" | "site" | "createdAt">;

export interface GoalReport {
  range: Range;
  goal: Goal;
  totals: GoalTotals;
  series: Array<{ start: number; conversions: number; revenue: number }>;
  sources: Array<{ value: string } & Omit<GoalTotals, "rate">>;
  channels: Array<{ value: string } & Omit<GoalTotals, "rate">>;
  pages: Array<{ value: string } & Omit<GoalTotals, "rate">>;
}

export interface MailService {
  id: string;
  name: string;
  fields: Array<{ name: string; label: string; secret?: boolean; options?: string[]; optional?: boolean; placeholder?: string }>;
}

export interface MailState {
  source: "code" | "dashboard" | null;
  service: string;
  from: string;
  fromName: string;
  fields: Record<string, string>;
  saved: string[];
  encrypted: boolean;
  services: MailService[];
}

export interface Report {
  id: string;
  site: string;
  email: string;
  frequency: "weekly" | "monthly";
  lang: string;
  lastSentAt: number | null;
  createdAt: number;
}

export interface AssistantProvider {
  id: string;
  name: string;
  protocol: "anthropic" | "openai";
  baseUrl: string;
  model: string;
  key: "yes" | "no" | "optional";
}

/** The assistant's setup: everyone learns whether it is ready; owners also see the provider and model, never the key. */
export interface AssistantState {
  configured: boolean;
  provider?: string;
  model?: string;
  baseUrl?: string;
  keySaved?: boolean;
  encrypted?: boolean;
  providers?: AssistantProvider[];
}

/** The paths visits take, a column per step. "" is any other page. */
export interface JourneyAnswer {
  visits: number;
  columns: Array<{ items: Array<{ value: string; visits: number }>; visits: number; left: number }>;
  links: Array<{ step: number; from: string; to: string; visits: number }>;
  paths: Array<{ pages: string[]; visits: number }>;
}

export interface ApiToken {
  id: string;
  name: string;
  /** "" for every site. */
  site: string;
  /** "manage" also changes its site's settings, for a Runlight hub. */
  scope?: "read" | "manage";
  hint: string;
  createdAt: number;
  lastUsedAt: number | null;
}

export interface Share {
  id: string;
  site: string;
  name: string;
  createdAt: number;
  path: string;
}

export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

async function get<T>(path: string, params: URLSearchParams): Promise<T> {
  const response = await fetch(`${base}/api/${path}?${params}`, {
    credentials: "same-origin",
    headers: share ? { "x-runlight-share": share } : undefined,
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new ApiError(response.status, body?.error ?? response.statusText);
  }
  return response.json() as Promise<T>;
}

/** Fetches a file from the API (with a share's header when there is one) and saves it under the server's name. */
export async function download(path: string, params: URLSearchParams): Promise<void> {
  const response = await fetch(`${base}/api/${path}?${params}`, {
    credentials: "same-origin",
    headers: share ? { "x-runlight-share": share } : undefined,
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new ApiError(response.status, body?.error ?? response.statusText);
  }
  const name = /filename="([^"]+)"/.exec(response.headers.get("content-disposition") ?? "")?.[1] ?? "runlight-export";
  const link = document.createElement("a");
  link.href = URL.createObjectURL(await response.blob());
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 10_000);
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
  observeKey: (site: string) => get<{ key: string }>("observe-key", new URLSearchParams({ site })),
  newObserveKey: (site: string) => send<{ key: string }>("POST", `observe-key/new${siteQuery(site)}`, {}),
  funnels: (view: View) => get<{ funnels: Funnel[] }>("funnels", viewParams(view)),
  saveFunnel: (site: string, id: string | null, funnel: { name: string; steps: FunnelStep[] }) =>
    send<{ funnel: Funnel }>(id ? "PATCH" : "POST", `funnels${id ? `/${id}` : ""}${siteQuery(site)}`, funnel),
  deleteFunnel: (site: string, id: string) => del(`funnels/${id}${siteQuery(site)}`),
  account: () => get<{ account: Person }>("account", new URLSearchParams()),
  changePassword: (current: string, next: string) => send<{ ok: true }>("POST", "account/password", { current, next }),
  people: () => get<{ people: Person[] }>("people", new URLSearchParams()),
  addPerson: (email: string, role: Person["role"]) => send<{ person: Person; password: string }>("POST", "people", { email, role }),
  setRole: (id: string, role: Person["role"]) => send<{ person: Person }>("PATCH", `people/${id}`, { role }),
  removePerson: (id: string) => del(`people/${id}`),
  eventProps: (view: View, event: string, key: string | null) => {
    const params = viewParams(view);
    params.set("event", event);
    if (key) params.set("key", key);
    return get<{ event: string; keys: Array<{ key: string; events: number }>; key: string | null; rows: Array<{ value: string; events: number; visitors: number }> }>("event-props", params);
  },
  umamiWebsites: (credentials: Record<string, string>) => send<{ websites: Array<{ id: string; name: string; domain: string }> }>("POST", "import/umami/websites", { credentials }),
  importVisits: (site: string, credentials: Record<string, string>, website: string, cursor: string | null) =>
    send<{ cursor: string | null; done: number; total: number; pageviews: number; events: number; visits: number }>("POST", `import/umami/visits${siteQuery(site)}`, { credentials, website, cursor }),
  goals: (view: View) =>
    get<{ visitors: number; goals: Array<Goal & GoalTotals & { previous?: GoalTotals }> }>("goals", viewParams(view)),
  goal: (view: View, id: string) => get<GoalReport>(`goals/${id}`, viewParams(view)),
  createGoal: (site: string, input: GoalInput) => send<{ goal: Goal }>("POST", `goals${siteQuery(site)}`, input),
  updateGoal: (site: string, id: string, input: GoalInput) => send<{ goal: Goal }>("PATCH", `goals/${id}${siteQuery(site)}`, input),
  deleteGoal: (site: string, id: string) => del(`goals/${id}${siteQuery(site)}`),
  // A connected site's reports go out through its own install's mail service.
  mail: (site?: string) => get<MailState>("mail", new URLSearchParams(site ? { site } : {})),
  connect: (url: string) => send<{ authorize: string }>("POST", "sites/connect", { url }),
  assistant: () => get<AssistantState>("assistant", new URLSearchParams()),
  saveAssistant: (input: { provider: string; model: string; baseUrl: string; key: string }) => send<{ ok: true }>("PUT", "assistant", input),
  removeAssistant: () => del("assistant"),
  ask: (site: string, messages: Array<{ role: "user" | "assistant"; content: string }>, view: string, language: string) =>
    send<{ reply: string; tools: string[] }>("POST", "assistant/chat", { site, messages, view, language }),
  saveMail: (input: Record<string, string>) => send<{ ok: true }>("PUT", "mail", input),
  removeMail: () => del("mail"),
  testMail: (to: string, lang: string) => send<{ ok: true }>("POST", "mail/test", { to, lang }),
  reports: (site: string) => get<{ reports: Report[]; languages: string[] }>("reports", new URLSearchParams(site ? { site } : {})),
  addReport: (site: string, input: { email: string; frequency: string; lang: string; origin: string }) => send<{ report: Report }>("POST", `reports${siteQuery(site)}`, input),
  deleteReport: (site: string, id: string) => del(`reports/${id}${siteQuery(site)}`),
  sendReport: (site: string, id: string) => send<{ ok: true }>("POST", `reports/${id}/send${siteQuery(site)}`, {}),
  tokens: () => get<{ tokens: ApiToken[] }>("tokens", new URLSearchParams()),
  createToken: (name: string, site: string) => send<{ token: ApiToken; secret: string }>("POST", "tokens", { name, site }),
  deleteToken: (id: string) => del(`tokens/${id}`),
  shares: (site: string) => get<{ shares: Share[] }>("shares", new URLSearchParams(site ? { site } : {})),
  createShare: (site: string, name: string) => send<{ share: Share }>("POST", `shares${siteQuery(site)}`, { name }),
  renameShare: (site: string, id: string, name: string) => send<{ share: Share }>("PATCH", `shares/${id}${siteQuery(site)}`, { name }),
  deleteShare: (site: string, id: string) => del(`shares/${id}${siteQuery(site)}`),
  linkDomains: (site: string) => get<{ domains: string[] }>("link-domains", new URLSearchParams(site ? { site } : {})),
  addLinkDomain: (site: string, domain: string) => send<{ domain: string }>("POST", `link-domains${siteQuery(site)}`, { domain }),
  checkLinkDomain: (site: string, domain: string) =>
    get<{ domain: string; working: boolean; reason: string }>(`link-domains/${encodeURIComponent(domain)}/check`, new URLSearchParams(site ? { site } : {})),
  removeLinkDomain: (site: string, domain: string) => del(`link-domains/${encodeURIComponent(domain)}${siteQuery(site)}`),
  updateSite: (id: string, patch: { name?: string; timezone?: string; hostnames?: string; retentionMonths?: number | null }) => send<{ site: Site }>("PATCH", `sites/${encodeURIComponent(id)}`, patch),
  sites: () =>
    get<{ sites: Site[]; managed?: boolean }>("sites", new URLSearchParams()).then((r) => {
      install.managed = Boolean(r.managed);
      return r;
    }),
  addSite: (site: { name: string; hostnames?: string; timezone?: string; remote?: { url: string; token: string } }) => send<{ site: Site }>("POST", "sites", site),
  deleteSite: (id: string) => del(`sites/${encodeURIComponent(id)}`),
  stats: (view: View) => get<{ range: Range; compare?: { from: string; to: string }; stats: Stats; previous?: Stats }>("stats", viewParams(view)),
  series: (view: View) => get<{ range: Range; points: Point[]; previous?: Point[] }>("series", viewParams(view)),
  breakdown: (view: View, dimension: string, limit: number) => {
    const params = viewParams(view);
    params.set("dimension", dimension);
    params.set("limit", String(limit));
    return get<{ rows: Row[] }>("breakdown", params);
  },
  rhythm: (view: View) => get<{ grid: number[][]; cells: RhythmCell[][] }>("rhythm", viewParams(view)),
  journeys: (view: View, options: { steps: number; start: string; end: string; through: { step: number; value: string } | null }) => {
    const params = viewParams(view);
    params.set("steps", String(options.steps));
    if (options.start) params.set("start", options.start);
    if (options.end) params.set("end", options.end);
    if (options.through) params.set("through", `${options.through.step}:${options.through.value}`);
    return get<JourneyAnswer>("journeys", params);
  },
  realtime: (site: string) => get<Realtime>("realtime", new URLSearchParams(site ? { site } : {})),
};
