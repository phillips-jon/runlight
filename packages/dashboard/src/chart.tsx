import { useEffect, useRef, useState } from "preact/hooks";
import { bucketLabel } from "./format.js";
import { t } from "./i18n.js";
import { MAX_FILLED, metricLabel, type MetricDef } from "./metrics.js";

/** One line on the chart: which value of each point, its colour slot, and how to show it. */
export interface Series {
  key: string;
  slot: number;
  label: string;
  format: (n: number) => string;
}

type ChartPoint = { start: number } & Record<string, number>;

interface Props {
  points: ChartPoint[];
  /** The comparison period's points, by position, drawn dashed behind. */
  previous?: ChartPoint[];
  metrics: Series[];
  interval: string;
  timezone: string;
  /** Several lines on one axis, for series in the same unit (clicks and visitors). */
  shared?: boolean;
  height?: number;
}

/** A dashboard metric as a chart series. */
export const asSeries = (m: MetricDef): Series => ({ key: m.key, slot: m.slot, label: metricLabel(m), format: m.format });
const PAD = { top: 18, right: 14, bottom: 30, left: 52 };

/** A round top for the axis. */
function niceMax(value: number): number {
  if (value <= 0) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    if (step * power >= value) return step * power;
  }
  return 10 * power;
}

/**
 * One metric draws on its own axis. Several are each scaled to their own
 * peak, so their shapes can be compared without a second axis pretending
 * that visitors and a bounce rate share a unit; the tooltip gives the
 * real values.
 */
