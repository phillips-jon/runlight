import { useEffect, useRef, useState } from "preact/hooks";
import type { Point } from "./api.js";
import { bucketLabel } from "./format.js";
import { t } from "./i18n.js";
import { MAX_FILLED, metricLabel, type MetricDef } from "./metrics.js";

interface Props {
  points: Point[];
  /** The comparison period's points, by position, drawn dashed behind. */
  previous?: Point[];
  metrics: MetricDef[];
  interval: string;
  timezone: string;
}

const HEIGHT = 300;
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
export function Chart({ points, previous, metrics, interval, timezone }: Props) {
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

  const single = metrics.length === 1 ? metrics[0] : undefined;
  const pad = { ...PAD, left: single ? PAD.left : 16 };
  const innerW = width - pad.left - pad.right;
  const innerH = HEIGHT - pad.top - pad.bottom;
  const step = points.length > 1 ? innerW / (points.length - 1) : 0;
  const x = (i: number) => pad.left + (points.length > 1 ? i * step : innerW / 2);
  const before = previous ?? [];
  const tops = new Map(metrics.map((m) => [m.key, niceMax(Math.max(0, ...points.map((p) => p[m.key]), ...before.map((p) => p[m.key])))]));
  const y = (m: MetricDef, v: number) => pad.top + innerH - (v / (tops.get(m.key) ?? 1)) * innerH;
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
      <svg width={width} height={HEIGHT} role="img" aria-label={t("chart.label", { metrics: metrics.map(metricLabel).join(", ") })} onPointerMove={onMove} onPointerLeave={() => setHover(null)}>
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
          const then = smooth(before.map((_, i) => x(i)), before.map((p) => y(m, p[m.key])));
          return <path class={`then s${m.slot}`} d={then} />;
        })}
        {metrics.map((m) => {
          const line = smooth(points.map((_, i) => x(i)), points.map((p) => y(m, p[m.key])));
          const area = points.length ? `${line}L${x(points.length - 1).toFixed(1)},${baseline}L${x(0).toFixed(1)},${baseline}Z` : "";
          return (
            <g class={`series s${m.slot}`}>
              {metrics.length <= MAX_FILLED ? <path class="area" d={area} /> : null}
              <path class="line" d={line} />
            </g>
          );
        })}
        {hovered && hover !== null ? (
          <g>
            <line class="cursor" x1={x(hover)} x2={x(hover)} y1={pad.top} y2={baseline} />
            {metrics.map((m) => (
              <circle class={`dot s${m.slot}`} cx={x(hover)} cy={y(m, hovered[m.key])} r={4.5} />
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
                <span class="tip-label">{metricLabel(m)}</span>
                <strong>{m.format(hovered[m.key])}</strong>
                {then ? <span class="tip-then">{m.format(then[m.key])}</span> : null}
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

/** A faint area of one metric over the range, filling the bottom of its card. */
export function Spark({ points, metric, on }: { points: Point[]; metric: MetricDef; on: boolean }) {
  if (points.length < 2) return null;
  const vals = points.map((p) => p[metric.key]);
  const max = Math.max(...vals);
  const min = Math.min(...vals);
  const w = 200;
  const h = 60;
  // Its own low to high, in the lower part of the card, so a steady metric
  // still shows its movement without climbing behind the number.
  // The floor sits one span below the lowest point, so small wobbles stay small.
  const floor = Math.max(0, min - (max - min));
  const span = max - floor || 1;
  const xs = vals.map((_, i) => (i / (vals.length - 1)) * w);
  const ys = vals.map((v) => h - 3 - ((v - floor) / span) * (h * 0.62));
  const line = smooth(xs, ys);
  return (
    <svg class={`spark s${metric.slot}${on ? " on" : ""}`} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <path class="spark-area" d={`${line}L${w},${h}L0,${h}Z`} />
      <path class="spark-line" d={line} vector-effect="non-scaling-stroke" />
    </svg>
  );
}
