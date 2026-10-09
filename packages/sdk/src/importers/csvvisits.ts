/**
 * Visit history from a CSV file, in one of two shapes: Umami's data export
 * (one row per pageview or event, as in its website_event table) or Runlight's
 * own, documented on the dashboard docs page. The dashboard reads the file,
 * sorts it with rowTime, and sends it in batches; the server turns each row
 * into a hit with csvHit. Nothing here touches a database, so the dashboard
 * bundles the same code.
 */
import type { ImportedHit } from "./visits.js";

export type CsvFormat = "umami" | "runlight";

/** At most this many rows in one request. */
export const CSV_BATCH = 2000;

/** Which shape a file is, from its header row (lower case, as the dashboard reads it). */
export function csvFormat(columns: string[]): CsvFormat | null {
  const has = (c: string) => columns.includes(c);
  if (has("created_at") && has("url_path")) return "umami";
  if (has("time") && (has("path") || has("url"))) return "runlight";
  return null;
}

/**
 * A row's time in milliseconds, or NaN. ISO 8601 with or without a zone, "2024-05-01 12:34:56"
 * (both read as UTC when no zone is given, as Umami writes them), or a Unix time in seconds or milliseconds.
 */
export function rowTime(row: Record<string, string>, format: CsvFormat): number {
  const text = (format === "umami" ? row.created_at : row.time)?.trim() ?? "";
  if (!text) return NaN;
  if (/^\d+(\.\d+)?$/.test(text)) {
    const n = Number(text);
    return n < 1e12 ? Math.round(n * 1000) : Math.round(n);
  }
  const iso = text.replace(" ", "T");
  return Date.parse(/[zZ]|[+-]\d\d:?\d\d$/.test(iso) || !/T\d/.test(iso) ? iso : `${iso}Z`);
}

const cell = (row: Record<string, string>, ...names: string[]) => {
  for (const n of names) if (row[n]?.trim()) return row[n]!.trim();
  return "";
};

/** A row with no visitor is its own visit, keyed by its whole content so a second import gives it the same ids. */
const ownKey = (row: Record<string, string>) => `row:${JSON.stringify(Object.entries(row).sort(([a], [b]) => (a < b ? -1 : 1)))}`;

/** A referrer as a full address: a bare domain gains https://. */
const fullReferrer = (value: string) => (!value ? "" : /^[a-z][a-z0-9+.-]*:\/\//i.test(value) ? value : `https://${value}`);

/**
 * One row as a hit and the namespace its ids are made in, or null for a row that is not a pageview or a
 * named event, or has no time. Umami rows use the namespace the Umami API import does, so the same visits
 * brought in both ways get the same ids.
 */
export function csvHit(row: Record<string, string>, format: CsvFormat): { ns: string; hit: ImportedHit } | null {
  const ts = rowTime(row, format);
  if (!Number.isFinite(ts)) return null;
  if (format === "umami") {
    const type = cell(row, "event_type") || "1";
    const name = cell(row, "event_name");
    if (type !== "1" && !(type === "2" && name)) return null;
    const website = cell(row, "website_id");
    return {
      ns: website ? `umami-visits:${website}` : "umami-csv",
      hit: {
        ts,
        key: cell(row, "session_id", "visit_id") || ownKey(row),
        kind: type === "1" ? "pageview" : "event",
        hostname: cell(row, "hostname"),
        path: cell(row, "url_path") || "/",
        query: cell(row, "url_query"),
        referrer: (() => {
          const domain = cell(row, "referrer_domain");
          if (!domain) return "";
          const query = cell(row, "referrer_query");
          return `https://${domain}${cell(row, "referrer_path") || "/"}${query ? `?${query.replace(/^\?/, "")}` : ""}`;
        })(),
        title: cell(row, "page_title"),
        name: type === "2" ? name : "",
        country: cell(row, "country"),
        region: cell(row, "subdivision1", "region"),
        city: cell(row, "city"),
        browser: cell(row, "browser"),
        os: cell(row, "os"),
        device: cell(row, "device"),
        screen: cell(row, "screen"),
        language: cell(row, "language"),
      },
    };
  }
  // Runlight's own shape: a full url, or a path (with its query) and a hostname.
  let hostname = cell(row, "hostname");
  let path = cell(row, "path");
  let query = "";
  const url = cell(row, "url");
  if (url) {
    try {
      const u = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(url) ? url : `https://${url}`);
      hostname ||= u.hostname;
      path = u.pathname;
      query = u.search.slice(1);
    } catch {
      return null;
    }
  } else {
    const at = path.indexOf("?");
    if (at >= 0) [path, query] = [path.slice(0, at), path.slice(at + 1)];
  }
  if (!path.startsWith("/")) path = `/${path}`;
  const name = cell(row, "event");
  return {
    ns: "csv",
    hit: {
      ts,
      // Without a visitor column every row is its own visit.
      key: cell(row, "visitor") || ownKey(row),
      kind: name ? "event" : "pageview",
      hostname,
      path,
      query,
      referrer: fullReferrer(cell(row, "referrer")),
      title: cell(row, "title"),
      name,
      country: cell(row, "country"),
      region: cell(row, "region"),
      city: cell(row, "city"),
      browser: cell(row, "browser"),
      os: cell(row, "os"),
      device: cell(row, "device"),
      screen: cell(row, "screen"),
      language: cell(row, "language"),
    },
  };
}
