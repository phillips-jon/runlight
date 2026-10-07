import { render } from "preact";
import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import { ApiError, api, type Filter, type Point, type Range, type Site, type Stats, type View } from "./api.js";
import { Chart, type Metric } from "./chart.js";
import { change, count, duration, exact, percent } from "./format.js";
import { Panel, bounce, label, timeOnPage, type Tab } from "./panel.js";
import "./style.css";

const PERIODS: Array<[string, string]> = [
  ["today", "Today"],
  ["yesterday", "Yesterday"],
  ["7d", "Last 7 days"],
  ["30d", "Last 30 days"],
  ["90d", "Last 90 days"],
  ["month", "This month"],
  ["last_month", "Last month"],
  ["year", "This year"],
  ["12mo", "Last 12 months"],
  ["all", "All time"],
];

const DIMENSION_NAMES: Record<string, string> = {
  page: "Page",
  entry: "Entry page",
  exit: "Exit page",
  hostname: "Hostname",
  referrer: "Referrer",
  source: "Source",
  channel: "Channel",
  utm_source: "UTM source",
  utm_medium: "UTM medium",
  utm_campaign: "Campaign",
  utm_term: "UTM term",
  utm_content: "UTM content",
  country: "Country",
  region: "Region",
  city: "City",
  browser: "Browser",
  browser_version: "Browser version",
  os: "OS",
  os_version: "OS version",
  device: "Device",
  screen: "Screen",
  language: "Language",
  event: "Event",
};

function readView(): View {
  const q = new URLSearchParams(location.search);
  const filters: Filter[] = [];
  for (const raw of q.getAll("filter")) {
    const [dimension, op, ...rest] = raw.split(":");
    if (dimension && (op === "is" || op === "not" || op === "contains")) filters.push({ dimension, op, value: rest.join(":") });
  }
  return { site: q.get("site") ?? "", period: q.get("period") ?? "30d", from: q.get("from") ?? "", to: q.get("to") ?? "", filters };
}

function writeView(view: View) {
  const q = new URLSearchParams();
  if (view.site) q.set("site", view.site);
  if (view.from && view.to) {
    q.set("from", view.from);
    q.set("to", view.to);
  } else if (view.period !== "30d") {
    q.set("period", view.period);
  }
  for (const f of view.filters) q.append("filter", `${f.dimension}:${f.op}:${f.value}`);
  const search = q.toString();
  history.replaceState(null, "", search ? `?${search}` : location.pathname);
}

function Delta({ now, before, lowerIsBetter }: { now: number; before: number | undefined; lowerIsBetter?: boolean }) {
  const c = change(now, before);
  if (c === null) return <span class="delta none" />;
  const good = lowerIsBetter ? c < 0 : c > 0;
  const flat = Math.abs(c) < 0.005;
  return (
    <span class={`delta ${flat ? "flat" : good ? "up" : "down"}`} title="Against the previous period">
      {flat ? "0%" : `${c > 0 ? "+" : ""}${Math.round(c * 100)}%`}
    </span>
  );
}

