import { useEffect, useRef, useState } from "preact/hooks";
import type { Point } from "./api.js";
import { bucketLabel } from "./format.js";
import type { MetricDef } from "./metrics.js";

interface Props {
  points: Point[];
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
export function Chart({ points, metrics, interval, timezone }: Props) {
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
  const tops = new Map(metrics.map((m) => [m.key, niceMax(Math.max(0, ...points.map((p) => p[m.key])))]));
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
      <svg width={width} height={HEIGHT} role="img" aria-label={`${metrics.map((m) => m.label).join(", ")} over time`} onPointerMove={onMove} onPointerLeave={() => setHover(null)}>
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
          const line = points.map((p, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(m, p[m.key]).toFixed(1)}`).join("");
          const area = points.length ? `${line}L${x(points.length - 1).toFixed(1)},${baseline}L${x(0).toFixed(1)},${baseline}Z` : "";
          return (
            <g class={`series s${m.slot}`}>
              <path class="area" d={area} />
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
          {metrics.map((m) => (
            <span class="tip-row">
              <span class={`swatch s${m.slot}`} />
              <span class="tip-label">{m.label}</span>
              <strong>{m.format(hovered[m.key])}</strong>
            </span>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** A small line of one metric, for its card. */
export function Spark({ points, metric, on }: { points: Point[]; metric: MetricDef; on: boolean }) {
  if (points.length < 2) return <svg class="spark" />;
  const vals = points.map((p) => p[metric.key]);
  const max = Math.max(...vals) || 1;
  const w = 100;
  const h = 28;
  const d = vals.map((v, i) => `${i === 0 ? "M" : "L"}${((i / (vals.length - 1)) * w).toFixed(2)},${(h - 2 - (v / max) * (h - 4)).toFixed(2)}`).join("");
  return (
    <svg class={`spark s${metric.slot}${on ? " on" : ""}`} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <path d={d} vector-effect="non-scaling-stroke" />
    </svg>
  );
}
