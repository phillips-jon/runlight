import { useEffect, useRef, useState } from "preact/hooks";
import { api, download, geoCredit, viewParams, type Row, type View } from "./api.js";
import { count, countryName, duration, flag, hourLabel, percent, weekdays } from "./format.js";
import type { RhythmCell } from "./api.js";
import { rich, t, tn, type Key } from "./i18n.js";
import { MapOverlay, WorldMap } from "./map.js";
import { EventProps } from "./eventprops.js";
import { Icon } from "./icons.js";

export interface Tab {
  /** The API dimension. */
  dimension: string;
  label: Key;
  /** What the right-hand column counts. */
  column?: "visitors" | "fetches" | "events";
  /** Clicking a row filters by it. */
  filterable?: boolean;
  /** An extra column, such as time on page. */
  extra?: { key: keyof Row; label: Key; format: (n: number) => string };
  /**
   * Colours for known values, by categorical slot. The tab then opens with
   * a bar showing the mix, and each row carries its colour.
   */
  colors?: Record<string, number>;
  /** Groups rows into a two-part mix, such as live fetches against crawls. */
  groups?: { of: (value: string) => Key; slots: Partial<Record<Key, number>> };
}

interface Props {
  title: Key;
  tabs: Tab[];
  view: View;
  onFilter: (dimension: string, value: string) => void;
  wide?: boolean;
  /** Offer a world map of countries beside the list. */
  map?: boolean;
}

const SHORT = 8;
const ALL = 1000;

/** A value as people should read it: countries named, channels and devices in the viewer's language. */
export function label(dimension: string, value: string): string {
  if (!value) return t("common.none");
  if (dimension === "country") return `${flag(value)} ${countryName(value)}`.trim();
  if (dimension === "region") return `${flag(value.slice(0, 2))} ${value}`.trim();
  if (dimension === "channel") return t(`channel.${value}` as Key);
  if (dimension === "device") return t(`device.${value}` as Key);
  return value;
}

function Mix({ parts }: { parts: Array<{ name: string; n: number; slot: number }> }) {
  const total = parts.reduce((sum, p) => sum + p.n, 0);
  if (total === 0) return null;
  return (
    <div class="mix">
      <div class="mix-bar" role="img" aria-label={parts.map((p) => `${p.name} ${percent(p.n / total)}`).join(", ")}>
        {parts.map((p) => (
          <span class={`mix-part s${p.slot}`} style={{ flexGrow: String(p.n) }} title={`${p.name}: ${percent(p.n / total)}`} />
        ))}
      </div>
      <div class="mix-key">
        {parts.map((p) => (
          <span>
            <span class={`swatch s${p.slot}`} />
            {p.name} <b>{percent(p.n / total)}</b>
          </span>
        ))}
      </div>
    </div>
  );
}

function Rows({ rows, tab, onFilter, onDetail }: { rows: Row[]; tab: Tab; onFilter: (dimension: string, value: string) => void; onDetail?: (value: string) => void }) {
  const column = tab.column ?? "visitors";
  const top = Math.max(1, ...rows.map((r) => Number(r[column] ?? 0)));
  const dot = (value: string): number | undefined => tab.colors?.[value] ?? (tab.groups ? tab.groups.slots[tab.groups.of(value)] : undefined);
  return (
    <ol class="rows">
      {rows.map((row) => {
        const n = Number(row[column] ?? 0);
        const text = label(tab.dimension, row.value);
        const slot = dot(row.value);
        const name = (
          <>
            {slot !== undefined ? <span class={`swatch s${slot}`} /> : null}
            <span class="name-text">{text}</span>
          </>
        );
        return (
          <li>
            <span class="bar" style={{ width: `${(n / top) * 100}%` }} />
            {tab.filterable ? (
              <button type="button" class="name" title={t("panel.filterBy", { name: text })} onClick={() => onFilter(tab.dimension, row.value)}>
                {name}
              </button>
            ) : (
              <span class="name">{name}</span>
            )}
            {tab.extra ? <span class="extra">{tab.extra.format(Number(row[tab.extra.key] ?? 0))}</span> : null}
            {onDetail ? (
              <button type="button" class="row-detail" title={t("props.open", { name: text })} aria-label={t("props.open", { name: text })} onClick={() => onDetail(row.value)}>
                <Icon name="list" />
              </button>
            ) : null}
            <span class="num">{count(n)}</span>
          </li>
        );
      })}
    </ol>
  );
}

