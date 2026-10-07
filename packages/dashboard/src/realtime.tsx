import { useEffect, useState } from "preact/hooks";
import { api, type Realtime } from "./api.js";
import { count, countryName, exact, flag } from "./format.js";
import { currentLocale, rich, t, tn, type Key } from "./i18n.js";
import { Sheet } from "./links.js";
import { label } from "./panel.js";

const REFRESH_MS = 10_000;

function ago(ts: number): string {
  const seconds = Math.round((ts - Date.now()) / 1000);
  const f = new Intl.RelativeTimeFormat(currentLocale(), { numeric: "auto", style: "short" });
  return Math.abs(seconds) < 60 ? f.format(Math.min(0, seconds), "second") : f.format(Math.round(seconds / 60), "minute");
}

function clock(ts: number): string {
  return new Intl.DateTimeFormat(currentLocale(), { hour: "numeric", minute: "2-digit" }).format(ts);
}

/** Pageviews in each of the last 30 minutes, with the hovered minute named above. */
function Minutes({ minutes }: { minutes: number[] }) {
  const [hover, setHover] = useState<number | null>(null);
  const top = Math.max(1, ...minutes);
  const total = minutes.reduce((a, b) => a + b, 0);
  // The last bar is the minute in progress.
  const start = Math.floor(Date.now() / 60_000) * 60_000 - (minutes.length - 1) * 60_000;
  return (
    <section class="minutes">
      <p class="minutes-note">
        {hover === null
          ? tn("live.total", total, { n: exact(total) })
          : tn("live.minute", minutes[hover] ?? 0, { n: exact(minutes[hover] ?? 0), time: clock(start + hover * 60_000) })}
      </p>
      <div class="minute-bars" onPointerLeave={() => setHover(null)}>
        {minutes.map((n, i) => (
          <span class={hover === i ? "minute on" : "minute"} onPointerEnter={() => setHover(i)}>
            <span class="minute-bar" style={{ height: `${n ? Math.max(4, (n / top) * 100) : 0}%` }} />
          </span>
        ))}
      </div>
      <div class="minute-axis">
        <span>{t("live.ago30")}</span>
        <span>{t("live.nowLabel")}</span>
      </div>
    </section>
  );
}

function Now({ title, rows, dimension }: { title: Key; rows: Array<{ value: string; visitors: number }>; dimension: string }) {
  const top = Math.max(1, ...rows.map((r) => r.visitors));
  return (
    <section class="mini">
      <h3>{t(title)}</h3>
      {rows.length === 0 ? <p class="empty">{t("live.nobody")}</p> : null}
      <ol class="rows">
        {rows.map((r) => (
          <li>
            <span class="bar" style={{ width: `${(r.visitors / top) * 100}%` }} />
            <span class="name">
              <span class="name-text">{dimension === "country" ? `${flag(r.value)} ${countryName(r.value)}` : label(dimension, r.value)}</span>
            </span>
            <span class="num">{count(r.visitors)}</span>
          </li>
        ))}
      </ol>
    </section>
  );
}

function Feed({ recent }: { recent: Realtime["recent"] }) {
  return (
    <section class="feed">
      <h3>{t("live.feed")}</h3>
      {recent.length === 0 ? <p class="empty">{t("live.quiet")}</p> : null}
      <ol>
        {recent.map((r) => {
          const place = [r.city, r.country ? countryName(r.country) : ""].filter(Boolean).join(", ");
          const who = place ? t("live.someoneIn", { place }) : t("live.someone");
          const parts = { who, path: <strong>{r.path || "/"}</strong>, name: <strong>{r.name}</strong>, source: r.source };
          const key: Key = r.kind === "event" ? (r.source ? "live.didVia" : "live.did") : r.source ? "live.viewedVia" : "live.viewed";
          return (
            <li>
              <span class="feed-flag" aria-hidden="true">
                {r.country ? flag(r.country) : "·"}
              </span>
              <span class="feed-text">{rich(key, parts)}</span>
              <span class="feed-time">{ago(r.ts)}</span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

/** What is happening on the site right now, refreshed while open. */
export function RealtimeModal({ site, onClose }: { site: string; onClose: () => void }) {
  const [data, setData] = useState<Realtime | null>(null);
  useEffect(() => {
    let live = true;
    const load = () =>
      api
        .realtime(site)
        .then((r) => live && setData(r))
        .catch(() => {});
    void load();
    const timer = setInterval(load, REFRESH_MS);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [site]);
  return (
    <Sheet title={t("live.title")} sub={t("live.sub")} wide onClose={onClose}>
      <div class="live-body">
        {data ? (
          <>
            <p class="live-count">
              <span class={data.visitors > 0 ? "beat on" : "beat"} aria-hidden="true" />
              {rich(new Intl.PluralRules(currentLocale()).select(data.visitors) === "one" ? "live.now_one" : "live.now_other", { n: <strong>{exact(data.visitors)}</strong> })}
              <span class="live-hint">{t("live.nowHint")}</span>
            </p>
            <Minutes minutes={data.minutes} />
            <div class="mini-grid three">
              <Now title="live.pages" rows={data.pages} dimension="path" />
              <Now title="live.sources" rows={data.sources} dimension="source" />
              <Now title="live.countries" rows={data.countries} dimension="country" />
            </div>
            <Feed recent={data.recent} />
          </>
        ) : (
          <p class="empty">{t("common.loading")}</p>
        )}
      </div>
    </Sheet>
  );
}
