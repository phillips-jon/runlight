import { useEffect, useState } from "preact/hooks";
import { api, type Site, type Stats, type View } from "./api.js";
import { count, duration, percent } from "./format.js";
import { Sheet } from "./links.js";
import { t } from "./i18n.js";
import { Icon } from "./icons.js";
import { Chevron, useFlyout } from "./picker.js";

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
  const [mode, setMode] = useState<"here" | "connect">("here");
  const [name, setName] = useState("");
  const [hostnames, setHostnames] = useState("");
  const [remoteUrl, setRemoteUrl] = useState("");
  const [token, setToken] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const submit = (e: Event) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    const input = mode === "here" ? { name: name.trim(), hostnames, timezone: localZone() } : { name: name.trim(), remote: { url: remoteUrl.trim(), token: token.trim() } };
    api
      .addSite(input)
      .then((r) => onAdded(r.site))
      .catch((err: Error) => {
        setError(err.message);
        setBusy(false);
      });
  };
  return (
    <form class="sheet-body link-form" onSubmit={submit}>
      <div class="ops add-mode" role="radiogroup" aria-label={t("sites.addTitle")}>
        {(["here", "connect"] as const).map((m) => (
          <button type="button" role="radio" aria-checked={mode === m} class={mode === m ? "op on" : "op"} onClick={() => setMode(m)}>
            {t(m === "here" ? "sites.modeHere" : "sites.modeConnect")}
          </button>
        ))}
      </div>
      {mode === "here" ? (
        <label class="field-row">
          <span class="field-label">{t("sites.domains")}</span>
          <input class="value" type="text" required autoFocus placeholder="example.com" value={hostnames} onInput={(e) => setHostnames((e.target as HTMLInputElement).value)} />
          <span class="field-hint">{t("sites.domainsHint")}</span>
        </label>
      ) : (
        <>
          <p class="settings-text">{t("sites.connectIntro")}</p>
          <label class="field-row">
            <span class="field-label">{t("sites.connectUrl")}</span>
            <input class="value" type="url" required placeholder="https://example.com/runlight" value={remoteUrl} onInput={(e) => setRemoteUrl((e.target as HTMLInputElement).value)} />
          </label>
          <label class="field-row">
            <span class="field-label">{t("sites.connectToken")}</span>
            <input class="value" type="password" required autoComplete="off" placeholder="rl_..." value={token} onInput={(e) => setToken((e.target as HTMLInputElement).value)} />
            <span class="field-hint">{t("sites.connectTokenHint")}</span>
          </label>
        </>
      )}
      <label class="field-row">
        <span class="field-label">{t("sites.name")}</span>
        <input class="value" type="text" maxLength={80} placeholder={t("sites.namePlaceholder")} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        {mode === "here" ? <span class="field-hint">{t("sites.timezoneHint", { zone: localZone().replace(/_/g, " ") })}</span> : null}
      </label>
      <div class="settings-actions">
        {error ? <span class="settings-error">{error}</span> : null}
        {onCancel ? (
          <button type="button" class="ghost" onClick={onCancel}>
            {t("common.cancel")}
          </button>
        ) : null}
        <button type="submit" class="solid" disabled={busy || (mode === "here" ? !hostnames.trim() : !remoteUrl.trim() || !token.trim())}>
          <Icon name="plus" />
          {t(mode === "here" ? "sites.add" : "sites.connect")}
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

/** The site name as a menu: every site, then "Add a site" when sites are managed in the dashboard. */
export function SiteMenu({ sites, current, canAdd, onPick, onAdd, onAll }: { sites: Site[]; current: Site | undefined; canAdd: boolean; onPick: (id: string) => void; onAdd: () => void; onAll?: () => void }) {
  const { open, setOpen, root } = useFlyout();
  return (
    <div class="site-menu" ref={root}>
      <button type="button" class="site-button" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span class="site-button-name">{current?.name ?? "Runlight"}</span>
        <Chevron />
      </button>
      {open ? (
        <div class="site-flyout" role="menu" aria-label={t("app.site")}>
          {sites.map((s) => (
            <button
              type="button"
              role="menuitemradio"
              aria-checked={s.id === current?.id}
              class={s.id === current?.id ? "site-option on" : "site-option"}
              onClick={() => {
                setOpen(false);
                if (s.id !== current?.id) onPick(s.id);
              }}
            >
              <span class="site-option-text">
                <span class="site-option-name">{s.name}</span>
                {s.hostnames[0] && s.hostnames[0] !== s.name ? <span class="site-option-host">{s.hostnames[0]}</span> : null}
              </span>
              {s.id === current?.id ? <Icon name="check" /> : null}
            </button>
          ))}
          {onAll && sites.length > 1 ? (
            <>
              <hr />
              <button
                type="button"
                role="menuitem"
                class="site-option site-add"
                onClick={() => {
                  setOpen(false);
                  onAll();
                }}
              >
                <Icon name="list" />
                <span>{t("sites.all")}</span>
              </button>
            </>
          ) : null}
          {canAdd ? (
            <>
              <hr />
              <button
                type="button"
                role="menuitem"
                class="site-option site-add"
                onClick={() => {
                  setOpen(false);
                  onAdd();
                }}
              >
                <Icon name="plus" />
                <span>{t("sites.addTitle")}</span>
              </button>
            </>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/** Every site side by side for the chosen dates: the six numbers, and a click opens one. */
export function AllSites({ sites, view, onPick, onClose }: { sites: Site[]; view: View; onPick: (id: string) => void; onClose: () => void }) {
  const [rows, setRows] = useState<Record<string, Stats | null>>({});
  useEffect(() => {
    for (const s of sites) {
      api
        .stats({ ...view, site: s.id, filters: [] })
        .then((r) => setRows((all) => ({ ...all, [s.id]: r.stats })))
        .catch(() => setRows((all) => ({ ...all, [s.id]: null })));
    }
  }, []);
  const sorted = [...sites].sort((a, b) => (rows[b.id]?.visitors ?? -1) - (rows[a.id]?.visitors ?? -1));
  return (
    <Sheet title={t("sites.all")} wide onClose={onClose}>
      <div class="sheet-body all-sites">
        <table class="all-table">
          <thead>
            <tr>
              <th>{t("sites.name")}</th>
              <th>{t("metric.visitors")}</th>
              <th>{t("metric.visits")}</th>
              <th>{t("metric.pageviews")}</th>
              <th>{t("metric.bounceRate")}</th>
              <th>{t("metric.visitDuration")}</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((s) => {
              const r = rows[s.id];
              return (
                <tr>
                  <td>
                    <button type="button" class="name" onClick={() => onPick(s.id)}>
                      <span class="name-text">{s.name}</span>
                    </button>
                  </td>
                  <td>{r ? count(r.visitors) : r === null ? "?" : "…"}</td>
                  <td>{r ? count(r.visits) : ""}</td>
                  <td>{r ? count(r.pageviews) : ""}</td>
                  <td>{r ? percent(r.bounceRate) : ""}</td>
                  <td>{r ? duration(r.visitDuration) : ""}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Sheet>
  );
}
