import type { Point, Stats } from "./api.js";
import { count, duration, percent } from "./format.js";

export type MetricKey = keyof Stats;

export interface MetricDef {
  key: MetricKey;
  label: string;
  /** Categorical slot, fixed per metric so a metric keeps its colour whatever else is shown. */
  slot: 1 | 2 | 3 | 4 | 5 | 6;
  format: (n: number) => string;
  lowerIsBetter?: boolean;
  /** One line under the label, for anyone unsure what it counts. */
  hint: string;
}

export const METRICS: MetricDef[] = [
  { key: "visitors", label: "Visitors", slot: 1, format: count, hint: "Different people, counted once a day" },
  { key: "visits", label: "Visits", slot: 2, format: count, hint: "Sessions: a visit ends after 30 idle minutes" },
  { key: "pageviews", label: "Pageviews", slot: 3, format: count, hint: "Every page loaded, repeats included" },
  { key: "viewsPerVisit", label: "Views per visit", slot: 4, format: (n) => n.toFixed(1), hint: "Pageviews divided by visits" },
  { key: "bounceRate", label: "Bounce rate", slot: 5, format: percent, lowerIsBetter: true, hint: "One page, no clicks, under ten seconds" },
  { key: "visitDuration", label: "Visit duration", slot: 6, format: duration, hint: "Average time actually looking at the page" },
];

/** At most this many metrics share the chart; more overlapping areas stop being readable. */
export const MAX_CHARTED = 3;

export function metric(key: string): MetricDef | undefined {
  return METRICS.find((m) => m.key === key);
}

export function values(points: Point[], key: MetricKey): number[] {
  return points.map((p) => p[key]);
}