function Columns({ tab }: { tab: Tab }) {
  return (
    <div class="cols">
      <span>{t(tab.label)}</span>
      <span>
        {tab.extra ? <span class="extra">{t(tab.extra.label)}</span> : null}
        {t(`column.${tab.column ?? "visitors"}`)}
      </span>
    </div>
  );
}

type SheetColumn = { label: Key; value: (row: Row, total: number) => string };

const VISIT_DIMENSIONS = new Set(["referrer", "source", "channel", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "country", "region", "city", "browser", "browser_version", "os", "os_version", "device", "screen", "language"]);

/** The columns a full list shows: everything the API knows about that kind of row. */
function sheetColumns(tab: Tab): SheetColumn[] {
  const n = (key: keyof Row) => (row: Row) => count(Number(row[key] ?? 0));
  const share = (key: keyof Row) => (row: Row, total: number) => (total ? percent(Number(row[key] ?? 0) / total) : "");
  if (tab.column === "fetches") return [{ label: "column.fetches", value: n("fetches") }, { label: "column.share", value: share("fetches") }];
  if (tab.column === "events") return [{ label: "column.visitors", value: n("visitors") }, { label: "column.events", value: n("events") }, { label: "column.share", value: share("events") }];
  if (tab.dimension === "page") {
    return [
      { label: "column.visitors", value: n("visitors") },
      { label: "column.pageviews", value: n("pageviews") },
      { label: "column.time", value: (r) => (r.timeOnPage ? duration(r.timeOnPage) : "") },
      { label: "column.scroll", value: (r) => (r.scrollDepth ? `${r.scrollDepth}%` : "") },
    ];
  }
  if (tab.dimension === "hostname") return [{ label: "column.visitors", value: n("visitors") }, { label: "column.pageviews", value: n("pageviews") }];
  if (tab.dimension === "entry" || tab.dimension === "exit") {
    return [
      { label: "column.visitors", value: n("visitors") },
      { label: "column.visits", value: n("visits") },
      { label: "column.bounce", value: (r) => percent(r.bounceRate ?? 0) },
    ];
  }
  if (VISIT_DIMENSIONS.has(tab.dimension)) {
    return [
      { label: "column.visitors", value: n("visitors") },
      { label: "column.visits", value: n("visits") },
      { label: "column.pageviews", value: n("pageviews") },
      { label: "column.bounce", value: (r) => percent(r.bounceRate ?? 0) },
      { label: "column.duration", value: (r) => duration(r.visitDuration ?? 0) },
      { label: "column.share", value: share("visitors") },
    ];
  }
  return [{ label: "column.visitors", value: n("visitors") }];
}

