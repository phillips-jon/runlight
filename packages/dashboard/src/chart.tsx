import { useEffect, useRef, useState } from "preact/hooks";
import type { Point } from "./api.js";
import { bucketLabel, count } from "./format.js";

export type Metric = "visitors" | "visits" | "pageviews";

interface Props {
  points: Point[];
  metric: Metric;
  interval: string;
  timezone: string;
}

const HEIGHT = 240;
const PAD = { top: 16, right: 12, bottom: 28, left: 44 };

/** A round top for the axis: 1, 2 or 5 times a power of ten. */
function niceMax(value: number): number {
  if (value <= 4) return 4;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 2.5, 5, 10]) {
    if (step * power >= value) return step * power;
  }
  return 10 * power;
}

export function Chart({ points, metric, interval, timezone }: Props) {
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

  const values = points.map((p) => p[metric]);
  const max = niceMax(Math.max(0, ...values));
  const innerW = width - PAD.left - PAD.right;
  const innerH = HEIGHT - PAD.top - PAD.bottom;
  const step = points.length > 1 ? innerW / (points.length - 1) : 0;
  const x = (i: number) => PAD.left + (points.length > 1 ? i * step : innerW / 2);
  const y = (v: number) => PAD.top + innerH - (v / max) * innerH;

  const line = values.map((v, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
  const area = values.length ? `${line}L${x(values.length - 1).toFixed(1)},${y(0)}L${x(0).toFixed(1)},${y(0)}Z` : "";
  const ticks = [0, max / 2, max];
  const labelEvery = Math.max(1, Math.ceil(points.length / Math.max(2, Math.floor(innerW / 90))));

  const onMove = (event: PointerEvent) => {
    const rect = (event.currentTarget as SVGElement).getBoundingClientRect();
    const i = Math.round((event.clientX - rect.left - PAD.left) / (step || 1));
    setHover(points.length ? Math.min(points.length - 1, Math.max(0, i)) : null);
  };

  const hovered = hover !== null ? points[hover] : undefined;

  return (
    <div class="chart" ref={box}>
      <svg width={width} height={HEIGHT} role="img" aria-label={`${metric} over time`} onPointerMove={onMove} onPointerLeave={() => setHover(null)}>
        {ticks.map((t) => (
          <g key={t}>
            <line class="gridline" x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} />
            <text class="axis" x={PAD.left - 8} y={y(t) + 4} text-anchor="end">
              {count(t)}
            </text>
          </g>
        ))}
        {points.map((p, i) =>
          i % labelEvery === 0 ? (
            <text key={p.start} class="axis" x={x(i)} y={HEIGHT - 8} text-anchor={i === 0 ? "start" : "middle"}>
              {bucketLabel(p.start, interval, timezone)}
            </text>
          ) : null,
        )}
        <path class="area" d={area} />
        <path class="line" d={line} />
        {hovered && hover !== null ? (
          <g>
            <line class="cursor" x1={x(hover)} x2={x(hover)} y1={PAD.top} y2={PAD.top + innerH} />
            <circle class="dot" cx={x(hover)} cy={y(hovered[metric])} r={4} />
          </g>
        ) : null}
      </svg>
      {hovered && hover !== null ? (
        <div class="tip" style={{ left: `${Math.min(width - 140, Math.max(0, x(hover) - 70))}px` }}>
          <span class="tip-when">{bucketLabel(hovered.start, interval === "hour" ? "hour" : "day", timezone)}</span>
          <strong>{count(hovered[metric])}</strong> {metric}
        </div>
      ) : null}
    </div>
  );
}
