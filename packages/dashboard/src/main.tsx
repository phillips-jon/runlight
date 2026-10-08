import { render } from "preact";
import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import { ApiError, accounts, api, base, download, install, share, viewParams, type Person, signOut, type Filter, type Point, type Range, type Site, type Stats, type View } from "./api.js";
import { Chart, asSeries } from "./chart.js";
import { change, exact } from "./format.js";
import { FilterDrawer, fieldName, opName } from "./filters.js";
import { Icon } from "./icons.js";
import { LANGUAGES, currentLocale, initialLocale, rich, setLocale, t, tn, type Key } from "./i18n.js";
import { MAX_CHARTED, METRICS, metric, metricHint, metricLabel, type MetricKey } from "./metrics.js";
import { LinksPanel, Sheet } from "./links.js";
import { AddSiteForm, AllSites, FirstSite, SiteMenu } from "./sites.js";
import { AccountSheet } from "./account.js";
import { AssistantDrawer } from "./assistant.js";
import { Panel, Rhythm, bounce, label, timeOnPage, type Tab } from "./panel.js";
import { ComparePicker, DEFAULT_PERIOD, PERIODS, Picker, rangeText, type CompareMode } from "./picker.js";
import { RealtimeModal } from "./realtime.js";
import { ConversionsPanel } from "./goals.js";
import { Install, SettingsModal, type Section } from "./settings.js";
import { applyTheme, isDark, onThemeChange, setTheme, themeChoice, type ThemeChoice } from "./theme.js";
import "./style.css";

/** A fresh dashboard compares with nothing; the cards show changes once a comparison is picked. */
const DEFAULT_COMPARE: CompareMode = "off";