function SheetTable({ rows, tab, onFilter }: { rows: Row[]; tab: Tab; onFilter: (dimension: string, value: string) => void }) {
  const column = tab.column ?? "visitors";
  const columns = sheetColumns(tab);
  const total = rows.reduce((sum, r) => sum + Number(r[column] ?? 0), 0);
  const top = Math.max(1, ...rows.map((r) => Number(r[column] ?? 0)));
  return (
    <table class="sheet-table">
      <thead>
        <tr>
          <th>{t(tab.label)}</th>
          {columns.map((c) => (
            <th class="numeric">{t(c.label)}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => {
          const text = label(tab.dimension, row.value);
          return (
            <tr>
              <td class="sheet-name">
                <span class="bar" style={{ width: `${(Number(row[column] ?? 0) / top) * 100}%` }} />
                {tab.filterable ? (
                  <button type="button" class="name" title={t("panel.filterBy", { name: text })} onClick={() => onFilter(tab.dimension, row.value)}>
                    <span class="name-text">{text}</span>
                  </button>
                ) : (
                  <span class="name">
                    <span class="name-text">{text}</span>
                  </span>
                )}
              </td>
              {columns.map((c, i) => (
                <td class={i === 0 ? "numeric lead" : "numeric"}>{c.value(row, total)}</td>
              ))}
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/** Every row of a tab, searchable, over the page. */
function AllRows({ title, tab, view, onFilter, onClose }: { title: Key; tab: Tab; view: View; onFilter: (d: string, v: string) => void; onClose: () => void }) {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [query, setQuery] = useState("");
  const search = useRef<HTMLInputElement>(null);
  useEffect(() => {
    api.breakdown(view, tab.dimension, ALL).then((r) => setRows(r.rows)).catch(() => setRows([]));
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.classList.add("locked");
    search.current?.focus();
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);
  const needle = query.trim().toLowerCase();
  const shown = (rows ?? []).filter((r) => !needle || label(tab.dimension, r.value).toLowerCase().includes(needle));
  return (
    <div class="scrim center" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class={sheetColumns(tab).length > 3 ? "list-sheet wide" : "list-sheet"} role="dialog" aria-modal="true" aria-label={`${t(title)}: ${t(tab.label)}`}>
        <header class="drawer-head">
          <h2>
            {t(title)} <span class="sheet-sub">{t(tab.label)}</span>
          </h2>
          <button
            type="button"
            class="copy inline sheet-download"
            onClick={() => {
              const params = viewParams(view);
              params.set("dimension", tab.dimension);
              params.set("limit", String(ALL));
              params.set("format", "csv");
              void download("breakdown", params).catch(() => {});
            }}
          >
            <Icon name="upload" />
            {t("export.csv")}
          </button>
          <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </header>
        <div class="sheet-search">
          <input
            ref={search}
            class="value"
            type="search"
            placeholder={t("common.search")}
            aria-label={t("common.search")}
            value={query}
            onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
          />
          <span class="sheet-tools">
            {query ? (
              <button type="button" class="sheet-clear" aria-label={t("common.clearAll")} onClick={() => {
                setQuery("");
                search.current?.focus();
              }}>
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />
                </svg>
              </button>
            ) : null}
            <span class="sheet-count">{rows ? (needle ? `${count(shown.length)} / ${count(rows.length)}` : count(rows.length)) : ""}</span>
          </span>
        </div>
        <div class="sheet-body">
          {!rows ? <p class="empty">{t("common.loading")}</p> : null}
          {rows && shown.length === 0 ? <p class="empty">{t("panel.empty")}</p> : null}
          {shown.length ? (
            <SheetTable
              rows={shown}
              tab={tab}
              onFilter={(d, v) => {
                onFilter(d, v);
                onClose();
              }}
            />
          ) : null}
        </div>
      </div>
    </div>
  );
}

export function Panel({ title, tabs, view, onFilter, wide, map }: Props) {
  const [active, setActive] = useState(0);
  const [showMap, setShowMap] = useState(false);
  const [fullMap, setFullMap] = useState(false);
  const [showAll, setShowAll] = useState(false);
  /** The event whose properties are open, from the Events panel. */
  const [detail, setDetail] = useState<string | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState("");
  /** Set when a reload takes longer than 300 ms, to fade the rows still showing. */
  const [slow, setSlow] = useState(false);
  const tab = tabs[active] ?? tabs[0]!;
  const column = tab.column ?? "visitors";

  useEffect(() => {
    let live = true;
    setError("");
    const timer = setTimeout(() => live && setSlow(true), 300);
    api
      .breakdown(view, tab.dimension, 50)
      .then((result) => live && setRows(result.rows))
      .catch((e: Error) => live && setError(e.message))
      .finally(() => {
        clearTimeout(timer);
        if (live) setSlow(false);
      });
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [view, tab.dimension]);

  const all = rows ?? [];
  let mix: Array<{ name: string; n: number; slot: number }> = [];
  if (tab.colors) {
    mix = all.filter((r) => tab.colors![r.value] !== undefined).map((r) => ({ name: label(tab.dimension, r.value), n: Number(r[column] ?? 0), slot: tab.colors![r.value]! }));
  } else if (tab.groups) {
    const sums = new Map<Key, number>();
    for (const r of all) sums.set(tab.groups.of(r.value), (sums.get(tab.groups.of(r.value)) ?? 0) + Number(r[column] ?? 0));
    mix = (Object.entries(tab.groups.slots) as Array<[Key, number]>).map(([key, slot]) => ({ name: t(key), n: sums.get(key) ?? 0, slot }));
  }

  return (
    <section class={`${wide ? "panel wide" : "panel"}${slow && rows ? " stale" : ""}`} aria-busy={slow}>
      <header class="panel-head">
        <h2>{t(title)}</h2>
        <div class="head-tools">
          {tabs.length > 1 && !showMap ? (
            <nav class="tabs" aria-label={t("panel.views", { title: t(title) })}>
              {tabs.map((x, i) => (
                <button
                  type="button"
                  class={i === active ? "tab on" : "tab"}
                  aria-pressed={i === active}
                  onClick={() => {
                    setActive(i);
                    setRows(null);
                  }}
                >
                  {t(x.label)}
                </button>
              ))}
            </nav>
          ) : null}
          {map ? (
            <>
              <button type="button" class={showMap ? "tool on" : "tool"} aria-pressed={showMap} title={t(showMap ? "panel.showList" : "panel.showMap")} onClick={() => setShowMap(!showMap)}>
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M1.5 3.5l4-1.5 5 2 4-1.5v10l-4 1.5-5-2-4 1.5z M5.5 2v10 M10.5 4v10" />
                </svg>
              </button>
              <button type="button" class="tool" title={t("panel.fullMap")} onClick={() => setFullMap(true)}>
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M2 6V2h4M10 2h4v4M14 10v4h-4M6 14H2v-4" />
                </svg>
              </button>
            </>
          ) : null}
        </div>
      </header>
      {fullMap ? <MapOverlay view={view} onFilter={onFilter} onClose={() => setFullMap(false)} /> : null}
      {detail ? <EventProps view={view} event={detail} onClose={() => setDetail(null)} /> : null}
      {showAll ? <AllRows title={title} tab={tab} view={view} onFilter={onFilter} onClose={() => setShowAll(false)} /> : null}
      {showMap ? (
        <WorldMap view={view} onFilter={onFilter} />
      ) : (
        <>
          {mix.length > 0 ? <Mix parts={mix} /> : null}
          <Columns tab={tab} />
          {error ? <p class="empty">{error}</p> : null}
          {!error && rows && all.length === 0 ? <p class="empty">{t("panel.empty")}</p> : null}
          {!rows && !error ? <p class="empty">{t("common.loading")}</p> : null}
          <Rows rows={all.slice(0, SHORT)} tab={tab} onFilter={onFilter} onDetail={tab.dimension === "event" ? setDetail : undefined} />
          {all.length > SHORT ? (
            <button type="button" class="more" onClick={() => setShowAll(true)}>
              <Icon name="expand" />
              {t("panel.more")}
            </button>
          ) : null}
        </>
      )}
      {/* DB-IP's free data asks for credit where its locations are shown. */}
      {map && geoCredit ? (
        <a class="geo-credit" href="https://db-ip.com" target="_blank" rel="noopener">
          {rich("panel.geoCredit", { name: <span>DB-IP</span> })}
        </a>
      ) : null}
    </section>
  );
}

const STEPS = 6;

/** Visits by weekday and hour, in the site's timezone. */
export function Rhythm({ view, wide }: { view: View; wide?: boolean }) {
  const [grid, setGrid] = useState<number[][] | null>(null);
  const [cells, setCells] = useState<RhythmCell[][]>([]);
  const [error, setError] = useState("");
  const [hover, setHover] = useState<{ d: number; h: number; x: number; y: number } | null>(null);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let live = true;
    setError("");
    api
      .rhythm(view)
      .then((r) => {
        if (!live) return;
        setGrid(r.grid);
        setCells(r.cells ?? []);
      })
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [view]);

  const days = weekdays("short");
  const max = grid ? Math.max(0, ...grid.flat()) : 0;
  let busiest: [number, number] | null = null;
  if (grid && max > 0) {
    for (let d = 0; d < 7 && !busiest; d++) {
      const h = grid[d]!.indexOf(max);
      if (h >= 0) busiest = [d, h];
    }
  }

  const typical = grid ? grid.flat().reduce((a, b) => a + b, 0) / 168 : 0;
  const hovered = hover && grid ? { n: grid[hover.d]![hover.h]!, cell: cells[hover.d]?.[hover.h] } : null;

  return (
    <section class={wide ? "panel wide" : "panel"}>
      <header class="panel-head">
        <h2>{t("panel.rhythm")}</h2>
        {busiest ? <span class="aside">{t("rhythm.busiest", { when: `${days[busiest[0]]} ${hourLabel(busiest[1])}` })}</span> : null}
      </header>
      {error ? <p class="empty">{error}</p> : null}
      {!grid && !error ? <p class="empty">{t("common.loading")}</p> : null}
      {grid ? (
        <div class="rhythm" role="table" aria-label={t("rhythm.table")} ref={box} onPointerLeave={() => setHover(null)}>
          {grid.map((row, d) => (
            <div class="rhythm-row" role="row">
              <span class="rhythm-day" role="rowheader">
                {days[d]}
              </span>
              {row.map((n, h) => (
                <span
                  role="cell"
                  aria-label={tn("rhythm.cell", n, { when: `${days[d]} ${hourLabel(h)}`, n: count(n) })}
                  class={`cell q${n === 0 || max === 0 ? 0 : Math.max(1, Math.ceil((n / max) * STEPS))}${hover?.d === d && hover.h === h ? " hot" : ""}`}
                  onPointerEnter={(e) => {
                    const r = box.current?.getBoundingClientRect();
                    const c = (e.currentTarget as HTMLElement).getBoundingClientRect();
                    if (r) setHover({ d, h, x: c.left - r.left + c.width / 2, y: c.top - r.top });
                  }}
                />
              ))}
            </div>
          ))}
          <div class="rhythm-row hours" aria-hidden="true">
            <span class="rhythm-day" />
            {Array.from({ length: 24 }, (_, h) => (
              <span class="hour">{h % 6 === 0 ? hourLabel(h) : ""}</span>
            ))}
          </div>
          {hover && hovered ? (
            <div class={hover.x > (box.current?.clientWidth ?? 0) * 0.6 ? "rhythm-tip left" : "rhythm-tip"} style={{ left: `${hover.x}px`, top: `${hover.y}px` }}>
              <span class="tip-when">
                {days[hover.d]} {hourLabel(hover.h)}
              </span>
              {hovered.n && hovered.cell ? (
                <>
                  <span class="tip-row">
                    <span class="tip-label">{t("metric.visits")}</span>
                    <strong>{count(hovered.cell.visits)}</strong>
                  </span>
                  <span class="tip-row">
                    <span class="tip-label">{t("metric.visitors")}</span>
                    <strong>{count(hovered.cell.visitors)}</strong>
                  </span>
                  <span class="tip-row">
                    <span class="tip-label">{t("metric.pageviews")}</span>
                    <strong>{count(hovered.cell.pageviews)}</strong>
                  </span>
                  <span class="tip-row">
                    <span class="tip-label">{t("metric.bounceRate")}</span>
                    <strong>{percent(hovered.cell.bounceRate)}</strong>
                  </span>
                  {typical > 0 ? <span class="tip-note">{t("rhythm.typical", { x: (hovered.n / typical).toFixed(1) })}</span> : null}
                </>
              ) : (
                <span class="tip-note">{t("rhythm.quiet")}</span>
              )}
            </div>
          ) : null}
          <div class="rhythm-scale" aria-hidden="true">
            <span>{t("scale.fewer")}</span>
            {Array.from({ length: STEPS }, (_, i) => (
              <span class={`cell q${i + 1}`} />
            ))}
            <span>{t("scale.more")}</span>
          </div>
        </div>
      ) : null}
    </section>
  );
}

export const timeOnPage = { key: "timeOnPage" as const, label: "column.time" as const, format: (n: number) => (n ? duration(n) : "") };
export const bounce = { key: "bounceRate" as const, label: "column.bounce" as const, format: percent };
