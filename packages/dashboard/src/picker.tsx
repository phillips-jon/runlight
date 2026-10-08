import { useEffect, useRef, useState } from "preact/hooks";
import { day as dayText, monthTitle, weekdays } from "./format.js";
import { t, type Key } from "./i18n.js";

export const PERIODS = ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"] as const;
export const DEFAULT_PERIOD = "30d";

export const periodLabel = (period: string): string =>
  (PERIODS as readonly string[]).includes(period) ? t(`period.${period}` as Key) : t("period.30d");

function iso(y: number, m: number, d: number): string {
  return new Date(Date.UTC(y, m, d)).toISOString().slice(0, 10);
}

export function rangeText(from: string, to: string): string {
  if (from === to) return dayText(from);
  const sameYear = from.slice(0, 4) === to.slice(0, 4);
  return t("calendar.range", { from: dayText(from, !sameYear), to: dayText(to) });
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
        {weekdays("short").map((w) => (
          <span class="weekday">{w.slice(0, 2)}</span>
        ))}
        {Array.from({ length: lead }, () => (
          <span />
        ))}
        {Array.from({ length: days }, (_, i) => {
          const day = iso(y, m, i + 1);
          const inRange = lo && hi && day >= lo && day <= hi;
          const edge = Boolean(lo) && (day === lo || day === hi);
          return (
            <button
              type="button"
              class={`day${inRange ? " in" : ""}${edge ? " edge" : ""}${day === today ? " today" : ""}`}
              disabled={day > today}
              aria-pressed={edge}
              aria-label={dayText(day)}
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

/** Two months side by side, picking a start and an end day. */
export function Calendar({ from, to, today, onApply, onCancel, applyLabel }: {
  from: string;
  to: string;
  today: string;
  onApply: (from: string, to: string) => void;
  onCancel: () => void;
  applyLabel?: string;
}) {
  const [start, setStart] = useState(from);
  const [end, setEnd] = useState(to);
  const [hoverDay, setHoverDay] = useState("");
  const [ty, tm] = today.split("-").map(Number) as [number, number];
  const anchor = (to || today).split("-").map(Number) as [number, number];
  // The right-hand month; the left one is the month before it.
  const [shown, setShown] = useState<[number, number]>([anchor[0], anchor[1] - 1]);

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
  const right = new Date(Date.UTC(ry, rm, 1));
  const atLatest = right.getUTCFullYear() > ty || (right.getUTCFullYear() === ty && right.getUTCMonth() >= tm - 1);

  return (
    <div class="calendars">
      <div class="cal-nav">
        <button type="button" class="nav" aria-label={t("calendar.earlier")} onClick={() => setShown([ry, rm - 1])}>
          <svg viewBox="0 0 16 16" aria-hidden="true">
            <path d="M10 4l-4 4 4 4" />
          </svg>
        </button>
        <button type="button" class="nav" aria-label={t("calendar.later")} disabled={atLatest} onClick={() => setShown([ry, rm + 1])}>
          <svg viewBox="0 0 16 16" aria-hidden="true">
            <path d="M6 4l4 4-4 4" />
          </svg>
        </button>
      </div>
      <div class="months" onPointerLeave={() => setHoverDay("")}>
        <Month y={left.getUTCFullYear()} m={left.getUTCMonth()} start={start} end={end} hoverDay={hoverDay} today={today} onDay={pickDay} onHover={setHoverDay} />
        <Month y={right.getUTCFullYear()} m={right.getUTCMonth()} start={start} end={end} hoverDay={hoverDay} today={today} onDay={pickDay} onHover={setHoverDay} />
      </div>
      <div class="cal-foot">
        <span class="cal-sel">{start ? (end ? rangeText(start, end) : t("calendar.open", { from: dayText(start) })) : t("calendar.pick")}</span>
        <button type="button" class="ghost" onClick={onCancel}>
          {t("common.cancel")}
        </button>
        <button type="button" class="solid" disabled={!start} onClick={() => onApply(start, end || start)}>
          {applyLabel ?? t("calendar.apply")}
        </button>
      </div>
    </div>
  );
}

export function useFlyout() {
  const [open, setOpen] = useState(false);
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
  return { open, setOpen, root };
}

export const Chevron = () => (
  <svg class="chev" viewBox="0 0 16 16" aria-hidden="true">
    <path d="M4 6l4 4 4-4" />
  </svg>
);

export function Picker({ period, from, to, today, onPeriod, onRange }: {
  period: string;
  from: string;
  to: string;
  /** Today in the site's timezone, YYYY-MM-DD. Later days cannot be picked. */
  today: string;
  onPeriod: (period: string) => void;
  onRange: (from: string, to: string) => void;
}) {
  const { open, setOpen, root } = useFlyout();
  const label = from && to ? rangeText(from, to) : periodLabel(period);

  return (
    <div class="picker" ref={root}>
      <button type="button" class="picker-button" aria-haspopup="dialog" aria-expanded={open} onClick={() => setOpen(!open)}>
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true">
          <rect x="2" y="3" width="12" height="11" rx="2" />
          <path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" />
        </svg>
        <span>{label}</span>
        <Chevron />
      </button>
      {open ? (
        <div class="flyout" role="dialog" aria-label={t("calendar.dialog")}>
          <ul class="presets">
            {PERIODS.map((value) => (
              <li>
                <button
                  type="button"
                  class={!from && period === value ? "preset on" : "preset"}
                  onClick={() => {
                    onPeriod(value);
                    setOpen(false);
                  }}
                >
                  {periodLabel(value)}
                </button>
              </li>
            ))}
          </ul>
          <Calendar
            from={from}
            to={to}
            today={today}
            onCancel={() => setOpen(false)}
            onApply={(a, b) => {
              onRange(a, b);
              setOpen(false);
            }}
          />
        </div>
      ) : null}
    </div>
  );
}

export type CompareMode = "previous" | "year" | "custom" | "off";
export const COMPARES: CompareMode[] = ["previous", "year", "custom", "off"];

/** What the current range is compared with. */
export function ComparePicker({ mode, from, to, today, allTime, onChange }: {
  mode: CompareMode;
  /** All time has nothing before it to compare with, so only "No comparison" can be picked. */
  allTime?: boolean;
  from: string;
  to: string;
  today: string;
  onChange: (mode: CompareMode, from?: string, to?: string) => void;
}) {
  const { open, setOpen, root } = useFlyout();
  const [custom, setCustom] = useState(false);
  const label = mode === "custom" && from && to ? rangeText(from, to) : t(`compare.${mode}`);

  return (
    <div class="picker" ref={root}>
      <button
        type="button"
        class={mode === "off" ? "picker-button compare off" : "picker-button compare"}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => {
          setCustom(mode === "custom");
          setOpen(!open);
        }}
      >
        <span class="compare-vs">{t("compare.vs")}</span>
        <span>{label}</span>
        <Chevron />
      </button>
      {open ? (
        <div class="flyout compare-flyout" role="dialog" aria-label={t("compare.dialog")}>
          <ul class="presets">
            <li class="presets-title">{t("compare.title")}</li>
            {COMPARES.map((value) => (
              <li>
                <button
                  type="button"
                  class={(custom ? value === "custom" : mode === value) ? "preset on" : "preset"}
                  disabled={allTime && value !== "off"}
                  onClick={() => {
                    if (value === "custom") return setCustom(true);
                    onChange(value);
                    setOpen(false);
                  }}
                >
                  {t(`compare.${value}`)}
                </button>
              </li>
            ))}
            {allTime ? <li class="presets-note">{t("compare.allTime")}</li> : null}
          </ul>
          {custom && !allTime ? (
            <Calendar
              from={from}
              to={to}
              today={today}
              applyLabel={t("compare.apply")}
              onCancel={() => setOpen(false)}
              onApply={(a, b) => {
                onChange("custom", a, b);
                setOpen(false);
              }}
            />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
