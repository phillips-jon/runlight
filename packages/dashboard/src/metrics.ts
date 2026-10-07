import type { Point, Stats } from "./api.js";
import { count, decimal, duration, percent } from "./format.js";
import { t } from "./i18n.js";

export type MetricKey = keyof Stats;

export interface MetricDef {
  key: MetricKey;
  /** Categorical slot, fixed per metric so a metric keeps its colour whatever else is shown. */
  slot: 1 | 2 | 3 | 4 | 5 | 6;
  format: (n: number) => string;
  lowerIsBetter?: boolean;
}

export const METRICS: MetricDef[] = [
  { key: "visitors", slot: 1, format: count },
  { key: "visits", slot: 2, format: count },
  { key: "pageviews", slot: 3, format: count },
  { key: "viewsPerVisit", slot: 4, format: decimal },
  { key: "bounceRate", slot: 5, format: percent, lowerIsBetter: true },
  { key: "visitDuration", slot: 6, format: duration },
];

export const metricLabel = (m: MetricDef): string => t(`metric.${m.key}`);
/** One line for anyone unsure what a metric counts. */
export const metricHint = (m: MetricDef): string => t(`hint.${m.key}`);

/** At most this many metrics share the chart; more overlapping areas stop being readable. */
export const MAX_CHARTED = 3;

export function metric(key: string): MetricDef | undefined {
  return METRICS.find((m) => m.key === key);
}

export function values(points: Point[], key: MetricKey): number[] {
  return points.map((p) => p[key]);
}
