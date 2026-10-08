/**
 * Dates in a site's timezone, without a date library. Ranges are computed
 * here as epoch milliseconds so the database only ever compares integers.
 */
import type { Bucket } from "./store.js";

export type Interval = "hour" | "day" | "week" | "month";

export const PERIODS = ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"] as const;
export type Period = (typeof PERIODS)[number];

export interface Range {
  /** Inclusive. */
  from: number;
  /** Exclusive. */
  to: number;
  /** First and last local dates covered, YYYY-MM-DD, both inclusive. */
  fromDate: string;
  toDate: string;
  interval: Interval;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
  let f = formatters.get(timezone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(timezone, f);
  }
  return f;
}

export function isTimezone(value: string): boolean {
  try {
    formatter(value);
    return true;
  } catch {
    return false;
  }
}

function parts(ts: number, timezone: string): number[] {
  const out: Record<string, number> = {};
  for (const part of formatter(timezone).formatToParts(new Date(ts))) {
    if (part.type !== "literal") out[part.type] = Number(part.value);
  }
  return [out.year ?? 0, out.month ?? 1, out.day ?? 1, out.hour ?? 0, out.minute ?? 0, out.second ?? 0];
}

/** Milliseconds the zone is ahead of UTC at an instant. */
function offset(ts: number, timezone: string): number {
  const [y, mo, d, h, mi, s] = parts(ts, timezone);
  return Date.UTC(y!, mo! - 1, d!, h!, mi!, s!) - (ts - (ts % 1000));
}

/** The instant a local date (and hour) begins in a zone. */
export function startOf(date: string, timezone: string, hour = 0): number {
  const [y, m, d] = date.split("-").map(Number);
  const guess = Date.UTC(y!, m! - 1, d!, hour);
  const first = guess - offset(guess, timezone);
  let at = guess - offset(first, timezone);
  // Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it never
  // happens, and the sum above lands before it; the day then begins when the clocks land, at most a
  // few quarter hours on.
  for (let i = 0; i < 8; i++) {
    const [ly, lm, ld, lh] = parts(at, timezone);
    if (Date.UTC(ly!, lm! - 1, ld!, lh!) >= guess) break;
    at += 15 * 60_000;
  }
  return at;
}

/** The local date of an instant, YYYY-MM-DD. */
export function localDate(ts: number, timezone: string): string {
  const [y, m, d] = parts(ts, timezone);
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y!, m! - 1, d! + days)).toISOString().slice(0, 10);
}

export function addMonths(date: string, months: number): string {
  const [y, m] = date.split("-").map(Number);
  return new Date(Date.UTC(y!, m! - 1 + months, 1)).toISOString().slice(0, 10);
}

export function isDate(value: string): boolean {
  // Years from 1900 to 9998, so the day after any date is a date too.
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value < "1900" || value >= "9999") return false;
  // A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

function defaultInterval(fromDate: string, toDate: string): Interval {
  const days = daysBetween(fromDate, toDate);
  if (days < 1) return "hour";
  if (days <= 92) return "day";
  return "month";
}

/**
 * A named period or custom dates as a range in the site's timezone.
 * `firstDate` is the earliest local date with data, used by "all".
 */
