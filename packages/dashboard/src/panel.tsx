import { useEffect, useState } from "preact/hooks";
import { api, type Row, type View } from "./api.js";
import { count, countryName, duration, flag, percent } from "./format.js";

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
}

interface Props {
  title: string;
  tabs: Tab[];
  view: View;
  onFilter: (dimension: string, value: string) => void;
}

const SHORT = 9;
const LONG = 100;

export function label(dimension: string, value: string): string {
  if (dimension === "country") return `${flag(value)} ${countryName(value)}`.trim();
  if (dimension === "region") return `${flag(value.slice(0, 2))} ${value}`.trim();
  if (dimension === "device" && value) return value[0]!.toUpperCase() + value.slice(1);
  return value || "(none)";
}

export function Panel({ title, tabs, view, onFilter }: Props) {
  const [active, setActive] = useState(0);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState(false);
  const tab = tabs[active] ?? tabs[0]!;
  const column = tab.column ?? "visitors";

  useEffect(() => {
    let live = true;
    setError("");
    api
      .breakdown(view, tab.dimension, expanded ? LONG : SHORT + 1)
      .then((result) => live && setRows(result.rows))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [view, tab.dimension, expanded]);

  const shown = rows ? (expanded ? rows : rows.slice(0, SHORT)) : [];
  const top = Math.max(1, ...shown.map((r) => Number(r[column] ?? 0)));

  return (
    <section class="panel">
      <header class="panel-head">
        <h2>{title}</h2>
        {tabs.length > 1 ? (
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
      </header>
      <div class="cols">
        <span>{tab.label}</span>
        <span>
          {tab.extra ? <span class="extra">{tab.extra.label}</span> : null}
          {column}
        </span>
      </div>
      {error ? <p class="empty">{error}</p> : null}
      {!error && rows && shown.length === 0 ? <p class="empty">Nothing yet</p> : null}
      {!rows && !error ? <p class="empty loading">Loading</p> : null}
      <ol class="rows">
        {shown.map((row) => {
          const n = Number(row[column] ?? 0);
          const text = label(tab.dimension, row.value);
          return (
            <li key={row.value}>
              <span class="bar" style={{ width: `${(n / top) * 100}%` }} />
              {tab.filterable ? (
                <button type="button" class="name" title={`Filter by ${text}`} onClick={() => onFilter(tab.dimension, row.value)}>
                  {text}
                </button>
              ) : (
                <span class="name">{text}</span>
              )}
              {tab.extra ? <span class="extra">{tab.extra.format(Number(row[tab.extra.key] ?? 0))}</span> : null}
              <span class="num">{count(n)}</span>
            </li>
          );
        })}
      </ol>
      {rows && rows.length > SHORT && !expanded ? (
        <button type="button" class="more" onClick={() => setExpanded(true)}>
          Show more
        </button>
      ) : null}
      {expanded ? (
        <button type="button" class="more" onClick={() => setExpanded(false)}>
          Show fewer
        </button>
      ) : null}
    </section>
  );
}

export const timeOnPage = { key: "timeOnPage" as const, label: "time", format: (n: number) => (n ? duration(n) : "") };
export const bounce = { key: "bounceRate" as const, label: "bounce", format: percent };
