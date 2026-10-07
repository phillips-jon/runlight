import { render } from "preact";
import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import { ApiError, api, base, type Filter, type Point, type Range, type Site, type Stats, type View } from "./api.js";
import { Chart, Spark } from "./chart.js";
import { change, exact } from "./format.js";
import { MAX_CHARTED, METRICS, metric, type MetricKey } from "./metrics.js";
import { FIELD_NAMES, FilterDrawer } from "./filters.js";
import { Panel, Rhythm, bounce, label, timeOnPage, type Tab } from "./panel.js";
import { DEFAULT_PERIOD, Picker, rangeText } from "./picker.js";
import "./style.css";

/** How a period reads inside a sentence, and what it is compared with. */
const PHRASES: Record<string, [string, string]> = {
  today: ["today", "yesterday"],
  yesterday: ["yesterday", "the day before"],
  "7d": ["in the last 7 days", "the 7 days before"],
  "30d": ["in the last 30 days", "the 30 days before"],
  "90d": ["in the last 90 days", "the 90 days before"],
  month: ["this month", "the same stretch before it"],
  last_month: ["last month", "the month before"],
  year: ["this year", "the same stretch before it"],
  "12mo": ["in the last 12 months", "the 12 months before"],
  all: ["since tracking began", ""],
};

function readView(): View {
  const q = new URLSearchParams(location.search);
  const filters: Filter[] = [];
  for (const raw of q.getAll("filter")) {
    const [dimension, op, ...rest] = raw.split(":");
    if (dimension && (op === "is" || op === "not" || op === "contains")) filters.push({ dimension, op, value: rest.join(":") });
  }
  return { site: q.get("site") ?? "", period: q.get("period") ?? DEFAULT_PERIOD, from: q.get("from") ?? "", to: q.get("to") ?? "", filters };
}

function readCharted(): MetricKey[] {
  const keys = (new URLSearchParams(location.search).get("chart") ?? "").split(",").filter((k) => metric(k)) as MetricKey[];
  return keys.length ? keys.slice(0, MAX_CHARTED) : ["visitors"];
}

function writeUrl(view: View, charted: MetricKey[]) {
  const q = new URLSearchParams();
  if (view.site) q.set("site", view.site);
  if (view.from && view.to) {
    q.set("from", view.from);
    q.set("to", view.to);
  } else if (view.period !== DEFAULT_PERIOD) {
    q.set("period", view.period);
  }
  for (const f of view.filters) q.append("filter", `${f.dimension}:${f.op}:${f.value}`);
  if (charted.join(",") !== "visitors") q.set("chart", charted.join(","));
  const search = q.toString();
  history.replaceState(null, "", search ? `?${search}` : location.pathname);
}

function todayIn(timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

function Delta({ now, before, lowerIsBetter }: { now: number; before: number | undefined; lowerIsBetter?: boolean }) {
  const c = change(now, before);
  if (c === null) return <span class="delta" />;
  const flat = Math.abs(c) < 0.005;
  const good = lowerIsBetter ? c < 0 : c > 0;
  return (
    <span class={`delta ${flat ? "flat" : good ? "up" : "down"}`} title="Against the previous period">
      {flat ? "no change" : `${c > 0 ? "↑" : "↓"} ${Math.abs(Math.round(c * 100))}%`}
    </span>
  );
}

function Avatar({ site }: { site: Site }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [site.id]);
  const letter = (site.name.replace(/^www\./, "")[0] ?? "R").toUpperCase();
  return failed ? (
    <span class="avatar letter" aria-hidden="true">
      {letter}
    </span>
  ) : (
    <img class="avatar" src={`${base}/api/icon?site=${encodeURIComponent(site.id)}`} alt="" width={40} height={40} onError={() => setFailed(true)} />
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
      {n} here now
    </span>
  );
}

function Headline({ view, stats, previous }: { view: View; stats: Stats; previous?: Stats }) {
  const phrase = view.from ? [`between ${rangeText(view.from, view.to)}`, "the same stretch before"] : PHRASES[view.period] ?? PHRASES[DEFAULT_PERIOD]!;
  const c = change(stats.visitors, previous?.visitors);
  const who = stats.visitors === 1 ? "person" : "people";
  const verb = view.filters.length ? "matched these filters" : "visited";
  return (
    <p class="headline">
      <strong>
        {exact(stats.visitors)} {who}
      </strong>{" "}
      {verb} {phrase[0]}
      {c !== null && phrase[1] && Math.abs(c) >= 0.005 ? (
        <>
          , <span class={c > 0 ? "up" : "down"}>{Math.abs(Math.round(c * 100))}% {c > 0 ? "more" : "fewer"}</span> than {phrase[1]}.
        </>
      ) : (
        "."
      )}
    </p>
  );
}