function Live({ site }: { site: string }) {
  const [n, setN] = useState<number | null>(null);
  useEffect(() => {
    let live = true;
    const load = () => api.realtime(site).then((r) => live && setN(r.visitors)).catch(() => {});
    load();
    const timer = setInterval(load, 30_000);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [site]);
  if (n === null) return null;
  return (
    <span class="live" title="Visitors in the last five minutes">
      <span class={n > 0 ? "beat on" : "beat"} aria-hidden="true" />
      {n} {n === 1 ? "visitor" : "visitors"} now
    </span>
  );
}

function App() {
  const [sites, setSites] = useState<Site[] | null>(null);
  const [view, setView] = useState<View>(readView);
  const [metric, setMetric] = useState<Metric>("visitors");
  const [stats, setStats] = useState<{ range: Range; stats: Stats; previous?: Stats } | null>(null);
  const [points, setPoints] = useState<Point[]>([]);
  const [failure, setFailure] = useState("");

  useEffect(() => {
    api
      .sites()
      .then((r) => setSites(r.sites))
      .catch((e: Error) => setFailure(e instanceof ApiError && e.status === 401 ? "signed-out" : e.message));
  }, []);

  useEffect(() => {
    writeView(view);
    let live = true;
    Promise.all([api.stats(view), api.series(view)])
      .then(([s, series]) => {
        if (!live) return;
        setStats(s);
        setPoints(series.points);
      })
      .catch((e: Error) => live && setFailure(e instanceof ApiError && e.status === 401 ? "signed-out" : e.message));
    return () => {
      live = false;
    };
  }, [view]);

  const update = useCallback((patch: Partial<View>) => setView((v) => ({ ...v, ...patch })), []);
  const addFilter = useCallback(
    (dimension: string, value: string) =>
      setView((v) => ({
        ...v,
        filters: [...v.filters.filter((f) => f.dimension !== dimension), { dimension, op: "is", value }],
      })),
    [],
  );

  const site = sites?.find((s) => s.id === view.site) ?? sites?.[0];
  const panels = useMemo(() => layout(), []);

  if (failure === "signed-out") {
    return (
      <main class="signed-out">
        <h1>Runlight</h1>
        <p>
          Open this page once with <code>?token=</code> followed by your <code>RUNLIGHT_TOKEN</code> to sign in.
        </p>
      </main>
    );
  }

  const s = stats?.stats;
  const p = stats?.previous;
  const metrics: Array<{ key: string; label: string; value: string; now: number; before?: number; chart?: Metric; lowerIsBetter?: boolean; title?: string }> = s
    ? [
        { key: "visitors", label: "Visitors", value: count(s.visitors), now: s.visitors, before: p?.visitors, chart: "visitors", title: exact(s.visitors) },
        { key: "visits", label: "Visits", value: count(s.visits), now: s.visits, before: p?.visits, chart: "visits", title: exact(s.visits) },
        { key: "pageviews", label: "Pageviews", value: count(s.pageviews), now: s.pageviews, before: p?.pageviews, chart: "pageviews", title: exact(s.pageviews) },
        { key: "vpv", label: "Views per visit", value: s.viewsPerVisit.toFixed(1), now: s.viewsPerVisit, before: p?.viewsPerVisit },
        { key: "bounce", label: "Bounce rate", value: percent(s.bounceRate), now: s.bounceRate, before: p?.bounceRate, lowerIsBetter: true },
        { key: "duration", label: "Visit duration", value: duration(s.visitDuration), now: s.visitDuration, before: p?.visitDuration },
      ]
    : [];

  return (
    <main>
      <header class="top">
        <div class="site">
          <span class="mark" aria-hidden="true" />
          {sites && sites.length > 1 ? (
            <select aria-label="Site" value={site?.id} onChange={(e) => update({ site: (e.target as HTMLSelectElement).value, filters: [] })}>
              {sites.map((x) => (
                <option value={x.id}>{x.name}</option>
              ))}
            </select>
          ) : (
            <h1>{site?.name ?? "Runlight"}</h1>
          )}
          {site ? <Live site={site.id} /> : null}
        </div>
        <div class="controls">
          <select
            aria-label="Date range"
            value={view.from ? "custom" : view.period}
            onChange={(e) => update({ period: (e.target as HTMLSelectElement).value, from: "", to: "" })}
          >
            {PERIODS.map(([value, text]) => (
              <option value={value}>{text}</option>
            ))}
            {view.from ? <option value="custom">{`${view.from} to ${view.to}`}</option> : null}
          </select>
          <Theme />
        </div>
      </header>

      {view.filters.length ? (
        <div class="filters">
          {view.filters.map((f) => (
            <span class="filter">
              <span class="filter-dim">{DIMENSION_NAMES[f.dimension] ?? f.dimension}</span> {f.op === "is" ? "is" : f.op === "not" ? "is not" : "contains"}{" "}
              <strong>{label(f.dimension, f.value)}</strong>
              <button type="button" aria-label="Remove filter" onClick={() => update({ filters: view.filters.filter((x) => x !== f) })}>
                ×
              </button>
            </span>
          ))}
          {view.filters.length > 1 ? (
            <button type="button" class="clear" onClick={() => update({ filters: [] })}>
              Clear all
            </button>
          ) : null}
        </div>
      ) : null}

      {failure ? <p class="failure">{failure}</p> : null}

      <section class="overview">
        <div class="metrics">
          {metrics.map((m) => (
            <button
              type="button"
              class={m.chart && m.chart === metric ? "metric on" : "metric"}
              disabled={!m.chart}
              onClick={() => m.chart && setMetric(m.chart)}
              title={m.title}
            >
              <span class="metric-label">{m.label}</span>
              <span class="metric-value">{m.value}</span>
              <Delta now={m.now} before={m.before} lowerIsBetter={m.lowerIsBetter} />
            </button>
          ))}
        </div>
        {stats ? <Chart points={points} metric={metric} interval={stats.range.interval} timezone={stats.range.timezone} /> : <div class="chart" />}
      </section>

      <div class="grid">
        {panels.map((panel) => (
          <Panel title={panel.title} tabs={panel.tabs} view={view} onFilter={addFilter} />
        ))}
      </div>

      <footer class="foot">
        <span>Runlight</span>
        <span>{stats ? `${stats.range.from} to ${stats.range.to}, ${stats.range.timezone}` : ""}</span>
      </footer>
    </main>
  );
}

function layout(): Array<{ title: string; tabs: Tab[] }> {
  const f = { filterable: true };
  return [
    {
      title: "Sources",
      tabs: [
        { dimension: "channel", label: "Channels", ...f },
        { dimension: "source", label: "Sources", ...f },
        { dimension: "referrer", label: "Referrers", ...f },
      ],
    },
    {
      title: "Pages",
      tabs: [
        { dimension: "page", label: "Top", ...f, extra: timeOnPage },
        { dimension: "entry", label: "Entry", ...f, extra: bounce },
        { dimension: "exit", label: "Exit", ...f },
      ],
    },
    {
      title: "Campaigns",
      tabs: [
        { dimension: "utm_campaign", label: "Campaign", ...f },
        { dimension: "utm_source", label: "Source", ...f },
        { dimension: "utm_medium", label: "Medium", ...f },
        { dimension: "utm_content", label: "Content", ...f },
        { dimension: "utm_term", label: "Term", ...f },
      ],
    },
    {
      title: "Locations",
      tabs: [
        { dimension: "country", label: "Countries", ...f },
        { dimension: "region", label: "Regions", ...f },
        { dimension: "city", label: "Cities", ...f },
      ],
    },
    {
      title: "Devices",
      tabs: [
        { dimension: "device", label: "Device", ...f },
        { dimension: "browser", label: "Browser", ...f },
        { dimension: "os", label: "OS", ...f },
        { dimension: "screen", label: "Screen", ...f },
        { dimension: "language", label: "Language", ...f },
      ],
    },
    {
      title: "Events",
      tabs: [{ dimension: "event", label: "Event", column: "events", ...f }],
    },
    {
      title: "AI agents",
      tabs: [
        { dimension: "ai_agent", label: "Agents", column: "fetches" },
        { dimension: "ai_page", label: "Pages", column: "fetches" },
      ],
    },
  ];
}

function Theme() {
  const stored = (() => {
    try {
      return localStorage.getItem("runlight_theme");
    } catch {
      return null;
    }
  })();
  const [theme, setTheme] = useState<string | null>(stored);
  useEffect(() => {
    if (theme) document.documentElement.dataset.theme = theme;
    else delete document.documentElement.dataset.theme;
  }, [theme]);
  const dark = theme ? theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  return (
    <button
      type="button"
      class="theme"
      aria-label={dark ? "Use light theme" : "Use dark theme"}
      onClick={() => {
        const next = dark ? "light" : "dark";
        setTheme(next);
        try {
          localStorage.setItem("runlight_theme", next);
        } catch {}
      }}
    >
      {dark ? "Light" : "Dark"}
    </button>
  );
}

render(<App />, document.getElementById("app")!);