function readView(): View {
  const q = new URLSearchParams(location.search);
  const filters: Filter[] = [];
  for (const raw of q.getAll("filter")) {
    const [dimension, op, ...rest] = raw.split(":");
    if (dimension && (op === "is" || op === "not" || op === "contains")) filters.push({ dimension, op, value: rest.join(":") });
  }
  const compare = (["previous", "year", "custom", "off"].includes(q.get("compare") ?? "") ? q.get("compare") : DEFAULT_COMPARE) as CompareMode;
  const compareFrom = q.get("compare_from") ?? "";
  const compareTo = q.get("compare_to") ?? "";
  return {
    site: q.get("site") ?? "",
    period: q.get("period") ?? DEFAULT_PERIOD,
    from: q.get("from") ?? "",
    to: q.get("to") ?? "",
    filters,
    compare: q.get("period") === "all" ? "off" : compare === "custom" && !(compareFrom && compareTo) ? DEFAULT_COMPARE : compare,
    compareFrom,
    compareTo,
  };
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
  if (view.compare !== DEFAULT_COMPARE) q.set("compare", view.compare);
  if (view.compare === "custom") {
    q.set("compare_from", view.compareFrom);
    q.set("compare_to", view.compareTo);
  }
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

const isPeriod = (p: string) => (PERIODS as readonly string[]).includes(p);

function Delta({ now, before, lowerIsBetter }: { now: number; before: number | undefined; lowerIsBetter?: boolean }) {
  const c = change(now, before);
  if (c === null) return <span class="delta" />;
  const flat = Math.abs(c) < 0.005;
  const good = lowerIsBetter ? c < 0 : c > 0;
  return (
    <span class={`delta ${flat ? "flat" : good ? "up" : "down"}`} title={t("delta.title")}>
      {flat ? t("delta.none") : `${c > 0 ? "↑" : "↓"} ${Math.abs(Math.round(c * 100))}%`}
    </span>
  );
}

function Avatar({ site }: { site: Site }) {
  // Remembers which site's icon failed. A failure cached by the browser can fire
  // before any effect runs, so resetting a flag in an effect would lose it.
  const [failedFor, setFailedFor] = useState<string | null>(null);
  const failed = failedFor === site.id;
  const letter = (site.name.replace(/^www\./, "")[0] ?? "R").toUpperCase();
  return failed ? (
    <span class="avatar letter" aria-hidden="true">
      {letter}
    </span>
  ) : (
    <img class="avatar" src={`${base}/api/icon?site=${encodeURIComponent(site.id)}`} alt="" width={40} height={40} onError={() => setFailedFor(site.id)} />
  );
}

/** The live count. Before a site's first visit there is nothing to watch, so it is plain text, not a button. */
function Live({ site, ready }: { site: string; ready: boolean }) {
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
  const [open, setOpen] = useState(false);
  if (n === null) return null;
  if (!ready) {
    return (
      <span class="live">
        <span class="beat" aria-hidden="true" />
        {tn("app.live", n, { n: exact(n) })}
      </span>
    );
  }
  return (
    <>
      <button type="button" class="live" title={t("app.live.title")} onClick={() => setOpen(true)}>
        <span class={n > 0 ? "beat on" : "beat"} aria-hidden="true" />
        {tn("app.live", n, { n: exact(n) })}
      </button>
      {open ? <RealtimeModal site={site} onClose={() => setOpen(false)} /> : null}
    </>
  );
}

function Headline({ view, stats, previous, compare }: { view: View; stats: Stats; previous?: Stats; compare?: { from: string; to: string } }) {
  const period = isPeriod(view.period) ? view.period : DEFAULT_PERIOD;
  const when = view.from ? t("when.range", { range: rangeText(view.from, view.to) }) : t(`when.${period}` as Key);
  const against =
    view.compare === "off" || !compare
      ? ""
      : view.compare === "year"
        ? t("headline.lastYear")
        : view.compare === "custom"
          ? rangeText(compare.from, compare.to)
          : view.from
            ? t("before.range")
            : t(`before.${period}` as Key);
  const c = change(stats.visitors, previous?.visitors);
  const parts = {
    who: <strong>{tn("headline.who", stats.visitors, { n: exact(stats.visitors) })}</strong>,
    verb: t(view.filters.length ? "headline.matched" : "headline.visited"),
    when,
    against,
    change:
      c === null ? "" : <span class={c > 0 ? "up" : "down"}>{t(c > 0 ? "headline.more" : "headline.fewer", { pct: Math.abs(Math.round(c * 100)) })}</span>,
  };
  // Nobody in the compared range (a site younger than a year, say) has no percentage, but is still worth saying.
  const fromNone = Boolean(against) && previous?.visitors === 0 && stats.visitors > 0;
  const key: Key = fromNone
    ? "headline.fromNone"
    : c === null || !against
      ? "headline.plain"
      : Math.abs(c) < 0.005
        ? "headline.same"
        : c > 0
          ? "headline.up"
          : "headline.down";
  return <p class="headline">{rich(key, parts)}</p>;
}

function App() {
  const [, setLanguage] = useState(currentLocale());
  const [sites, setSites] = useState<Site[] | null>(null);
  const [view, setView] = useState<View>(readView);
  const [charted, setCharted] = useState<MetricKey[]>(readCharted);
  const [stats, setStats] = useState<{ range: Range; compare?: { from: string; to: string }; stats: Stats; previous?: Stats } | null>(null);
  const [points, setPoints] = useState<Point[]>([]);
  const [previousPoints, setPreviousPoints] = useState<Point[] | undefined>(undefined);
  // Coming back from connecting another Runlight: its settings open, or what went wrong shows.
  const [failure, setFailure] = useState(() => new URLSearchParams(location.search).get("connect_error") ?? "");
  const [filtering, setFiltering] = useState(false);
  const [asking, setAsking] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState<Section | null>(() => (new URLSearchParams(location.search).get("settings") === "general" ? "general" : null));
  const [addingSite, setAddingSite] = useState(false);
  /** Who is signed in, on the standalone server. */
  const [me, setMe] = useState<Person | null>(null);
  const [accountOpen, setAccountOpen] = useState(false);
  const [allOpen, setAllOpen] = useState(false);
  useEffect(() => {
    if (accounts) api.account().then((r) => setMe(r.account)).catch(() => {});
  }, []);
  /** A shared dashboard and a viewer see the numbers and change nothing. */
  const readOnly = Boolean(share) || me?.role === "viewer";

  const fail = (e: Error) =>
    setFailure(e instanceof ApiError && e.status === 401 ? "signed-out" : share && e instanceof ApiError && e.status === 404 ? t("share.gone") : e.message);

  useEffect(() => {
    api.sites().then((r) => setSites(r.sites)).catch(fail);
  }, []);

  useEffect(() => {
    writeUrl(view, charted);
  }, [view, charted]);

  // The last numbers stay up while new ones load; past 300 ms they fade, so a slow database shows it is working.
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => live && setSlow(true), 300);
    Promise.all([api.stats(view), api.series(view)])
      .then(([s, series]) => {
        if (!live) return;
        setFailure("");
        setStats(s);
        setPoints(series.points);
        setPreviousPoints(series.previous);
      })
      .catch((e: Error) => live && fail(e))
      .finally(() => {
        clearTimeout(timer);
        if (live) setSlow(false);
      });
    return () => {
      live = false;
      clearTimeout(timer);
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
  const isDefault =
    !view.from && view.period === DEFAULT_PERIOD && !view.filters.length && view.compare === DEFAULT_COMPARE && charted.join(",") === "visitors";
  // The URL follows the view without adding history, except on a reset, so Back brings the old view back.
  useEffect(() => {
    const restore = () => {
      setView(readView());
      setCharted(readCharted());
    };
    window.addEventListener("popstate", restore);
    return () => window.removeEventListener("popstate", restore);
  }, []);
  /** Back to the start: the default range and comparison, no filters, visitors charted. */
  const reset = () => {
    if (!isDefault) history.pushState(null, "", location.href);
    setView((v) => ({ site: v.site, period: DEFAULT_PERIOD, from: "", to: "", filters: [], compare: DEFAULT_COMPARE, compareFrom: "", compareTo: "" }));
    setCharted(["visitors"]);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };
  const changeLanguage = (code: string) => {
    setLocale(code, true)
      .then(() => setLanguage(code))
      .catch((e: Error) => setFailure(e.message));
  };

  const site = sites?.find((s) => s.id === view.site) ?? sites?.[0];

  // A site with no visits yet shows the install steps, and checks every few seconds for its first visit.
  // A connected site is counted by its own install, so it never waits here for setup.
  const waiting = Boolean(site && site.lastSeen == null && !share && !site.remote);
  /** Counted by another install: its numbers show here and nothing about it can be changed. */
  // A connected site whose install only lets this server read it.
  const elsewhere = Boolean(site?.remote && !site.manage);
  useEffect(() => {
    if (!waiting) return;
    const timer = setInterval(() => {
      api
        .sites()
        .then((r) => {
          setSites(r.sites);
          if (r.sites.find((x) => x.id === site?.id)?.lastSeen != null) setView((v) => ({ ...v }));
        })
        .catch(() => {});
    }, 5000);
    return () => clearInterval(timer);
  }, [waiting, site?.id]);
  const panels = useMemo(layout, []);
  const today = todayIn(site?.timezone ?? "UTC");

  if (failure === "signed-out") {
    return (
      <main class="signed-out">
        <h1>Runlight</h1>
        <p>{rich("app.signedOut", { token: <code>?token=</code>, env: <code>RUNLIGHT_TOKEN</code> })}</p>
      </main>
    );
  }

  const added = (s: Site) => {
    setSites((all) => [...(all ?? []), s].sort((a, b) => a.name.localeCompare(b.name)));
    setAddingSite(false);
    setView((v) => ({ ...v, site: s.id, filters: [] }));
  };
  // A standalone server with no sites yet asks for the first one.
  if (sites && sites.length === 0 && install.managed) return <FirstSite onAdded={added} />;

  const shownMetrics = METRICS.filter((m) => charted.includes(m.key));

  return (
    <main>
      <header class="hero">
        <div class="hero-top">
          <div class="identity">
            <button type="button" class="home" title={t("app.home")} onClick={reset}>
              {site ? <Avatar site={site} /> : <span class="avatar letter" />}
            </button>
            <div class="identity-text">
              {sites && (sites.length > 1 || (install.managed && !readOnly)) ? (
                <SiteMenu
                  sites={sites}
                  current={site}
                  canAdd={install.managed && !readOnly}
                  onPick={(id) => update({ site: id, filters: [] })}
                  onAdd={() => setAddingSite(true)}
                  onAll={() => setAllOpen(true)}
                />
              ) : (
                <h1>
                  <button type="button" class="home" title={t("app.home")} onClick={reset}>
                    {site?.name ?? "Runlight"}
                  </button>
                </h1>
              )}
              {site ? <Live site={site.id} ready={site.lastSeen != null} /> : null}
            </div>
            {site && !readOnly ? (
              <button type="button" class="gear" aria-label={t("settings.open")} title={t("settings.open")} onClick={() => setSettingsOpen("general")}>
                <svg viewBox="0 0 20 20" aria-hidden="true">
                  <circle cx="10" cy="10" r="2.6" />
                  <path d="M10 1.8l1.3 2.3 2.6-.6.8 2.5 2.5.8-.6 2.6 2.3 1.3-2.3 1.3.6 2.6-2.5.8-.8 2.5-2.6-.6L10 18.2l-1.3-2.3-2.6.6-.8-2.5-2.5-.8.6-2.6L1.8 10l2.3-1.3-.6-2.6 2.5-.8.8-2.5 2.6.6z" />
                </svg>
              </button>
            ) : null}
          </div>
          <div class="actions" hidden={waiting}>
            {isDefault ? null : (
              <button type="button" class="reset-button" onClick={reset} title={t("view.resetHint")}>
                <Icon name="reset" />
                {t("view.reset")}
              </button>
            )}
            {site && !share ? (
              <button type="button" class="filter-button assistant-button" aria-label={t("assistant.open")} title={t("assistant.open")} onClick={() => setAsking(true)}>
                <Icon name="robot" />
              </button>
            ) : null}
            <button type="button" class={view.filters.length ? "filter-button on" : "filter-button"} onClick={() => setFiltering(true)}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M2.5 3.5h11M4.5 8h7M6.5 12.5h3" />
              </svg>
              {t("filter.button")}
              {view.filters.length ? <span class="count">{view.filters.length}</span> : null}
            </button>
            <Picker
              period={view.period}
              from={view.from}
              to={view.to}
              today={today}
              onPeriod={(period) => update(period === "all" ? { period, from: "", to: "", compare: "off", compareFrom: "", compareTo: "" } : { period, from: "", to: "" })}
              onRange={(from, to) => update({ from, to })}
            />
            <ComparePicker
              mode={view.compare}
              from={view.compareFrom}
              to={view.compareTo}
              today={today}
              allTime={view.period === "all" && !view.from}
              onChange={(compare, compareFrom = "", compareTo = "") => update({ compare, compareFrom, compareTo })}
            />
          </div>
        </div>
        {waiting ? null : stats ? <Headline view={view} stats={stats.stats} previous={stats.previous} compare={stats.compare} /> : <p class="headline">&nbsp;</p>}
        {view.filters.length ? (
          <div class="filters">
            {view.filters.map((f) => (
              <span class="filter">
                <span class="filter-dim">{fieldName(f.dimension)}</span>
                {opName(f.op)} <strong>{label(f.dimension, f.value)}</strong>
                <button type="button" aria-label={t("filter.remove")} onClick={() => update({ filters: view.filters.filter((x) => x !== f) })}>
                  ×
                </button>
              </span>
            ))}
            {view.filters.length > 1 ? (
              <button type="button" class="clear" onClick={() => update({ filters: [] })}>
                <Icon name="x" />
                {t("common.clearAll")}
              </button>
            ) : null}
          </div>
        ) : null}
      </header>

      {failure ? <p class="failure">{failure}</p> : null}
      {settingsOpen && site && sites ? (
        <SettingsModal
          site={site}
          sites={sites}
          view={view}
          start={settingsOpen}
          onClose={() => {
            setSettingsOpen(null);
            // Goals may have changed; the board reads them again.
            setView((v) => ({ ...v }));
          }}
          onSaved={(saved) => {
            setSites((all) => (all ?? []).map((x) => (x.id === saved.id ? { ...x, ...saved } : x)));
            // A new timezone moves every day boundary, so reload the numbers.
            setView((v) => ({ ...v }));
          }}
          onLanguage={changeLanguage}
          me={me}
          onDeleted={(id) => {
            setSettingsOpen(null);
            const rest = (sites ?? []).filter((x) => x.id !== id);
            setSites(rest);
            setView((v) => ({ ...v, site: rest[0]?.id ?? "", filters: [] }));
          }}
        />
      ) : null}
      {allOpen && sites ? (
        <AllSites
          sites={sites}
          view={view}
          onClose={() => setAllOpen(false)}
          onPick={(id) => {
            setAllOpen(false);
            update({ site: id, filters: [] });
          }}
        />
      ) : null}
      {accountOpen && me ? <AccountSheet me={me} onClose={() => setAccountOpen(false)} /> : null}
      {addingSite ? (
        <Sheet title={t("sites.addTitle")} onClose={() => setAddingSite(false)}>
          <AddSiteForm onAdded={added} onCancel={() => setAddingSite(false)} />
        </Sheet>
      ) : null}
      {filtering ? <FilterDrawer view={view} onApply={(filters) => update({ filters })} onClose={() => setFiltering(false)} /> : null}
      {asking && site ? (
        <AssistantDrawer
          site={site}
          view={view}
          owner={!me || me.role === "owner"}
          onSetup={() => {
            setAsking(false);
            setSettingsOpen("assistant");
          }}
          onClose={() => setAsking(false)}
        />
      ) : null}

      {waiting && site && sites ? (
        <section class="welcome">
          <h2>{t("welcome.title", { name: site.name })}</h2>
          <p class="welcome-lead">
            <span class="beat wait" aria-hidden="true" />
            {t("welcome.lead")}
          </p>
          <div class="welcome-steps">
            <Install site={site} sites={sites} />
          </div>
        </section>
      ) : null}

      <section class={slow ? "overview stale" : "overview"} hidden={waiting} aria-busy={slow}>
        <div class="metrics">
          {METRICS.map((m) => {
            const on = charted.includes(m.key);
            const value = stats?.stats[m.key];
            return (
              <button type="button" class={`metric s${m.slot}${on ? " on" : ""}`} aria-pressed={on} onClick={() => toggleMetric(m.key)} title={metricHint(m)}>
                <span class="metric-label">
                  <span class={`swatch s${m.slot}`} />
                  {metricLabel(m)}
                </span>
                <span class="metric-value">{value === undefined ? " " : m.format(value)}</span>
                <span class="metric-foot">
                  {stats ? <Delta now={stats.stats[m.key]} before={stats.previous?.[m.key]} lowerIsBetter={m.lowerIsBetter} /> : null}
                </span>
              </button>
            );
          })}
        </div>
        <div class="chart-head">
          <span class="chart-note">
            {shownMetrics.length > 1 ? t("chart.scaled") : t("chart.pick")}
            {stats?.compare ? ` ${t("chart.dashed", { range: rangeText(stats.compare.from, stats.compare.to) })}` : ""}
          </span>
        </div>
        {stats ? (
          <Chart
            points={points as unknown as Array<{ start: number } & Record<string, number>>}
            previous={previousPoints as unknown as Array<{ start: number } & Record<string, number>> | undefined}
            metrics={shownMetrics.map(asSeries)}
            interval={stats.range.interval}
            timezone={stats.range.timezone}
          />
        ) : (
          <div class="chart" />
        )}
      </section>

      <div class="board" hidden={waiting}>
        {panels.map((panel, i) =>
          panel.title === "panel.rhythm" ? (
            <Rhythm view={view} wide={panel.wide} />
          ) : (
            <Panel title={panel.title} tabs={panel.tabs} view={view} onFilter={addFilter} wide={panel.wide} map={panel.title === "panel.locations"} key={i} />
          ),
        )}
        {/* The last row: Conversions narrow, Links wide, so the zigzag carries on. */}
        {/* Wide then narrow, so the zigzag of the rows above carries on. */}
        {site && !readOnly && !elsewhere ? <LinksPanel view={view} site={site.id} /> : null}
        {site ? <ConversionsPanel view={view} readOnly={readOnly || elsewhere} onAdd={() => setSettingsOpen("goals")} /> : null}
      </div>

      <footer class="foot">
        <a href="https://runlight.sh" class="powered">
          <svg class="powered-mark" viewBox="0 0 32 32" aria-hidden="true">
            <rect x="2.5" y="2.5" width="27" height="27" rx="7" />
            <path d="M11 23V9h6.2a4.3 4.3 0 0 1 0 8.6H11m6 0 5 5.4" />
            <circle cx="23.6" cy="8.4" r="2.6" />
          </svg>
          {rich("foot.powered", { name: <span>Runlight</span> })}
        </a>
        <span class="foot-range">{stats ? `${rangeText(stats.range.from, stats.range.to)} · ${stats.range.timezone}` : ""}</span>
        <label class="language">
          <span class="visually-hidden">{t("foot.language")}</span>
          <select value={currentLocale()} onChange={(e) => changeLanguage((e.target as HTMLSelectElement).value)}>
            {LANGUAGES.map(([code, name]) => (
              <option value={code}>{name}</option>
            ))}
          </select>
        </label>
        <Theme />
        <button type="button" class="sign-out" title={t("export.title")} onClick={() => void download("export", viewParams(view)).catch((e: Error) => setFailure(e.message))}>
          {t("export.zip")}
        </button>
        {me ? (
          <button type="button" class="sign-out" onClick={() => setAccountOpen(true)}>
            {t("account.title")}
          </button>
        ) : null}
        {signOut ? (
          <a class="sign-out" href={signOut}>
            {t("app.signOut")}
          </a>
        ) : null}
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

function layout(): Array<{ title: Key; tabs: Tab[]; wide?: boolean }> {
  const f = { filterable: true };
  // Wide and narrow alternate row by row, so the board reads as a zigzag.
  return [
    {
      title: "panel.pages",
      wide: true,
      tabs: [
        { dimension: "page", label: "tab.top", ...f, extra: timeOnPage },
        { dimension: "entry", label: "tab.entry", ...f, extra: bounce },
        { dimension: "exit", label: "tab.exit", ...f },
      ],
    },
    {
      title: "panel.sources",
      tabs: [
        { dimension: "channel", label: "tab.channels", ...f, colors: CHANNEL_COLORS },
        { dimension: "source", label: "tab.sources", ...f },
        { dimension: "referrer", label: "tab.referrers", ...f },
      ],
    },
    {
      title: "panel.locations",
      tabs: [
        { dimension: "country", label: "tab.countries", ...f },
        { dimension: "region", label: "tab.regions", ...f },
        { dimension: "city", label: "tab.cities", ...f },
      ],
    },
    { title: "panel.rhythm", wide: true, tabs: [] },
    {
      title: "panel.ai",
      wide: true,
      tabs: [
        { dimension: "ai_agent", label: "tab.agents", column: "fetches", groups: { of: (v) => (LIVE_AGENTS.has(v) ? "ai.live" : "ai.crawl"), slots: { "ai.live": 7, "ai.crawl": 1 } } },
        { dimension: "ai_page", label: "tab.pages", column: "fetches" },
      ],
    },
    {
      title: "panel.devices",
      tabs: [
        { dimension: "device", label: "tab.device", ...f, colors: DEVICE_COLORS },
        { dimension: "browser", label: "tab.browser", ...f },
        { dimension: "os", label: "tab.os", ...f },
        { dimension: "screen", label: "tab.screen", ...f },
        { dimension: "language", label: "tab.language", ...f },
      ],
    },
    {
      title: "panel.events",
      tabs: [{ dimension: "event", label: "tab.event", column: "events", ...f }],
    },
    {
      title: "panel.campaigns",
      wide: true,
      tabs: [
        { dimension: "utm_campaign", label: "tab.campaign", ...f },
        { dimension: "utm_source", label: "tab.source", ...f },
        { dimension: "utm_medium", label: "tab.medium", ...f },
        { dimension: "utm_content", label: "tab.content", ...f },
        { dimension: "utm_term", label: "tab.term", ...f },
      ],
    },
  ];
}

const CYCLE: ThemeChoice[] = ["light", "dark", "system"];
const themeName = (choice: ThemeChoice): string => t(choice === "light" ? "theme.light" : choice === "dark" ? "theme.dark" : "theme.system");

/** Cycles light, dark, and the device's setting; the icon shows the current one. */
function Theme() {
  const [, rerender] = useState(0);
  useEffect(() => onThemeChange(() => rerender((n) => n + 1)), []);
  const choice = themeChoice();
  const next = CYCLE[(CYCLE.indexOf(choice) + 1) % CYCLE.length]!;
  // Cmd+Shift+D on a Mac, Ctrl+Shift+D elsewhere, flips light and dark.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "d") {
        e.preventDefault();
        setTheme(isDark() ? "light" : "dark");
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  const mac = /Mac|iPhone|iPad/.test(navigator.platform);
  const label = t("theme.cycle", { current: themeName(choice), next: themeName(next) });
  return (
    <button
      type="button"
      class="theme"
      aria-label={label}
      aria-keyshortcuts={mac ? "Meta+Shift+D" : "Control+Shift+D"}
      title={`${label} (${mac ? "\u2318\u21e7D" : "Ctrl+Shift+D"})`}
      onClick={() => setTheme(next)}
    >
      {choice === "light" ? (
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <circle cx="10" cy="10" r="3.6" />
          <path d="M10 1.8v2.2M10 16v2.2M1.8 10H4M16 10h2.2M4.2 4.2l1.6 1.6M14.2 14.2l1.6 1.6M4.2 15.8l1.6-1.6M14.2 5.8l1.6-1.6" />
        </svg>
      ) : choice === "dark" ? (
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <path d="M16.5 12.6A7 7 0 0 1 7.4 3.5a7 7 0 1 0 9.1 9.1z" />
        </svg>
      ) : (
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <rect x="2.5" y="3.5" width="15" height="10" rx="1.6" />
          <path d="M7 17h6M10 13.5V17" />
        </svg>
      )}
    </button>
  );
}

applyTheme();
const root = document.getElementById("app")!;
setLocale(initialLocale())
  .catch(() => setLocale("en"))
  .finally(() => render(<App />, root));
