import { useEffect, useState } from "preact/hooks";
import { api, type View } from "./api.js";
import { count } from "./format.js";
import { t } from "./i18n.js";
import { Sheet } from "./links.js";
import { Empty } from "./empty.js";

type Answer = Awaited<ReturnType<typeof api.eventProps>>;

/** One event's properties: each name it was sent with, and the values that name took. */
export function EventProps({ view, event, onClose }: { view: View; event: string; onClose: () => void }) {
  const [key, setKey] = useState<string | null>(null);
  const [answer, setAnswer] = useState<Answer | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    api
      .eventProps(view, event, key)
      .then((r) => live && setAnswer(r))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [event, key, view]);
  const rows = answer?.rows ?? [];
  const top = Math.max(1, ...rows.map((r) => r.events));
  return (
    <Sheet title={event} sub={t("props.title")} wide onClose={onClose}>
      <div class="sheet-body props-body">
        {answer && answer.keys.length > 1 ? (
          <div class="ops props-keys" role="radiogroup" aria-label={t("props.title")}>
            {answer.keys.map((k) => (
              <button type="button" role="radio" aria-checked={answer.key === k.key} class={answer.key === k.key ? "op on" : "op"} onClick={() => setKey(k.key)}>
                {k.key}
              </button>
            ))}
          </div>
        ) : null}
        {error ? <p class="settings-error">{error}</p> : null}
        {answer && answer.keys.length === 0 ? <Empty icon="list" title={t("props.emptyTitle")} hint={t("props.none")} /> : null}
        {answer && answer.key ? (
          <>
            <div class="table">
            <div class="cols">
              <span>{answer.key}</span>
              <span class="extra">{t("column.visitors")}</span>
              <span class="num-head">{t("column.events")}</span>
            </div>
            <ol class="rows">
              {rows.map((r) => (
                <li>
                  <span class="bar" style={{ width: `${(r.events / top) * 100}%` }} />
                  <span class="name" title={r.value}>
                    <span class="name-text">{r.value}</span>
                  </span>
                  <span class="extra">{count(r.visitors)}</span>
                  <span class="num">{count(r.events)}</span>
                </li>
              ))}
            </ol>
            </div>
          </>
        ) : null}
        {!answer && !error ? <p class="empty">{t("common.loading")}</p> : null}
      </div>
    </Sheet>
  );
}
