import { useEffect, useRef, useState } from "preact/hooks";
import { api, type Row, type View } from "./api.js";
import { count, countryName, flag } from "./format.js";

interface World {
  w: number;
  h: number;
  shapes: Array<{ id: string; d: string }>;
}

const worldUrl = document.getElementById("app")?.dataset.world ?? "";
let loading: Promise<World> | null = null;

/** The shapes are fetched once, the first time any map opens. */
function loadWorld(): Promise<World> {
  loading ??= fetch(worldUrl).then((r) => {
    if (!r.ok) throw new Error("Could not load the map");
    return r.json() as Promise<World>;
  });
  loading.catch(() => (loading = null));
  return loading;
}

const STEPS = 6;

interface Props {
  view: View;
  onFilter: (dimension: string, value: string) => void;
  large?: boolean;
}

export function WorldMap({ view, onFilter, large }: Props) {
  const [world, setWorld] = useState<World | null>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState("");
  const [hover, setHover] = useState<{ id: string; x: number; y: number } | null>(null);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    loadWorld().then(setWorld).catch((e: Error) => setError(e.message));
  }, []);

  useEffect(() => {
    let live = true;
    api
      .breakdown(view, "country", 300)
      .then((r) => live && setRows(r.rows))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [view]);

  const visitors = new Map(rows.map((r) => [r.value, r.visitors]));
  const max = Math.max(0, ...rows.map((r) => r.visitors));
  // Square root, so a handful of big countries do not wash out the rest.
  const step = (n: number) => (n <= 0 || max === 0 ? 0 : Math.max(1, Math.ceil(Math.sqrt(n / max) * STEPS)));

  if (error) return <p class="empty">{error}</p>;
  if (!world) return <div class={large ? "map large" : "map"} />;

  const hovered = hover ? { id: hover.id, n: visitors.get(hover.id) ?? 0 } : null;

  return (
    <div class={large ? "map large" : "map"} ref={box}>
      <svg
        viewBox={`0 0 ${world.w} ${world.h}`}
        role="img"
        aria-label={`Visitors by country: ${rows
          .slice(0, 5)
          .map((r) => `${countryName(r.value)} ${count(r.visitors)}`)
          .join(", ")}`}
        onPointerLeave={() => setHover(null)}
      >
        {world.shapes.map((s) => {
          const n = visitors.get(s.id) ?? 0;
          return (
            <path
              d={s.d}
              class={`land q${step(n)}${hover?.id === s.id ? " hot" : ""}${s.id && n ? " has" : ""}`}
              onPointerMove={(e) => {
                const rect = box.current?.getBoundingClientRect();
                if (rect && s.id) setHover({ id: s.id, x: e.clientX - rect.left, y: e.clientY - rect.top });
              }}
              onClick={() => s.id && n && onFilter("country", s.id)}
            />
          );
        })}
      </svg>
      {hovered && hovered.id ? (
        <div class="map-tip" style={{ left: `${hover!.x}px`, top: `${hover!.y}px` }}>
          <strong>
            {flag(hovered.id)} {countryName(hovered.id)}
          </strong>
          <span>{hovered.n ? `${count(hovered.n)} ${hovered.n === 1 ? "visitor" : "visitors"}` : "No visitors"}</span>
        </div>
      ) : null}
      <div class="map-scale" aria-hidden="true">
        <span>Fewer</span>
        {Array.from({ length: STEPS }, (_, i) => (
          <span class={`cell q${i + 1}`} />
        ))}
        <span>More</span>
      </div>
    </div>
  );
}

/** The map large, over the page, with the country list beside it. */
export function MapOverlay({ view, onFilter, onClose }: Props & { onClose: () => void }) {
  const [rows, setRows] = useState<Row[]>([]);
  useEffect(() => {
    api.breakdown(view, "country", 30).then((r) => setRows(r.rows)).catch(() => setRows([]));
  }, [view]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.classList.add("locked");
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);
  const total = rows.reduce((sum, r) => sum + r.visitors, 0);
  return (
    <div class="scrim center" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class="map-sheet" role="dialog" aria-modal="true" aria-label="Visitors around the world">
        <header class="drawer-head">
          <h2>Around the world</h2>
          <button type="button" class="remove" aria-label="Close" onClick={onClose}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </header>
        <div class="map-sheet-body">
          <WorldMap
            view={view}
            large
            onFilter={(d, v) => {
              onFilter(d, v);
              onClose();
            }}
          />
          <ol class="map-list">
            {rows.map((r) => (
              <li>
                <button
                  type="button"
                  onClick={() => {
                    onFilter("country", r.value);
                    onClose();
                  }}
                >
                  <span class="map-list-name">
                    {flag(r.value)} {countryName(r.value)}
                  </span>
                  <span class="map-list-share">{total ? `${Math.round((r.visitors / total) * 100)}%` : ""}</span>
                  <b>{count(r.visitors)}</b>
                </button>
              </li>
            ))}
          </ol>
        </div>
      </div>
    </div>
  );
}
