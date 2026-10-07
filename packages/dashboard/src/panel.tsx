import { useEffect, useState } from "preact/hooks";
import { api, type Row, type View } from "./api.js";
import { count, countryName, duration, flag, percent } from "./format.js";
import { MapOverlay, WorldMap } from "./map.js";

export interface Tab {
  /** The API dimension. */
  dimension: string;
  label: string;
  /** What the right-hand column counts. */
  column?: "visitors" | "fetches" | "events";
  /** Clicking a row filters by it. */
  filterable?: boolean;
  /** An extra column, such as time on page. */
  extra?: { key: keyof Row; label: string; format: (n: number) => string };
  /**
   * Colours for known values, by categorical slot. The tab then opens with
   * a bar showing the mix, and each row carries its colour.
   */
  colors?: Record<string, number>;
  /** Groups rows into a two-part mix, such as live fetches against crawls. */
  groups?: { of: (value: string) => string; slots: Record<string, number> };
}

interface Props {
  title: string;
  tabs: Tab[];
  view: View;
  onFilter: (dimension: string, value: string) => void;
  wide?: boolean;
  /** Offer a world map of countries beside the list. */
  map?: boolean;
}

const SHORT = 8;
const LONG = 100;

export function label(dimension: string, value: string): string {
  if (dimension === "country") return `${flag(value)} ${countryName(value)}`.trim();
  if (dimension === "region") return `${flag(value.slice(0, 2))} ${value}`.trim();
  if (dimension === "device" && value) return value[0]!.toUpperCase() + value.slice(1);
  return value || "(none)";
}

function Mix({ parts, dimension }: { parts: Array<{ name: string; n: number; slot: number }>; dimension: string }) {
  const total = parts.reduce((sum, p) => sum + p.n, 0);
  if (total === 0) return null;
  return (
    <div class="mix">
      <div class="mix-bar" role="img" aria-label={parts.map((p) => `${label(dimension, p.name)} ${percent(p.n / total)}`).join(", ")}>
        {parts.map((p) => (
          <span class={`mix-part s${p.slot}`} style={{ flexGrow: String(p.n) }} title={`${label(dimension, p.name)}: ${percent(p.n / total)}`} />
        ))}
      </div>
      <div class="mix-key">
        {parts.map((p) => (
          <span>
            <span class={`swatch s${p.slot}`} />
            {label(dimension, p.name)} <b>{percent(p.n / total)}</b>
          </span>
        ))}
      </div>
    </div>
  );
}

