import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { api, type JourneyAnswer, type View } from "./api.js";
import { count } from "./format.js";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";
import { Sheet } from "./links.js";

const STEPS = [3, 4, 5, 6, 7];

type Pick = { step: number; value: string } | null;

/** Where each page box sits, to draw the flows between them. */
type Boxes = Map<string, { x1: number; x2: number; y: number }>;
const boxKey = (step: number, value: string) => `${step}\u0000${value}`;

/** Journeys: the paths visits take through the site, a column per step with the flows between them. */
export function JourneysSheet({ view, onClose }: { view: View; onClose: () => void }) {
  const [steps, setSteps] = useState(5);
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [through, setThrough] = useState<Pick>(null);
  const [answer, setAnswer] = useState<JourneyAnswer | null>(null);
  const [pages, setPages] = useState<string[]>([]);
  const [error, setError] = useState("");
  const [boxes, setBoxes] = useState<Boxes>(new Map());
  const grid = useRef<HTMLDivElement>(null);

  useEffect(() => {
    void api
      .breakdown(view, "page", 100)
      .then((r) => setPages(r.rows.map((row) => row.value)))
      .catch(() => {});
  }, [view]);
  useEffect(() => {
    setError("");
    void api
      .journeys(view, { steps, start, end, through })
      .then(setAnswer)
      .catch((e: Error) => setError(e.message));
  }, [view, steps, start, end, through]);

  // Measure the boxes once drawn, so the flows can join them.
  useLayoutEffect(() => {
    const root = grid.current;
    if (!root || !answer) return;
    const measure = () => {
      const origin = root.getBoundingClientRect();
      const next: Boxes = new Map();
      for (const el of root.querySelectorAll<HTMLElement>("[data-box]")) {
        const r = el.getBoundingClientRect();
        next.set(el.dataset.box!, { x1: r.left - origin.left, x2: r.right - origin.left, y: r.top - origin.top + r.height / 2 });
      }
      setBoxes(next);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(root);
    return () => observer.disconnect();
  }, [answer]);

  const columns = answer?.columns ?? [];
  const most = Math.max(1, ...(answer?.links ?? []).map((l) => l.visits));
  const label = (value: string) => value || t("journeys.other");
  const pick = (step: number, value: string) => setThrough(through && through.step === step && through.value === value ? null : value ? { step, value } : null);

  return (
    <Sheet title={t("journeys.title")} wide onClose={onClose}>
      <div class="sheet-body journeys">
        <p class="settings-text">{t("journeys.intro")}</p>
        <div class="journey-controls">
          <label class="field-row">
            <span class="field-label">{t("journeys.steps")}</span>
            <select class="value" value={String(steps)} onChange={(e) => setSteps(Number((e.target as HTMLSelectElement).value))}>
              {STEPS.map((n) => (
                <option value={String(n)}>{t("journeys.stepCount", { n })}</option>
              ))}
            </select>
          </label>
          <label class="field-row">
            <span class="field-label">{t("journeys.start")}</span>
            <select class="value" value={start} onChange={(e) => setStart((e.target as HTMLSelectElement).value)}>
              <option value="">{t("journeys.anyPage")}</option>
              {pages.map((p) => (
                <option value={p}>{p}</option>
              ))}
            </select>
          </label>
          <label class="field-row">
            <span class="field-label">{t("journeys.end")}</span>
            <select class="value" value={end} onChange={(e) => setEnd((e.target as HTMLSelectElement).value)}>
              <option value="">{t("journeys.anyPage")}</option>
              {pages.map((p) => (
                <option value={p}>{p}</option>
              ))}
            </select>
          </label>
        </div>
        {through ? (
          <p class="journey-following">
            {t("journeys.following", { page: through.value, step: through.step + 1 })}
            <button type="button" class="copy inline" onClick={() => setThrough(null)}>
              <Icon name="x" />
              {t("common.clearAll")}
            </button>
          </p>
        ) : null}
        {answer?.sampled ? <p class="field-hint">{t("journeys.sampled", { n: count(answer.sampled) })}</p> : null}
        {error ? <p class="settings-error">{error}</p> : null}
        {!answer ? (
          <p class="empty">{t("common.loading")}</p>
        ) : answer.visits === 0 ? (
          <p class="empty">{t("journeys.none")}</p>
        ) : (
          <div class="journey-scroll">
            <div class="journey-grid" ref={grid} style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(150px, 1fr))` }}>
              <svg class="journey-links" aria-hidden="true">
                {answer.links.map((l) => {
                  const a = boxes.get(boxKey(l.step, l.from));
                  const b = boxes.get(boxKey(l.step + 1, l.to));
                  if (!a || !b) return null;
                  const mid = (a.x2 + b.x1) / 2;
                  const lit = through ? (through.step === l.step && through.value === l.from) || (through.step === l.step + 1 && through.value === l.to) : false;
                  return <path class={lit ? "lit" : ""} d={`M${a.x2},${a.y} C${mid},${a.y} ${mid},${b.y} ${b.x1},${b.y}`} style={{ strokeWidth: Math.max(1.5, (l.visits / most) * 16) }} />;
                })}
              </svg>
              {columns.map((column, step) => (
                <div class="journey-column">
                  <p class="journey-step">
                    {t("journeys.step", { n: step + 1 })}
                    <span>{count(column.visits)}</span>
                  </p>
                  {column.items.map((item) => (
                    <button
                      type="button"
                      data-box={boxKey(step, item.value)}
                      class={`journey-page${!item.value ? " other" : ""}${through && through.step === step && through.value === item.value ? " on" : ""}`}
                      title={item.value ? t("journeys.follow", { page: item.value }) : undefined}
                      disabled={!item.value}
                      onClick={() => pick(step, item.value)}
                    >
                      <span class="journey-name">{label(item.value)}</span>
                      <span class="journey-count">
                        {count(item.visits)}
                        <span class="journey-share">{Math.round((item.visits / column.visits) * 100)}%</span>
                      </span>
                    </button>
                  ))}
                  {column.left ? <p class="journey-left">{t("journeys.left", { n: count(column.left) })}</p> : null}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </Sheet>
  );
}
