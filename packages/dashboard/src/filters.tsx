import { useEffect, useRef, useState } from "preact/hooks";
import { api, type Filter, type Row, type View } from "./api.js";
import { count } from "./format.js";
import { t, tn, type Key } from "./i18n.js";
import { label } from "./panel.js";
import { Icon } from "./icons.js";

export const FIELDS: Array<{ group: Key; fields: string[] }> = [
  { group: "group.pages", fields: ["page", "entry", "exit", "hostname"] },
  { group: "group.sources", fields: ["channel", "source", "referrer", "utm_campaign", "utm_source", "utm_medium", "utm_content", "utm_term"] },
  { group: "group.location", fields: ["country", "region", "city"] },
  { group: "group.device", fields: ["device", "browser", "browser_version", "os", "os_version", "screen", "language"] },
  { group: "group.behaviour", fields: ["event"] },
];

export const fieldName = (dimension: string): string => t(`field.${dimension}` as Key);

const OPS: Filter["op"][] = ["is", "not", "contains"];
export const opName = (op: Filter["op"]): string => t(`filter.${op}`);

interface Draft extends Filter {
  id: number;
}

let nextId = 1;

function Clause({ draft, view, first, onChange, onRemove }: {
  draft: Draft;
  view: View;
  first: boolean;
  onChange: (d: Draft) => void;
  onRemove: () => void;
}) {
  const [suggestions, setSuggestions] = useState<Row[]>([]);
  useEffect(() => {
    let live = true;
    // Suggest from the current view, minus any filter on this same field.
    const scoped = { ...view, filters: view.filters.filter((f) => f.dimension !== draft.dimension) };
    api
      .breakdown(scoped, draft.dimension, 12)
      .then((r) => live && setSuggestions(r.rows))
      .catch(() => live && setSuggestions([]));
    return () => {
      live = false;
    };
  }, [draft.dimension, view]);

  return (
    <div class="clause">
      <span class="joiner">{t(first ? "filter.where" : "filter.and")}</span>
      <div class="clause-body">
        <div class="clause-line">
          <select
            class="value"
            aria-label={t("filter.field")}
            value={draft.dimension}
            onChange={(e) => onChange({ ...draft, dimension: (e.target as HTMLSelectElement).value, value: "" })}
          >
            {FIELDS.map((g) => (
              <optgroup label={t(g.group)}>
                {g.fields.map((value) => (
                  <option value={value}>{fieldName(value)}</option>
                ))}
              </optgroup>
            ))}
          </select>
          <div class="ops" role="radiogroup" aria-label={t("filter.match")}>
            {OPS.map((op) => (
              <button type="button" role="radio" aria-checked={draft.op === op} class={draft.op === op ? "op on" : "op"} onClick={() => onChange({ ...draft, op })}>
                {opName(op)}
              </button>
            ))}
          </div>
          <button type="button" class="remove" aria-label={t("filter.removeCondition")} onClick={onRemove}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </div>
        <input
          class="value"
          type="text"
          aria-label={t("filter.value")}
          placeholder={t(draft.op === "contains" ? "filter.placeholderContains" : "filter.placeholder")}
          value={draft.value}
          onInput={(e) => onChange({ ...draft, value: (e.target as HTMLInputElement).value })}
        />
        {suggestions.length ? (
          <div class="suggestions">
            {suggestions.map((s) => (
              <button type="button" class={s.value === draft.value ? "suggestion on" : "suggestion"} onClick={() => onChange({ ...draft, value: s.value })}>
                {label(draft.dimension, s.value)}
                <span>{count(Number(s.visitors || s.events || 0))}</span>
              </button>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}

export function FilterDrawer({ view, onApply, onClose }: { view: View; onApply: (filters: Filter[]) => void; onClose: () => void }) {
  const [drafts, setDrafts] = useState<Draft[]>(() =>
    view.filters.length ? view.filters.map((f) => ({ ...f, id: nextId++ })) : [{ dimension: "page", op: "is", value: "", id: nextId++ }],
  );
  const panel = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    panel.current?.querySelector<HTMLElement>("select, input")?.focus();
    document.body.classList.add("locked");
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);

  const ready = drafts.filter((d) => d.value.trim() !== "");

  return (
    <div class="scrim" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class="drawer" role="dialog" aria-modal="true" aria-labelledby="filter-title" ref={panel}>
        <header class="drawer-head">
          <h2 id="filter-title">{t("filter.title")}</h2>
          <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </header>
        <div class="drawer-body">
          {drafts.map((d, i) => (
            <Clause
              draft={d}
              view={view}
              first={i === 0}
              onChange={(next) => setDrafts(drafts.map((x) => (x.id === d.id ? next : x)))}
              onRemove={() => setDrafts(drafts.filter((x) => x.id !== d.id))}
            />
          ))}
          <button type="button" class="add" onClick={() => setDrafts([...drafts, { dimension: "country", op: "is", value: "", id: nextId++ }])}>
            <Icon name="plus" />
            {t("filter.add").replace(/^\+\s*/, "")}
          </button>
          <p class="drawer-note">{t("filter.note")}</p>
        </div>
        <footer class="drawer-foot">
          <button type="button" class="ghost" onClick={() => setDrafts([])}>
            <Icon name="x" />
            {t("common.clearAll")}
          </button>
          <span class="grow" />
          <button type="button" class="ghost" onClick={onClose}>
            {t("common.cancel")}
          </button>
          <button
            type="button"
            class="solid"
            onClick={() => {
              onApply(ready.map(({ dimension, op, value }) => ({ dimension, op, value: value.trim() })));
              onClose();
            }}
          >
            <Icon name="check" />
            {ready.length ? tn("filter.apply", ready.length) : t("filter.everything")}
          </button>
        </footer>
      </div>
    </div>
  );
}