export function resolveRange(
  input: { period?: string | null; from?: string | null; to?: string | null; interval?: string | null },
  timezone: string,
  now: number,
  firstDate?: string,
): Range | null {
  const today = localDate(now, timezone);
  let fromDate: string;
  let toDate: string;

  if (input.from || input.to) {
    if (!input.from || !input.to || !isDate(input.from) || !isDate(input.to) || input.from > input.to) return null;
    fromDate = input.from;
    toDate = input.to;
  } else {
    const period = (input.period ?? "30d") as Period;
    switch (period) {
      case "today": fromDate = toDate = today; break;
      case "yesterday": fromDate = toDate = addDays(today, -1); break;
      case "7d": fromDate = addDays(today, -6); toDate = today; break;
      case "30d": fromDate = addDays(today, -29); toDate = today; break;
      case "90d": fromDate = addDays(today, -89); toDate = today; break;
      case "month": fromDate = `${today.slice(0, 8)}01`; toDate = today; break;
      case "last_month": fromDate = addMonths(today, -1); toDate = addDays(`${today.slice(0, 8)}01`, -1); break;
      case "year": fromDate = `${today.slice(0, 4)}-01-01`; toDate = today; break;
      case "12mo": fromDate = addMonths(today, -11); toDate = today; break;
      case "all": fromDate = firstDate && firstDate < today ? firstDate : today; toDate = today; break;
      default: return null;
    }
  }

  const interval = (["hour", "day", "week", "month"] as const).find((i) => i === input.interval) ?? defaultInterval(fromDate, toDate);
  return { from: startOf(fromDate, timezone), to: startOf(addDays(toDate, 1), timezone), fromDate, toDate, interval };
}

export type CompareMode = "previous" | "year" | "custom" | "off";

function addYears(date: string, years: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(y! + years, m! - 1, d!));
  // Feb 29 in a year without one becomes Feb 28, not Mar 1.
  if (shifted.getUTCMonth() !== m! - 1) shifted.setUTCDate(0);
  return shifted.toISOString().slice(0, 10);
}

/**
 * The range a period is compared with: the same number of days just before
 * it, the same dates a year earlier, or custom dates. Null for "off" or bad
 * custom dates.
 */
export function compareRange(
  range: Range,
  mode: CompareMode,
  timezone: string,
  custom: { from?: string | null; to?: string | null } = {},
): Range | null {
  let fromDate: string;
  let toDate: string;
  if (mode === "off") return null;
  if (mode === "year") {
    fromDate = addYears(range.fromDate, -1);
    toDate = addYears(range.toDate, -1);
  } else if (mode === "custom") {
    if (!custom.from || !custom.to || !isDate(custom.from) || !isDate(custom.to) || custom.from > custom.to) return null;
    fromDate = custom.from;
    toDate = custom.to;
  } else {
    const days = daysBetween(range.fromDate, range.toDate) + 1;
    fromDate = addDays(range.fromDate, -days);
    toDate = addDays(range.fromDate, -1);
  }
  return { from: startOf(fromDate, timezone), to: startOf(addDays(toDate, 1), timezone), fromDate, toDate, interval: range.interval };
}


const MAX_BUCKETS = 1000;
/** A month of hours. Longer hourly ranges are cut off rather than refused. */
const MAX_HOURS = 744;

/** Chart buckets covering a range, each starting on a local boundary. */
export function buckets(range: Range, timezone: string): Bucket[] {
  const starts: number[] = [];
  if (range.interval === "hour") {
    for (let t = range.from; t < range.to && starts.length < MAX_HOURS; t += 3_600_000) starts.push(t);
  } else {
    let date = range.fromDate;
    if (range.interval === "week") {
      const weekday = (new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7;
      date = addDays(date, -weekday);
    } else if (range.interval === "month") {
      date = `${date.slice(0, 8)}01`;
    }
    while (date <= range.toDate && starts.length < MAX_BUCKETS) {
      starts.push(startOf(date, timezone));
      date = range.interval === "day" ? addDays(date, 1) : range.interval === "week" ? addDays(date, 7) : addMonths(date, 1);
    }
  }
  return starts.map((start, i) => ({
    start: Math.max(start, range.from),
    end: Math.min(starts[i + 1] ?? range.to, range.to),
  }));
}

/** Monday is 0. */
export function localWeekdayHour(ts: number, timezone: string): [weekday: number, hour: number] {
  const [y, m, d, h] = parts(ts, timezone);
  const weekday = (new Date(Date.UTC(y!, m! - 1, d!)).getUTCDay() + 6) % 7;
  return [weekday, h!];
}
