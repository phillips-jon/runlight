const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const whole = new Intl.NumberFormat("en");

export function count(n: number): string {
  return n < 10_000 ? whole.format(n) : compact.format(n);
}

export function exact(n: number): string {
  return whole.format(n);
}

export function percent(fraction: number): string {
  return `${Math.round(fraction * 100)}%`;
}

export function duration(ms: number): string {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

/** Change against the previous period, or null when there is nothing to compare. */
export function change(now: number, before: number | undefined): number | null {
  if (before === undefined || before === 0) return null;
  return (now - before) / before;
}

const regions = (() => {
  try {
    return new Intl.DisplayNames(["en"], { type: "region" });
  } catch {
    return null;
  }
})();

export function countryName(code: string): string {
  try {
    return regions?.of(code) ?? code;
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
  return new Intl.DateTimeFormat("en", options).format(new Date(start));
}
