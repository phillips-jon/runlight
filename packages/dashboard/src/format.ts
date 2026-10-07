import { currentLocale } from "./i18n.js";

const cache = new Map<string, Intl.NumberFormat | Intl.DateTimeFormat | Intl.DisplayNames | null>();

function cached<T extends Intl.NumberFormat | Intl.DateTimeFormat | Intl.DisplayNames | null>(key: string, make: () => T): T {
  const full = `${currentLocale()}|${key}`;
  if (!cache.has(full)) {
    try {
      cache.set(full, make());
    } catch {
      cache.set(full, null);
    }
  }
  return cache.get(full) as T;
}

const numbers = (key: string, options: Intl.NumberFormatOptions) => cached(key, () => new Intl.NumberFormat(currentLocale(), options));
const dates = (key: string, options: Intl.DateTimeFormatOptions) => cached(key, () => new Intl.DateTimeFormat(currentLocale(), options));

export function count(n: number): string {
  return n < 10_000 ? exact(n) : numbers("compact", { notation: "compact", maximumFractionDigits: 1 }).format(n);
}

export function exact(n: number): string {
  return numbers("whole", {}).format(n);
}

export function decimal(n: number): string {
  return numbers("decimal", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(n);
}

export function percent(fraction: number): string {
  return numbers("percent", { style: "percent", maximumFractionDigits: 0 }).format(fraction);
}

/** Short and the same in every language: 42s, 1m 07s, 2h 05m. */
export function duration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

/** Change against the comparison period, or null when there is nothing to compare. */
export function change(now: number, before: number | undefined): number | null {
  if (before === undefined || before === 0) return null;
  return (now - before) / before;
}

export function countryName(code: string): string {
  try {
    return cached("regions", () => new Intl.DisplayNames([currentLocale()], { type: "region" }))?.of(code) ?? code;
  } catch {
    return code;
  }
}

export function flag(code: string): string {
  if (!/^[A-Z]{2}$/.test(code)) return "";
  return String.fromCodePoint(...[...code].map((c) => 0x1f1a5 + c.charCodeAt(0)));
}

export function bucketLabel(start: number, interval: string, timezone: string): string {
  const options: Intl.DateTimeFormatOptions =
    interval === "hour"
      ? { hour: "numeric", timeZone: timezone }
      : interval === "month"
        ? { month: "short", year: "numeric", timeZone: timezone }
        : { month: "short", day: "numeric", timeZone: timezone };
  return dates(`bucket|${interval}|${timezone}`, options).format(new Date(start));
}

/** A YYYY-MM-DD date, written out. */
export function day(date: string, withYear = true): string {
  const options: Intl.DateTimeFormatOptions = withYear
    ? { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }
    : { month: "short", day: "numeric", timeZone: "UTC" };
  return dates(`day|${withYear}`, options).format(new Date(`${date}T00:00:00Z`));
}

export function monthTitle(y: number, m: number): string {
  return dates("month", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(y, m, 1)));
}

/** Monday first. */
export function weekdays(style: "narrow" | "short"): string[] {
  const f = dates(`weekday|${style}`, { weekday: style, timeZone: "UTC" });
  // 2024-01-01 was a Monday.
  return Array.from({ length: 7 }, (_, i) => f.format(new Date(Date.UTC(2024, 0, 1 + i))));
}

export function hourLabel(h: number): string {
  return dates("hour", { hour: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(2024, 0, 1, h)));
}

/** An amount in a currency, with cents only when there are some. */
export function money(n: number, currency: string): string {
  const whole = Number.isInteger(n);
  const f = numbers(`money:${currency}:${whole}`, { style: "currency", currency, minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: 2 });
  return f ? f.format(n) : `${n} ${currency}`;
}