export function Panel({ title, tabs, view, onFilter, wide, map }: Props) {
  const [active, setActive] = useState(0);
  const [showMap, setShowMap] = useState(false);
  const [fullMap, setFullMap] = useState(false);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
  const tab = tabs[active] ?? tabs[0]!;
  const column = tab.column ?? "visitors";

  useEffect(() => {
    let live = true;
    setError("");
    api
      .breakdown(view, tab.dimension, expanded ? LONG : 50)
      .then((result) => live && setRows(result.rows))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [view, tab.dimension, expanded]);

  const all = rows ?? [];
  const shown = expanded ? all : all.slice(0, SHORT);
  const top = Math.max(1, ...shown.map((r) => Number(r[column] ?? 0)));

  let mix: Array<{ name: string; n: number; slot: number }> = [];
  if (tab.colors) {
    mix = all.filter((r) => tab.colors![r.value] !== undefined).map((r) => ({ name: r.value, n: Number(r[column] ?? 0), slot: tab.colors![r.value]! }));
  } else if (tab.groups) {
    const sums = new Map<string, number>();
    for (const r of all) sums.set(tab.groups.of(r.value), (sums.get(tab.groups.of(r.value)) ?? 0) + Number(r[column] ?? 0));
    mix = Object.entries(tab.groups.slots).map(([name, slot]) => ({ name, n: sums.get(name) ?? 0, slot }));
  }
  const dot = (value: string): number | undefined => tab.colors?.[value] ?? (tab.groups ? tab.groups.slots[tab.groups.of(value)] : undefined);

  return (
    <section class={wide ? "panel wide" : "panel"}>
      <header class="panel-head">
        <h2>{title}</h2>
        <div class="head-tools">
        {tabs.length > 1 && !showMap ? (
          <nav class="tabs" aria-label={`${title} views`}>
            {tabs.map((t, i) => (
              <button
                type="button"
                class={i === active ? "tab on" : "tab"}
                aria-pressed={i === active}
                onClick={() => {
                  setActive(i);
                  setExpanded(false);
                  setRows(null);
                }}
              >
                {t.label}
              </button>
            ))}
          </nav>
        ) : null}
        {map ? (
          <>
            <button type="button" class={showMap ? "tool on" : "tool"} aria-pressed={showMap} title={showMap ? "Show the list" : "Show a map"} onClick={() => setShowMap(!showMap)}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M1.5 3.5l4-1.5 5 2 4-1.5v10l-4 1.5-5-2-4 1.5z M5.5 2v10 M10.5 4v10" />
              </svg>
            </button>
            <button type="button" class="tool" title="Full screen map" onClick={() => setFullMap(true)}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M2 6V2h4M10 2h4v4M14 10v4h-4M6 14H2v-4" />
              </svg>
            </button>
          </>
        ) : null}
        </div>
      </header>
      {fullMap ? <MapOverlay view={view} onFilter={onFilter} onClose={() => setFullMap(false)} /> : null}
      {showMap ? <WorldMap view={view} onFilter={onFilter} /> : null}
      {showMap ? null : <>
      {mix.length > 0 ? <Mix parts={mix} dimension={tab.dimension} /> : null}
      <div class="cols">
        <span>{tab.label}</span>
        <span>
          {tab.extra ? <span class="extra">{tab.extra.label}</span> : null}
          {column}
        </span>
      </div>
      {error ? <p class="empty">{error}</p> : null}
      {!error && rows && shown.length === 0 ? <p class="empty">Nothing in this range</p> : null}
      {!rows && !error ? <p class="empty">Loading</p> : null}
      <ol class="rows">
        {shown.map((row) => {
          const n = Number(row[column] ?? 0);
          const text = label(tab.dimension, row.value);
          const slot = dot(row.value);
          const name = (
            <>
              {slot !== undefined ? <span class={`swatch s${slot}`} /> : null}
              {text}
            </>
          );
          return (
            <li>
              <span class="bar" style={{ width: `${(n / top) * 100}%` }} />
              {tab.filterable ? (
                <button type="button" class="name" title={`Filter by ${text}`} onClick={() => onFilter(tab.dimension, row.value)}>
                  {name}
                </button>
              ) : (
                <span class="name">{name}</span>
              )}
              {tab.extra ? <span class="extra">{tab.extra.format(Number(row[tab.extra.key] ?? 0))}</span> : null}
              <span class="num">{count(n)}</span>
            </li>
          );
        })}
      </ol>
      {all.length > SHORT ? (
        <button type="button" class="more" onClick={() => setExpanded(!expanded)}>
          {expanded ? "Show fewer" : "Show more"}
        </button>
      ) : null}
      </>}
    </section>
  );
}

const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const STEPS = 6;

function hourLabel(h: number): string {
  return h === 0 ? "12am" : h < 12 ? `${h}am` : h === 12 ? "12pm" : `${h - 12}pm`;
}

/** Visits by weekday and hour, in the site's timezone. */
export function Rhythm({ view, wide }: { view: View; wide?: boolean }) {
  const [grid, setGrid] = useState<number[][] | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    setError("");
    api
      .rhythm(view)
      .then((r) => live && setGrid(r.grid))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [view]);

  const max = grid ? Math.max(0, ...grid.flat()) : 0;
  let peak: [number, number] | null = null;
  if (grid && max > 0) {
    grid.forEach((row, d) => row.forEach((n, h) => n === max && !peak && (peak = [d, h])));
  }
  const busiest = peak as [number, number] | null;

  return (
    <section class={wide ? "panel wide" : "panel"}>
      <header class="panel-head">
        <h2>When people visit</h2>
        {busiest ? (
          <span class="aside">
            Busiest: {DAYS[busiest[0]]} {hourLabel(busiest[1])}
          </span>
        ) : null}
      </header>
      {error ? <p class="empty">{error}</p> : null}
      {!grid && !error ? <p class="empty">Loading</p> : null}
      {grid ? (
        <div class="rhythm" role="table" aria-label="Visits by weekday and hour">
          {grid.map((row, d) => (
            <div class="rhythm-row" role="row">
              <span class="rhythm-day" role="rowheader">
                {DAYS[d]}
              </span>
              {row.map((n, h) => (
                <span
                  role="cell"
                  class={`cell q${n === 0 || max === 0 ? 0 : Math.max(1, Math.ceil((n / max) * STEPS))}`}
                  title={`${DAYS[d]} ${hourLabel(h)}: ${count(n)} ${n === 1 ? "visit" : "visits"}`}
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
          <div class="rhythm-scale" aria-hidden="true">
            <span>Fewer</span>
            {Array.from({ length: STEPS }, (_, i) => (
              <span class={`cell q${i + 1}`} />
            ))}
            <span>More</span>
          </div>
        </div>
      ) : null}
    </section>
  );
}

export const timeOnPage = { key: "timeOnPage" as const, label: "time", format: (n: number) => (n ? duration(n) : "") };
export const bounce = { key: "bounceRate" as const, label: "bounce", format: percent };