export function Chart({ points, previous, metrics, interval, timezone, shared, height = 300 }: Props) {
  const HEIGHT = height;
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const [hover, setHover] = useState<number | null>(null);

  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => entry && setWidth(Math.max(280, entry.contentRect.width)));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // One axis when there is one line, or several in the same unit.
  const single = metrics.length === 1 || shared ? metrics[0] : undefined;
  const pad = { ...PAD, left: single ? PAD.left : 16 };
  const innerW = width - pad.left - pad.right;
  const innerH = HEIGHT - pad.top - pad.bottom;
  const step = points.length > 1 ? innerW / (points.length - 1) : 0;
  const x = (i: number) => pad.left + (points.length > 1 ? i * step : innerW / 2);
  const before = previous ?? [];
  const peak = (m: Series) => Math.max(0, ...points.map((p) => p[m.key] ?? 0), ...before.map((p) => p[m.key] ?? 0));
  const common = niceMax(Math.max(0, ...metrics.map(peak)));
  const tops = new Map(metrics.map((m) => [m.key, shared ? common : niceMax(peak(m))]));
  const y = (m: Series, v: number) => pad.top + innerH - ((v ?? 0) / (tops.get(m.key) ?? 1)) * innerH;
  const baseline = pad.top + innerH;
  const labelEvery = Math.max(1, Math.ceil(points.length / Math.max(2, Math.floor(innerW / 92))));

  const onMove = (event: PointerEvent) => {
    const rect = (event.currentTarget as SVGElement).getBoundingClientRect();
    const i = Math.round((event.clientX - rect.left - pad.left) / (step || 1));
    setHover(points.length ? Math.min(points.length - 1, Math.max(0, i)) : null);
  };

  const hovered = hover !== null ? points[hover] : undefined;
  const gridFractions = [0, 0.25, 0.5, 0.75, 1];

  return (
    <div class="chart" ref={box}>
      <svg width={width} height={HEIGHT} role="img" aria-label={t("chart.label", { metrics: metrics.map((m) => m.label).join(", ") })} onPointerMove={onMove} onPointerLeave={() => setHover(null)}>
        {gridFractions.map((f) => (
          <line class={f === 0 ? "gridline base" : "gridline"} x1={pad.left} x2={width - pad.right} y1={baseline - f * innerH} y2={baseline - f * innerH} />
        ))}
        {single
          ? gridFractions.filter((_, i) => i % 2 === 0).map((f) => (
              <text class="axis" x={pad.left - 10} y={baseline - f * innerH + 4} text-anchor="end">
                {single.format((tops.get(single.key) ?? 1) * f)}
              </text>
            ))
          : null}
        {points.map((p, i) =>
          i % labelEvery === 0 ? (
            <text class="axis" x={x(i)} y={HEIGHT - 8} text-anchor={i === 0 ? "start" : "middle"}>
              {bucketLabel(p.start, interval, timezone)}
            </text>
          ) : null,
        )}
        {metrics.map((m) => {
          if (before.length < 2) return null;
          const then = smooth(before.map((_, i) => x(i)), before.map((p) => y(m, p[m.key]!)));
          return <path class={`then s${m.slot}`} d={then} />;
        })}
        {metrics.map((m) => {
          const line = smooth(points.map((_, i) => x(i)), points.map((p) => y(m, p[m.key]!)));
          const area = points.length ? `${line}L${x(points.length - 1).toFixed(1)},${baseline}L${x(0).toFixed(1)},${baseline}Z` : "";
          return (
            <g class={`series s${m.slot}`}>
              {metrics.length <= MAX_FILLED && (!shared || m === metrics[0]) ? <path class="area" d={area} /> : null}
              <path class="line" d={line} />
            </g>
          );
        })}
        {hovered && hover !== null ? (
          <g>
            <line class="cursor" x1={x(hover)} x2={x(hover)} y1={pad.top} y2={baseline} />
            {metrics.map((m) => (
              <circle class={`dot s${m.slot}`} cx={x(hover)} cy={y(m, hovered[m.key]!)} r={4.5} />
            ))}
          </g>
        ) : null}
      </svg>
      {hovered && hover !== null ? (
        <div class={x(hover) > width / 2 ? "tip left" : "tip"} style={{ left: `${x(hover)}px` }}>
          <span class="tip-when">{bucketLabel(hovered.start, interval === "hour" ? "hour" : interval === "month" ? "month" : "day", timezone)}</span>
          {metrics.map((m) => {
            const then = hover !== null ? before[hover] : undefined;
            return (
              <span class="tip-row">
                <span class={`swatch s${m.slot}`} />
                <span class="tip-label">{m.label}</span>
                <strong>{m.format(hovered[m.key] ?? 0)}</strong>
                {then ? <span class="tip-then">{m.format(then[m.key] ?? 0)}</span> : null}
              </span>
            );
          })}
          {hover !== null && before[hover] ? (
            <span class="tip-then-when">
              {t("chart.then", { when: bucketLabel(before[hover]!.start, interval === "hour" ? "hour" : interval === "month" ? "month" : "day", timezone) })}
            </span>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/**
 * A smooth path through points (Catmull-Rom as cubic Beziers), with each
 * control point held inside its segment's vertical range so the curve
 * never overshoots below zero or above a peak.
 */
export function smooth(xs: number[], ys: number[]): string {
  if (xs.length === 0) return "";
  let d = `M${xs[0]!.toFixed(2)},${ys[0]!.toFixed(2)}`;
  for (let i = 0; i < xs.length - 1; i++) {
    const x0 = xs[i - 1] ?? xs[i]!;
    const y0 = ys[i - 1] ?? ys[i]!;
    const x1 = xs[i]!;
    const y1 = ys[i]!;
    const x2 = xs[i + 1]!;
    const y2 = ys[i + 1]!;
    const x3 = xs[i + 2] ?? x2;
    const y3 = ys[i + 2] ?? y2;
    const lo = Math.min(y1, y2);
    const hi = Math.max(y1, y2);
    const c1y = Math.min(hi, Math.max(lo, y1 + (y2 - y0) / 6));
    const c2y = Math.min(hi, Math.max(lo, y2 - (y3 - y1) / 6));
    d += `C${(x1 + (x2 - x0) / 6).toFixed(2)},${c1y.toFixed(2)} ${(x2 - (x3 - x1) / 6).toFixed(2)},${c2y.toFixed(2)} ${x2.toFixed(2)},${y2.toFixed(2)}`;
  }
  return d;
}

