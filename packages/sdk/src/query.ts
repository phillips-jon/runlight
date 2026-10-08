/**
 * Report queries: which dimensions exist, where each lives, and how filters
 * are read from a URL. Shared by every store.
 */

/** Dimensions recorded per event. */
export const EVENT_DIMENSIONS = {
  page: "path",
  hostname: "hostname",
  event: "name",
} as const;

/** Dimensions recorded once per session, from its first request. */
export const SESSION_DIMENSIONS = {
  entry: "entry_path",
  exit: "exit_path",
  referrer: "referrer_host",
  source: "source",
  channel: "channel",
  utm_source: "utm_source",
  utm_medium: "utm_medium",
  utm_campaign: "utm_campaign",
  utm_term: "utm_term",
  utm_content: "utm_content",
  country: "country",
  region: "region",
  city: "city",
  browser: "browser",
  browser_version: "browser_version",
  os: "os",
  os_version: "os_version",
  device: "device",
  screen: "screen",
  language: "language",
} as const;

export type EventDimension = keyof typeof EVENT_DIMENSIONS;
export type SessionDimension = keyof typeof SESSION_DIMENSIONS;
/** AI agent fetches are their own rows, outside visits. */
export type FetchDimension = "ai_agent" | "ai_page";
export type Dimension = EventDimension | SessionDimension | FetchDimension;

export const DIMENSIONS: Dimension[] = [
  ...(Object.keys(EVENT_DIMENSIONS) as EventDimension[]),
  ...(Object.keys(SESSION_DIMENSIONS) as SessionDimension[]),
  "ai_agent",
  "ai_page",
];

export type FilterOp = "is" | "not" | "contains";

export interface Filter {
  dimension: EventDimension | SessionDimension;
  op: FilterOp;
  value: string;
}

export interface Query {
  site: string;
  /** Inclusive, epoch milliseconds. */
  from: number;
  /** Exclusive, epoch milliseconds. */
  to: number;
  filters: Filter[];
}

export function isDimension(value: string): value is Dimension {
  return (DIMENSIONS as string[]).includes(value);
}

export function isSessionDimension(value: string): value is SessionDimension {
  return Object.hasOwn(SESSION_DIMENSIONS, value);
}

export function isEventDimension(value: string): value is EventDimension {
  return Object.hasOwn(EVENT_DIMENSIONS, value);
}

/** `dimension:op:value`, where the value may itself contain colons. */
export function parseFilter(text: string): Filter | null {
  const first = text.indexOf(":");
  const second = first < 0 ? -1 : text.indexOf(":", first + 1);
  if (second < 0) return null;
  const dimension = text.slice(0, first);
  const op = text.slice(first + 1, second);
  const value = text.slice(second + 1);
  if (!isSessionDimension(dimension) && !isEventDimension(dimension)) return null;
  if (op !== "is" && op !== "not" && op !== "contains") return null;
  // Paths are recorded percent-encoded, as browsers send them, so "/café" is matched as "/caf%C3%A9".
  const path = dimension === "page" || dimension === "entry" || dimension === "exit";
  return { dimension, op, value: (path ? value.replace(/[^\x21-\x7e]|["<>`{}]/gu, (c) => encodeURIComponent(c)) : value).slice(0, 500) };
}

/** The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values. */
export const MAX_FILTERS = 6;
