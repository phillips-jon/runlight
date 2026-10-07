/**
 * Runlight: privacy friendly web analytics that lives inside your app.
 *
 *   import { runlight } from "@runlight/sdk";
 *   import { sqlite } from "@runlight/sdk/sqlite";
 *
 *   export const rl = runlight({ store: sqlite({ path: "./data/runlight.db" }) });
 *   // app/runlight/[[...path]]/route.ts
 *   export const { GET, POST, PUT, PATCH, DELETE, OPTIONS } = rl.routes();
 *
 * Then add <script defer src="/runlight/s.js"></script> to your pages.
 */
import { Runlight, type RunlightOptions } from "./runlight.js";

export function runlight(options: RunlightOptions): Runlight {
  return new Runlight(options);
}

export { Runlight, SESSION_IDLE_MS } from "./runlight.js";
export type { RunlightOptions, SiteOptions, RequestContext } from "./runlight.js";
export type { Routes, RoutesOptions, FetchHandler } from "./routes.js";
export type { GeoLookup, Location } from "./geo.js";
export { SqlStore, BOUNCE_MS } from "./store.js";
export { Links, LinkError, SLUG_PATTERN } from "./links.js";
export type { LinkInput } from "./links.js";
export type { LinkRow } from "./store.js";
export type { Db, Stats, SeriesPoint, BreakdownRow, Realtime } from "./store.js";
export { DIMENSIONS } from "./query.js";
export type { Dimension, Filter, Query } from "./query.js";
export { VERSION, API_VERSION } from "./version.js";
