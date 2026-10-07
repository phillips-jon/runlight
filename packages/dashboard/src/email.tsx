import { useEffect, useState } from "preact/hooks";
import { api, base, type MailState, type Report, type Site } from "./api.js";
import { LANGUAGES, currentLocale, t, type Key } from "./i18n.js";
import { Icon } from "./icons.js";
import { DeleteButton } from "./links.js";

const fieldLabel = (name: string, fallback: string) => {
  const key = `mail.field.${name}` as Key;
  const text = t(key);
  return text === key ? fallback : text;
};

/** The install-wide mail service: shown, changed, tested. */
function MailService({ onChange }: { onChange: (ready: boolean) => void }) {
  const [state, setState] = useState<MailState | null>(null);
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [testTo, setTestTo] = useState("");
  const [tested, setTested] = useState("");

  const load = () =>
    api
      .mail()
      .then((m) => {
        setState(m);
        onChange(Boolean(m.source));
        setForm({ service: m.service || "ses", from: m.from, fromName: m.fromName, ...m.fields });
      })
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, []);
  if (!state) return error ? <p class="settings-error">{error}</p> : null;

  const service = state.services.find((x) => x.id === state.service);
  const chosen = state.services.find((x) => x.id === form.service) ?? state.services[0]!;

  const save = (e: Event) => {
    e.preventDefault();
    setError("");
    setBusy(true);
    api
      .saveMail(form)
      .then(() => {
        setEditing(false);
        return load();
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };

  const test = (e: Event) => {
    e.preventDefault();
    setError("");
    setTested("");
    setBusy(true);
    api
      .testMail(testTo.trim(), currentLocale())
      .then(() => setTested(t("mail.testSent", { to: testTo.trim() })))
      .catch((err: Error) => setError(err.message))
      .finally(() => setBusy(false));
  };

  // Nothing set up yet shows the form straight away.
  if (editing || !state.source) {
    return (
      <form class="goal-form" onSubmit={save}>
        {!state.encrypted ? <p class="settings-note">{t("mail.notEncrypted")}</p> : null}
        <label class="field-row">
          <span class="field-label">{t("mail.service")}</span>
          <select class="value" value={form.service} onChange={(e) => setForm({ ...form, service: (e.target as HTMLSelectElement).value })}>
            {state.services.map((x) => (
              <option value={x.id}>{x.name}</option>
            ))}
          </select>
        </label>
        {chosen.fields.map((f) => (
          <label class="field-row">
            <span class="field-label">
              {fieldLabel(f.name, f.label)}
              {f.optional ? <span class="optional"> {t("mail.optional")}</span> : null}
            </span>
            {f.options ? (
              <select class="value" value={form[f.name] || f.options[0]} onChange={(e) => setForm({ ...form, [f.name]: (e.target as HTMLSelectElement).value })}>
                {f.options.map((o) => (
                  <option value={o}>{o}</option>
                ))}
              </select>
            ) : (
              <input
                class="value"
                type={(f.secret ? "password" : "text") as "text"}
                autoComplete="off"
                spellcheck={false}
                placeholder={f.secret && state.saved.includes(f.name) && state.service === chosen.id ? t("mail.keepSaved") : (f.placeholder ?? "")}
                value={form[f.name] ?? ""}
                onInput={(e) => setForm({ ...form, [f.name]: (e.target as HTMLInputElement).value })}
              />
            )}
          </label>
        ))}
        <div class="value-row">
          <label class="field-row">
            <span class="field-label">{t("mail.from")}</span>
            <input class="value" type="email" placeholder="reports@example.com" value={form.from ?? ""} onInput={(e) => setForm({ ...form, from: (e.target as HTMLInputElement).value })} />
          </label>
          <label class="field-row">
            <span class="field-label">
              {t("mail.fromName")}
              <span class="optional"> {t("mail.optional")}</span>
            </span>
            <input class="value" type="text" placeholder="Runlight" value={form.fromName ?? ""} onInput={(e) => setForm({ ...form, fromName: (e.target as HTMLInputElement).value })} />
          </label>
        </div>
        <p class="field-hint">{t("mail.fromHint")}</p>
        {error ? <p class="settings-error">{error}</p> : null}
        <div class="settings-actions start">
          <button type="submit" class="solid" disabled={busy}>
            <Icon name="check" />
            {t("mail.save")}
          </button>
          {state.source ? (
            <button type="button" class="ghost" onClick={() => setEditing(false)}>
              {t("goals.cancel")}
            </button>
          ) : null}
        </div>
      </form>
    );
  }

  return (
    <div class="settings-group">
      <ul class="domain-list">
        <li>
          <div class="domain-main">
            <span class="share-name">{service?.name ?? state.service}</span>
            <span class="share-meta">{t(state.source === "code" ? "mail.fromCode" : "mail.fromLine", { from: state.fromName ? `${state.fromName} <${state.from}>` : state.from })}</span>
          </div>
          {state.source === "dashboard" ? (
            <div class="domain-actions">
              <button type="button" class="copy inline" onClick={() => setEditing(true)}>
                <Icon name="edit" />
                {t("mail.change")}
              </button>
              <DeleteButton name={service?.name ?? ""} onDelete={() => void api.removeMail().then(load)} />
            </div>
          ) : null}
        </li>
      </ul>
      <form class="domain-add" onSubmit={test}>
        <input class="value" type="email" placeholder={t("mail.testTo")} value={testTo} onInput={(e) => setTestTo((e.target as HTMLInputElement).value)} />
        <button type="submit" class="solid" disabled={busy || !testTo.trim()}>
          <Icon name="send" />
          {t("mail.test")}
        </button>
      </form>
      {tested ? (
        <p class="settings-ok-text">
          <Icon name="check" />
          {tested}
        </p>
      ) : null}
      {error ? <p class="settings-error">{error}</p> : null}
    </div>
  );
}

function ago(ms: number | null): string {
  if (!ms) return t("reports.never");
  return new Intl.DateTimeFormat(currentLocale(), { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(ms);
}

/** Settings, Email reports: the mail service, then who gets this site's reports. */
export function EmailReports({ site }: { site: Site }) {
  const [ready, setReady] = useState(false);
  const [reports, setReports] = useState<Report[] | null>(null);
  const [email, setEmail] = useState("");
  const [frequency, setFrequency] = useState<"weekly" | "monthly">("weekly");
  const [lang, setLang] = useState(currentLocale());
  const [error, setError] = useState("");
  const [sent, setSent] = useState("");
  const [sending, setSending] = useState("");
  const load = () =>
    api
      .reports(site.id)
      .then((r) => setReports(r.reports))
      .catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, [site.id]);

  const add = (e: Event) => {
    e.preventDefault();
    setError("");
    api
      .addReport(site.id, { email: email.trim(), frequency, lang, origin: `${location.origin}${base}` })
      .then(() => {
        setEmail("");
        return load();
      })
      .catch((err: Error) => setError(err.message));
  };
  const sample = (r: Report) => {
    setError("");
    setSent("");
    setSending(r.id);
    api
      .sendReport(site.id, r.id)
      .then(() => setSent(t("reports.sampleSent", { to: r.email })))
      .catch((err: Error) => setError(err.message))
      .finally(() => setSending(""));
  };
  const langName = (code: string) => LANGUAGES.find(([c]) => c === code)?.[1] ?? code;

  return (
    <>
      <div class="settings-group">
        <div class="field-row">
          <span class="field-label">{t("mail.title")}</span>
          <span class="settings-text">{t("mail.intro")}</span>
        </div>
        <MailService onChange={setReady} />
      </div>
      <div class="settings-group">
        <div class="field-row">
          <span class="field-label">{t("reports.title")}</span>
          <span class="settings-text">{t("reports.intro", { site: site.name })}</span>
        </div>
        {reports && reports.length ? (
          <ul class="domain-list">
            {reports.map((r) => (
              <li>
                <div class="domain-main">
                  <span class="share-name">{r.email}</span>
                  <span class="share-meta">
                    {t(r.frequency === "monthly" ? "reports.monthly" : "reports.weekly")} · {langName(r.lang)} · {t("reports.lastSent", { when: ago(r.lastSentAt) })}
                  </span>
                </div>
                <div class="domain-actions">
                  <button type="button" class="copy inline" disabled={!ready || sending === r.id} onClick={() => sample(r)}>
                    <Icon name="send" />
                    {t("reports.sample")}
                  </button>
                  <DeleteButton name={r.email} onDelete={() => void api.deleteReport(site.id, r.id).then(load)} />
                </div>
              </li>
            ))}
          </ul>
        ) : reports ? (
          <p class="field-hint">{t("reports.none")}</p>
        ) : null}
        {sent ? (
          <p class="settings-ok-text">
            <Icon name="check" />
            {sent}
          </p>
        ) : null}
        <form class="report-add" onSubmit={add}>
          <input class="value" type="email" placeholder={t("reports.emailPlaceholder")} value={email} onInput={(e) => setEmail((e.target as HTMLInputElement).value)} />
          <select class="value" value={frequency} aria-label={t("reports.frequency")} onChange={(e) => setFrequency((e.target as HTMLSelectElement).value as "weekly" | "monthly")}>
            <option value="weekly">{t("reports.weekly")}</option>
            <option value="monthly">{t("reports.monthly")}</option>
          </select>
          <select class="value" value={lang} aria-label={t("reports.language")} onChange={(e) => setLang((e.target as HTMLSelectElement).value)}>
            {LANGUAGES.map(([code, name]) => (
              <option value={code}>{name}</option>
            ))}
          </select>
          <button type="submit" class="solid" disabled={!email.trim()}>
            <Icon name="plus" />
            {t("reports.add")}
          </button>
        </form>
        {error ? <p class="settings-error">{error}</p> : null}
        <p class="field-hint">{t(ready ? "reports.when" : "reports.needsMail")}</p>
      </div>
    </>
  );
}
