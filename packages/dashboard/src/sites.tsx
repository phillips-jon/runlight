import { useState } from "preact/hooks";
import { api, type Site } from "./api.js";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";

/** The browser's own timezone, a good first guess for a new site's. */
function localZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

/** Adds a site to an install whose sites are managed in the dashboard (the standalone server). */
export function AddSiteForm({ onAdded, onCancel }: { onAdded: (site: Site) => void; onCancel?: () => void }) {
  const [name, setName] = useState("");
  const [hostnames, setHostnames] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const submit = (e: Event) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    api
      .addSite({ name: name.trim(), hostnames, timezone: localZone() })
      .then((r) => onAdded(r.site))
      .catch((err: Error) => {
        setError(err.message);
        setBusy(false);
      });
  };
  return (
    <form class="sheet-body link-form" onSubmit={submit}>
      <label class="field-row">
        <span class="field-label">{t("sites.domains")}</span>
        <input class="value" type="text" required autoFocus placeholder="example.com" value={hostnames} onInput={(e) => setHostnames((e.target as HTMLInputElement).value)} />
        <span class="field-hint">{t("sites.domainsHint")}</span>
      </label>
      <label class="field-row">
        <span class="field-label">{t("sites.name")}</span>
        <input class="value" type="text" maxLength={80} placeholder={t("sites.namePlaceholder")} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        <span class="field-hint">{t("sites.timezoneHint", { zone: localZone().replace(/_/g, " ") })}</span>
      </label>
      <div class="settings-actions">
        {error ? <span class="settings-error">{error}</span> : null}
        {onCancel ? (
          <button type="button" class="ghost" onClick={onCancel}>
            {t("common.cancel")}
          </button>
        ) : null}
        <button type="submit" class="solid" disabled={busy || !hostnames.trim()}>
          <Icon name="plus" />
          {t("sites.add")}
        </button>
      </div>
    </form>
  );
}

/** The whole page, for a standalone server with no sites yet. */
export function FirstSite({ onAdded }: { onAdded: (site: Site) => void }) {
  return (
    <main class="first-site">
      <div class="first-site-card">
        <h1>{t("sites.firstTitle")}</h1>
        <p class="settings-text">{t("sites.firstLead")}</p>
        <AddSiteForm onAdded={onAdded} />
      </div>
    </main>
  );
}
