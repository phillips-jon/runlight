import { useEffect, useState } from "preact/hooks";
import { api, type Funnel, type FunnelStep, type Site, type View } from "./api.js";
import { count, percent } from "./format.js";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";
import { DeleteButton } from "./links.js";

const stepText = (s: FunnelStep) => t(s.kind === "page" ? "funnels.stepPage" : "funnels.stepEvent", { match: s.match });

/** A funnel's steps as bars, each with the visits that got that far and how many went on from the step before. */
export function FunnelBars({ funnel }: { funnel: Funnel }) {
  const first = Math.max(1, funnel.steps[0]?.visits ?? 0);
  return (
    <ol class="funnel">
      {funnel.steps.map((step, i) => {
        const visits = step.visits ?? 0;
        const before = i === 0 ? visits : (funnel.steps[i - 1]!.visits ?? 0);
        return (
          <li>
            <div class="funnel-label">
              <span class="funnel-step">{i + 1}</span>
              <span class="name-text">{stepText(step)}</span>
              <span class="num">{count(visits)}</span>
            </div>
            <div class="funnel-track">
              <span class="funnel-fill" style={{ width: `${(visits / first) * 100}%` }} />
            </div>
            {i > 0 ? <span class="funnel-rate">{t("funnels.wentOn", { pct: before ? percent(visits / before) : percent(0) })}</span> : null}
          </li>
        );
      })}
    </ol>
  );
}

/** Settings, Goals, Funnels: name the steps a visit should take, in order. */
export function Funnels({ site, view }: { site: Site; view: View }) {
  const [funnels, setFunnels] = useState<Funnel[] | null>(null);
  const [editing, setEditing] = useState<Funnel | "new" | null>(null);
  const [error, setError] = useState("");
  const load = () =>
    api
      .funnels({ ...view, site: site.id })
      .then((r) => setFunnels(r.funnels))
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, [site.id]);
  if (editing) {
    return (
      <FunnelForm
        site={site}
        funnel={editing === "new" ? null : editing}
        onDone={() => {
          setEditing(null);
          void load();
        }}
      />
    );
  }
  return (
    <div class="settings-group">
      <p class="settings-text">
        <strong>{t("funnels.title")}</strong>
      </p>
      <p class="settings-text">{t("funnels.intro")}</p>
      {funnels && funnels.length ? (
        <ul class="domain-list goal-list">
          {funnels.map((f) => (
            <li>
              <div class="domain-main">
                <span class="share-name">{f.name}</span>
                <span class="share-meta">{f.steps.map(stepText).join(" → ")}</span>
              </div>
              <div class="domain-actions">
                <button type="button" class="copy inline" onClick={() => setEditing(f)}>
                  <Icon name="edit" />
                  {t("goals.edit")}
                </button>
                <DeleteButton name={f.name} onDelete={() => void api.deleteFunnel(site.id, f.id).then(load)} />
              </div>
            </li>
          ))}
        </ul>
      ) : funnels ? (
        <p class="field-hint">{t("funnels.none")}</p>
      ) : null}
      {error ? <p class="settings-error">{error}</p> : null}
      <div class="settings-actions start">
        <button type="button" class="ghost" onClick={() => setEditing("new")}>
          <Icon name="plus" />
          {t("funnels.add")}
        </button>
      </div>
    </div>
  );
}

function FunnelForm({ site, funnel, onDone }: { site: Site; funnel: Funnel | null; onDone: () => void }) {
  const [name, setName] = useState(funnel?.name ?? "");
  const [steps, setSteps] = useState<FunnelStep[]>(
    funnel?.steps.map((s) => ({ kind: s.kind, match: s.match })) ?? [
      { kind: "page", match: "" },
      { kind: "page", match: "" },
    ],
  );
  const [error, setError] = useState("");
  const set = (i: number, patch: Partial<FunnelStep>) => setSteps(steps.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  const save = (e: Event) => {
    e.preventDefault();
    setError("");
    api
      .saveFunnel(site.id, funnel?.id ?? null, { name: name.trim(), steps })
      .then(onDone)
      .catch((err: Error) => setError(err.message));
  };
  return (
    <form class="settings-group" onSubmit={save}>
      <label class="field-row">
        <span class="field-label">{t("funnels.name")}</span>
        <input class="value" type="text" maxLength={80} required placeholder={t("funnels.namePlaceholder")} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
      </label>
      <div class="field-row">
        <span class="field-label">{t("funnels.steps")}</span>
        <ol class="funnel-steps">
          {steps.map((s, i) => (
            <li>
              <span class="funnel-step">{i + 1}</span>
              <select class="value" value={s.kind} aria-label={t("funnels.kind")} onChange={(e) => set(i, { kind: (e.target as HTMLSelectElement).value as FunnelStep["kind"] })}>
                <option value="page">{t("funnels.page")}</option>
                <option value="event">{t("funnels.event")}</option>
              </select>
              <input
                class="value"
                type="text"
                required
                placeholder={s.kind === "page" ? "/pricing" : "Signup"}
                value={s.match}
                onInput={(e) => set(i, { match: (e.target as HTMLInputElement).value })}
              />
              <button type="button" class="remove" aria-label={t("funnels.removeStep")} disabled={steps.length <= 2} onClick={() => setSteps(steps.filter((_, j) => j !== i))}>
                <svg viewBox="0 0 16 16" aria-hidden="true">
                  <path d="M4 4l8 8M12 4l-8 8" />
                </svg>
              </button>
            </li>
          ))}
        </ol>
        <span class="field-hint">{t("funnels.stepsHint")}</span>
        {steps.length < 8 ? (
          <div>
            <button type="button" class="ghost" onClick={() => setSteps([...steps, { kind: "page", match: "" }])}>
              <Icon name="plus" />
              {t("funnels.addStep")}
            </button>
          </div>
        ) : null}
      </div>
      <div class="settings-actions">
        {error ? <span class="settings-error">{error}</span> : null}
        <button type="button" class="ghost" onClick={onDone}>
          {t("common.cancel")}
        </button>
        <button type="submit" class="solid">
          <Icon name="save" />
          {t(funnel ? "funnels.save" : "funnels.create")}
        </button>
      </div>
    </form>
  );
}
