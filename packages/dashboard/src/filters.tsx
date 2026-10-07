import { useEffect, useRef, useState } from "preact/hooks";
import { api, type Filter, type Row, type View } from "./api.js";
import { count } from "./format.js";
import { label } from "./panel.js";

export const FIELDS: Array<{ group: string; fields: Array<[string, string]> }> = [
  { group: "Pages", fields: [["page", "Page"], ["entry", "Entry page"], ["exit", "Exit page"], ["hostname", "Hostname"]] },
  {
    group: "Sources",
    fields: [["channel", "Channel"], ["source", "Source"], ["referrer", "Referrer"], ["utm_campaign", "Campaign"], ["utm_source", "UTM source"], ["utm_medium", "UTM medium"], ["utm_content", "UTM content"], ["utm_term", "UTM term"]],
  },
  { group: "Location", fields: [["country", "Country"], ["region", "Region"], ["city", "City"]] },
  {
    group: "Device",
    fields: [["device", "Device"], ["browser", "Browser"], ["browser_version", "Browser version"], ["os", "OS"], ["os_version", "OS version"], ["screen", "Screen"], ["language", "Language"]],
  },
  { group: "Behaviour", fields: [["event", "Event"]] },
];

export const FIELD_NAMES: Record<string, string> = Object.fromEntries(FIELDS.flatMap((g) => g.fields));

const OPS: Array<[Filter["op"], string]> = [
  ["is", "is"],
  ["not", "is not"],
  ["contains", "contains"],
];

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
      <span class="joiner">{first ? "where" : "and"}</span>
      <div class="clause-body">
        <div class="clause-line">
          <select
            class="field"
            aria-label="Field"
            value={draft.dimension}
            onChange={(e) => onChange({ ...draft, dimension: (e.target as HTMLSelectElement).value, value: "" })}
          >
            {FIELDS.map((g) => (
              <optgroup label={g.group}>
                {g.fields.map(([value, text]) => (
                  <option value={value}>{text}</option>
                ))}
              </optgroup>
            ))}
          </select>
          <div class="ops" role="radiogroup" aria-label="Match">
            {OPS.map(([op, text]) => (
              <button type="button" role="radio" aria-checked={draft.op === op} class={draft.op === op ? "op on" : "op"} onClick={() => onChange({ ...draft, op })}>
                {text}
              </button>
            ))}
          </div>
          <button type="button" class="remove" aria-label="Remove this condition" onClick={onRemove}>
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" />
            </svg>
          </button>
        </div>
        <input
          class="value"
          type="text"
          aria-label="Value"
          placeholder={draft.op === "contains" ? "Any part of the value" : "Type a value or pick one below"}
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
          <h2 id="filter-title">Show visits</h2>
          <button type="button" class="remove" aria-label="Close" onClick={onClose}>
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
            + Add a condition
          </button>
          <p class="drawer-note">Every condition has to hold. Click any row on the dashboard to add one without opening this.</p>
        </div>
        <footer class="drawer-foot">
          <button type="button" class="ghost" onClick={() => setDrafts([])}>
            Clear all
          </button>
          <span class="grow" />
          <button type="button" class="ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            class="solid"
            onClick={() => {
              onApply(ready.map(({ dimension, op, value }) => ({ dimension, op, value: value.trim() })));
              onClose();
            }}
          >
            {ready.length ? `Apply ${ready.length} ${ready.length === 1 ? "condition" : "conditions"}` : "Show everything"}
          </button>
        </footer>
      </div>
    </div>
  );
}
