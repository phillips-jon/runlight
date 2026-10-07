import { useEffect, useRef, useState } from "preact/hooks";

export const PERIODS: Array<[string, string]> = [
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

export const DEFAULT_PERIOD = "30d";

interface Props {
  period: string;
  from: string;
  to: string;
  /** Today in the site's timezone, YYYY-MM-DD. Later days cannot be picked. */
  today: string;
  onPeriod: (period: string) => void;
  onRange: (from: string, to: string) => void;
}

const WEEKDAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];

function iso(y: number, m: number, d: number): string {
  return new Date(Date.UTC(y, m, d)).toISOString().slice(0, 10);
}

function monthTitle(y: number, m: number): string {
  return new Intl.DateTimeFormat("en", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(y, m, 1)));
}

export function rangeText(from: string, to: string): string {
  const f = new Intl.DateTimeFormat("en", { month: "short", day: "numeric", timeZone: "UTC" });
  const fy = new Intl.DateTimeFormat("en", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const a = new Date(`${from}T00:00:00Z`);
  const b = new Date(`${to}T00:00:00Z`);
  if (from === to) return fy.format(a);
  return a.getUTCFullYear() === b.getUTCFullYear() ? `${f.format(a)} to ${fy.format(b)}` : `${fy.format(a)} to ${fy.format(b)}`;
}

function Month({ y, m, start, end, hoverDay, today, onDay, onHover }: {
  y: number;
  m: number;
  start: string;
  end: string;
  hoverDay: string;
  today: string;
  onDay: (day: string) => void;
  onHover: (day: string) => void;
}) {
  const first = new Date(Date.UTC(y, m, 1));
  const lead = (first.getUTCDay() + 6) % 7;
  const days = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const lastEnd = end || (start && hoverDay ? hoverDay : "");
  const lo = start && lastEnd ? (start < lastEnd ? start : lastEnd) : start;
  const hi = start && lastEnd ? (start < lastEnd ? lastEnd : start) : start;
  return (
    <div class="month">
      <div class="month-title">{monthTitle(y, m)}</div>
      <div class="month-grid" role="grid">
        {WEEKDAYS.map((w) => (
          <span class="weekday">{w}</span>
        ))}
        {Array.from({ length: lead }, () => (
          <span />
        ))}
        {Array.from({ length: days }, (_, i) => {
          const day = iso(y, m, i + 1);
          const future = day > today;
          const inRange = lo && hi && day >= lo && day <= hi;
          const edge = day === lo || day === hi;
          return (
            <button
              type="button"
              class={`day${inRange ? " in" : ""}${edge && lo ? " edge" : ""}${day === today ? " today" : ""}`}
              disabled={future}
              aria-pressed={Boolean(edge && lo)}
              onClick={() => onDay(day)}
              onPointerEnter={() => onHover(day)}
            >
              {i + 1}
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function Picker({ period, from, to, today, onPeriod, onRange }: Props) {
  const [open, setOpen] = useState(false);
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [hoverDay, setHoverDay] = useState("");
  const [ty, tm] = today.split("-").map(Number) as [number, number];
  // The right-hand month; the left one is the month before it.
  const [shown, setShown] = useState<[number, number]>([ty, tm - 1]);
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = (e: Event) => {
      if (e instanceof KeyboardEvent ? e.key === "Escape" : !root.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("pointerdown", close);
      document.removeEventListener("keydown", close);
    };
  }, [open]);

  const openPicker = () => {
    setStart(from);
    setEnd(to);
    const anchor = (to || today).split("-").map(Number) as [number, number];
    setShown([anchor[0], anchor[1] - 1]);
    setOpen(!open);
  };

  const pickDay = (day: string) => {
    if (!start || end) {
      setStart(day);
      setEnd("");
    } else {
      const [a, b] = day < start ? [day, start] : [start, day];
      setStart(a);
      setEnd(b);
    }
  };

  const [ry, rm] = shown;
  const left = new Date(Date.UTC(ry, rm - 1, 1));
  const label = from && to ? rangeText(from, to) : PERIODS.find(([p]) => p === period)?.[1] ?? "Last 30 days";

  return (
    <div class="picker" ref={root}>
      <button type="button" class="picker-button" aria-haspopup="dialog" aria-expanded={open} onClick={openPicker}>
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true">
          <rect x="2" y="3" width="12" height="11" rx="2" />
          <path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" />
        </svg>
        <span>{label}</span>
        <svg class="chev" viewBox="0 0 16 16" aria-hidden="true">
          <path d="M4 6l4 4 4-4" />
        </svg>
      </button>
      {open ? (
        <div class="flyout" role="dialog" aria-label="Choose dates">
          <ul class="presets">
            {PERIODS.map(([value, text]) => (
              <li>
                <button
                  type="button"
                  class={!from && period === value ? "preset on" : "preset"}
                  onClick={() => {
                    onPeriod(value);
                    setOpen(false);
                  }}
                >
                  {text}
                </button>
              </li>
            ))}
          </ul>
          <div class="calendars">
            <div class="cal-nav">
              <button type="button" class="nav" aria-label="Earlier months" onClick={() => setShown([ry, rm - 1])}>
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M10 4l-4 4 4 4" />
                </svg>
              </button>
              <button
                type="button"
                class="nav"
                aria-label="Later months"
                disabled={ry > ty || (ry === ty && rm >= tm - 1)}
                onClick={() => setShown([ry, rm + 1])}
              >
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M6 4l4 4-4 4" />
                </svg>
              </button>
            </div>
            <div class="months" onPointerLeave={() => setHoverDay("")}>
              <Month y={left.getUTCFullYear()} m={left.getUTCMonth()} start={start} end={end} hoverDay={hoverDay} today={today} onDay={pickDay} onHover={setHoverDay} />
              <Month y={new Date(Date.UTC(ry, rm, 1)).getUTCFullYear()} m={new Date(Date.UTC(ry, rm, 1)).getUTCMonth()} start={start} end={end} hoverDay={hoverDay} today={today} onDay={pickDay} onHover={setHoverDay} />
            </div>
            <div class="cal-foot">
              <span class="cal-sel">{start ? (end ? rangeText(start, end) : `${rangeText(start, start)} to ...`) : "Pick a start and an end day"}</span>
              <button type="button" class="ghost" onClick={() => setOpen(false)}>
                Cancel
              </button>
              <button
                type="button"
                class="solid"
                disabled={!start}
                onClick={() => {
                  onRange(start, end || start);
                  setOpen(false);
                }}
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