function App() {
  const [sites, setSites] = useState<Site[] | null>(null);
  const [view, setView] = useState<View>(readView);
  const [charted, setCharted] = useState<MetricKey[]>(readCharted);
  const [stats, setStats] = useState<{ range: Range; stats: Stats; previous?: Stats } | null>(null);
  const [points, setPoints] = useState<Point[]>([]);
  const [failure, setFailure] = useState("");
  const [filtering, setFiltering] = useState(false);

  const fail = (e: Error) => setFailure(e instanceof ApiError && e.status === 401 ? "signed-out" : e.message);

  useEffect(() => {
    api.sites().then((r) => setSites(r.sites)).catch(fail);
  }, []);

  useEffect(() => {
    writeUrl(view, charted);
  }, [view, charted]);

  useEffect(() => {
    let live = true;
    Promise.all([api.stats(view), api.series(view)])
      .then(([s, series]) => {
        if (!live) return;
        setFailure("");
        setStats(s);
        setPoints(series.points);
      })
      .catch((e: Error) => live && fail(e));
    return () => {
      live = false;
    };
  }, [view]);

  const update = useCallback((patch: Partial<View>) => setView((v) => ({ ...v, ...patch })), []);
  const addFilter = useCallback(
    (dimension: string, value: string) =>
      setView((v) => ({ ...v, filters: [...v.filters.filter((f) => f.dimension !== dimension), { dimension, op: "is", value }] })),
    [],
  );
  const toggleMetric = (key: MetricKey) =>
    setCharted((current) => {
      if (current.includes(key)) return current.length > 1 ? current.filter((k) => k !== key) : current;
      const next = [...current, key];
      return next.length > MAX_CHARTED ? next.slice(next.length - MAX_CHARTED) : next;
    });

  const site = sites?.find((s) => s.id === view.site) ?? sites?.[0];
  const panels = useMemo(layout, []);
  const today = todayIn(site?.timezone ?? "UTC");

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

  const shownMetrics = METRICS.filter((m) => charted.includes(m.key));

  return (
    <main>
      <header class="hero">
        <div class="hero-top">
          <div class="identity">
            {site ? <Avatar site={site} /> : <span class="avatar letter" />}
            <div class="identity-text">
              {sites && sites.length > 1 ? (
                <label class="site-select">
                  <span class="visually-hidden">Site</span>
                  <select value={site?.id} onChange={(e) => update({ site: (e.target as HTMLSelectElement).value, filters: [] })}>
                    {sites.map((x) => (
                      <option value={x.id}>{x.name}</option>
                    ))}
                  </select>
                </label>
              ) : (
                <h1>{site?.name ?? "Runlight"}</h1>
              )}
              {site ? <Live site={site.id} /> : null}
            </div>
          </div>
          <div class="actions">
          <button type="button" class={view.filters.length ? "filter-button on" : "filter-button"} onClick={() => setFiltering(true)}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M2.5 3.5h11M4.5 8h7M6.5 12.5h3" />
            </svg>
            Filter{view.filters.length ? <span class="count">{view.filters.length}</span> : null}
          </button>
          <Picker
            period={view.period}
            from={view.from}
            to={view.to}
            today={today}
            onPeriod={(period) => update({ period, from: "", to: "" })}
            onRange={(from, to) => update({ from, to })}
          />
          </div>
        </div>
        {stats ? <Headline view={view} stats={stats.stats} previous={stats.previous} /> : <p class="headline">&nbsp;</p>}
        {view.filters.length ? (
          <div class="filters">
            {view.filters.map((f) => (
              <span class="filter">
                <span class="filter-dim">{FIELD_NAMES[f.dimension] ?? f.dimension}</span>
                {f.op === "is" ? "is" : f.op === "not" ? "is not" : "contains"} <strong>{label(f.dimension, f.value)}</strong>
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
      </header>

      {failure ? <p class="failure">{failure}</p> : null}
      {filtering ? <FilterDrawer view={view} onApply={(filters) => update({ filters })} onClose={() => setFiltering(false)} /> : null}

      <section class="overview">
        <div class="metrics">
          {METRICS.map((m) => {
            const on = charted.includes(m.key);
            const value = stats?.stats[m.key];
            return (
              <button type="button" class={`metric s${m.slot}${on ? " on" : ""}`} aria-pressed={on} onClick={() => toggleMetric(m.key)} title={m.hint}>
                <span class="metric-label">
                  <span class={`swatch s${m.slot}`} />
                  {m.label}
                </span>
                <span class="metric-value">{value === undefined ? " " : m.format(value)}</span>
                <span class="metric-foot">
                  {stats ? <Delta now={stats.stats[m.key]} before={stats.previous?.[m.key]} lowerIsBetter={m.lowerIsBetter} /> : null}
                  <Spark points={points} metric={m} on={on} />
                </span>
              </button>
            );
          })}
        </div>
        <div class="chart-head">
          <div class="legend">
            {shownMetrics.map((m) => (
              <span>
                <span class={`swatch s${m.slot}`} />
                {m.label}
              </span>
            ))}
          </div>
          <span class="chart-note">
            {shownMetrics.length > 1 ? "Each line is scaled to its own peak. Hover for values." : `Pick up to ${MAX_CHARTED} cards to compare.`}
          </span>
        </div>
        {stats ? <Chart points={points} metrics={shownMetrics} interval={stats.range.interval} timezone={stats.range.timezone} /> : <div class="chart" />}
      </section>

      <div class="board">
        {panels.map((panel, i) =>
          panel.title === "When people visit" ? (
            <Rhythm view={view} wide={panel.wide} />
          ) : (
            <Panel title={panel.title} tabs={panel.tabs} view={view} onFilter={addFilter} wide={panel.wide} map={panel.title === "Locations"} key={i} />
          ),
        )}
      </div>

      <footer class="foot">
        <a href="https://runlight.sh" class="powered">
          Powered by <span>Runlight</span>
        </a>
        <span class="foot-range">{stats ? `${rangeText(stats.range.from, stats.range.to)} · ${stats.range.timezone}` : ""}</span>
        <Theme />
      </footer>
    </main>
  );
}

const CHANNEL_COLORS: Record<string, number> = {
  "Organic Search": 1,
  Social: 2,
  Direct: 3,
  Email: 4,
  Referral: 5,
  "Paid Search": 6,
  AI: 7,
  Campaign: 8,
};
const DEVICE_COLORS: Record<string, number> = { desktop: 1, mobile: 2, tablet: 3 };
const LIVE_AGENTS = new Set(["ChatGPT-User", "Claude-User", "Perplexity-User", "MistralAI-User", "meta-externalfetcher"]);

function layout(): Array<{ title: string; tabs: Tab[]; wide?: boolean }> {
  const f = { filterable: true };
  // Wide and narrow alternate row by row, so the board reads as a zigzag.
  return [
    {
      title: "Pages",
      wide: true,
      tabs: [
        { dimension: "page", label: "Top", ...f, extra: timeOnPage },
        { dimension: "entry", label: "Entry", ...f, extra: bounce },
        { dimension: "exit", label: "Exit", ...f },
      ],
    },
    {
      title: "Sources",
      tabs: [
        { dimension: "channel", label: "Channels", ...f, colors: CHANNEL_COLORS },
        { dimension: "source", label: "Sources", ...f },
        { dimension: "referrer", label: "Referrers", ...f },
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
    { title: "When people visit", wide: true, tabs: [] },
    {
      title: "AI agents",
      wide: true,
      tabs: [
        { dimension: "ai_agent", label: "Agents", column: "fetches", groups: { of: (v) => (LIVE_AGENTS.has(v) ? "Live fetches" : "Crawls"), slots: { "Live fetches": 7, Crawls: 1 } } },
        { dimension: "ai_page", label: "Pages", column: "fetches" },
      ],
    },
    {
      title: "Devices",
      tabs: [
        { dimension: "device", label: "Device", ...f, colors: DEVICE_COLORS },
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
      title: "Campaigns",
      wide: true,
      tabs: [
        { dimension: "utm_campaign", label: "Campaign", ...f },
        { dimension: "utm_source", label: "Source", ...f },
        { dimension: "utm_medium", label: "Medium", ...f },
        { dimension: "utm_content", label: "Content", ...f },
        { dimension: "utm_term", label: "Term", ...f },
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
      aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
      title={dark ? "Light theme" : "Dark theme"}
      onClick={() => {
        const next = dark ? "light" : "dark";
        setTheme(next);
        try {
          localStorage.setItem("runlight_theme", next);
        } catch {}
      }}
    >
      {dark ? (
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <circle cx="10" cy="10" r="3.6" />
          <path d="M10 1.8v2.2M10 16v2.2M1.8 10H4M16 10h2.2M4.2 4.2l1.6 1.6M14.2 14.2l1.6 1.6M4.2 15.8l1.6-1.6M14.2 5.8l1.6-1.6" />
        </svg>
      ) : (
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <path d="M16.5 12.6A7 7 0 0 1 7.4 3.5a7 7 0 1 0 9.1 9.1z" />
        </svg>
      )}
    </button>
  );
}

render(<App />, document.getElementById("app")!);
