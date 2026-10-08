import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { api, base, download, install, type Person, type Site, type View } from "./api.js";
import { People } from "./account.js";
import { AssistantSettings } from "./assistant.js";
import { EmailReports } from "./email.js";
import { Goals } from "./goals.js";
import { LANGUAGES, currentLocale, rich, t, type Key } from "./i18n.js";
import { Icon } from "./icons.js";
import { ImportLinks } from "./importer.js";
import { ImportVisits } from "./visitsimport.js";
import { domainPrompt, installPrompt, scriptPrompt } from "./prompts.js";
import { DeleteButton } from "./links.js";
import { Sharing } from "./sharing.js";
import { Tokens } from "./tokens.js";
import { setTheme, themeChoice, type ThemeChoice } from "./theme.js";

export type Section = "general" | "install" | "goals" | "email" | "sharing" | "api" | "links" | "import" | "people" | "data" | "assistant";
const SECTIONS: Array<[Section, Key]> = [
  ["general", "settings.general"],
  ["install", "settings.install"],
  ["goals", "settings.goals"],
  ["email", "settings.email"],
  ["sharing", "settings.sharing"],
  ["api", "settings.api"],
  ["links", "settings.links"],
  ["import", "settings.import"],
  ["data", "settings.data"],
  ["assistant", "settings.assistant"],
];

function timezones(): string[] {
  try {
    return (Intl as unknown as { supportedValuesOf(key: string): string[] }).supportedValuesOf("timeZone");
  } catch {
    return ["UTC"];
  }
}

function ago(ms: number): string {
  const seconds = Math.round((ms - Date.now()) / 1000);
  const f = new Intl.RelativeTimeFormat(currentLocale(), { numeric: "auto" });
  const abs = Math.abs(seconds);
  if (abs < 60) return f.format(seconds, "second");
  if (abs < 3600) return f.format(Math.round(seconds / 60), "minute");
  if (abs < 86_400) return f.format(Math.round(seconds / 3600), "hour");
  return f.format(Math.round(seconds / 86_400), "day");
}

export function Copy({ text, label, class: extra }: { text: string; label?: string; class?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      class={extra ? `copy ${extra}` : "copy"}
      onClick={() => {
        navigator.clipboard
          ?.writeText(text)
          .then(() => {
            setDone(true);
            setTimeout(() => setDone(false), 1600);
          })
          .catch(() => {});
      }}
    >
      <Icon name={done ? "check" : label ? "sparkle" : "copy"} />
      {done ? t("install.copied") : (label ?? t("install.copy"))}
    </button>
  );
}

export function Code({ children }: { children: string }) {
  return (
    <div class="code">
      <pre>
        <code>{children}</code>
      </pre>
      <Copy text={children} />
    </div>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: ComponentChildren }) {
  return (
    <label class="field-row">
      <span class="field-label">{label}</span>
      {children}
      {hint ? <span class="field-hint">{hint}</span> : null}
    </label>
  );
}

function General({ site, onSaved, onLanguage, onDeleted }: { site: Site; onSaved: (site: Site) => void; onLanguage: (code: string) => void; onDeleted: (id: string) => void }) {
  const [name, setName] = useState(site.name);
  const [hostnames, setHostnames] = useState(site.hostnames.join(", "));
  const [timezone, setTimezone] = useState(site.timezone);
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");
  const [error, setError] = useState("");
  const [theme, setThemeChoice] = useState<ThemeChoice>(themeChoice());
  const zones = timezones();
  const hostsChanged = install.managed && hostnames.split(/[\s,]+/).filter(Boolean).join(",") !== site.hostnames.join(",");
  const changed = name.trim() !== site.name || timezone !== site.timezone || hostsChanged;

  const save = (e: Event) => {
    e.preventDefault();
    setState("saving");
    setError("");
    api
      .updateSite(site.id, { name: name.trim(), timezone, ...(hostsChanged ? { hostnames } : {}) })
      .then((r) => {
        onSaved(r.site);
        setState("saved");
      })
      .catch((err: Error) => {
        setError(err.message);
        setState("idle");
      });
  };

  return (
    <>
      {site.remote ? <RemoteCallout site={site} /> : null}
      <form class="settings-group" onSubmit={save}>
        <Field label={t("settings.siteName")}>
          <input class="value" type="text" maxLength={80} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        </Field>
        {install.managed && !site.remote ? (
          <Field label={t("sites.domains")} hint={t("sites.domainsHint")}>
            <input class="value" type="text" value={hostnames} onInput={(e) => setHostnames((e.target as HTMLInputElement).value)} />
          </Field>
        ) : null}
        <Field label={t("settings.timezone")} hint={t("settings.timezoneHint")}>
          <select class="value" value={timezone} onChange={(e) => setTimezone((e.target as HTMLSelectElement).value)}>
            {(zones.includes(timezone) ? zones : [timezone, ...zones]).map((z) => (
              <option value={z}>{z.replace(/_/g, " ")}</option>
            ))}
          </select>
        </Field>
        <div class="settings-actions">
          {error ? <span class="settings-error">{error}</span> : null}
          {state === "saved" && !changed ? <span class="settings-ok">{t("settings.saved")}</span> : null}
          <button type="submit" class="solid" disabled={!changed || state === "saving" || !name.trim()}>
            <Icon name="save" />
            {t(state === "saving" ? "settings.saving" : "settings.save")}
          </button>
        </div>
      </form>
      <div class="settings-group">
        <Field label={t("settings.language")} hint={t("settings.languageHint")}>
          <select class="value" value={currentLocale()} onChange={(e) => onLanguage((e.target as HTMLSelectElement).value)}>
            {LANGUAGES.map(([code, label]) => (
              <option value={code}>{label}</option>
            ))}
          </select>
        </Field>
        <div class="field-row">
          <span class="field-label">{t("settings.theme")}</span>
          <div class="ops" role="radiogroup" aria-label={t("settings.theme")}>
            {(["system", "light", "dark"] as const).map((choice) => (
              <button
                type="button"
                role="radio"
                aria-checked={theme === choice}
                class={theme === choice ? "op on" : "op"}
                onClick={() => {
                  setTheme(choice);
                  setThemeChoice(choice);
                }}
              >
                {t(choice === "system" ? "settings.themeSystem" : choice === "light" ? "settings.themeLight" : "settings.themeDark")}
              </button>
            ))}
          </div>
          <span class="field-hint">{t("settings.languageHint")}</span>
        </div>
      </div>
      {install.managed ? (
        <div class="settings-group">
          <div class="field-row">
            <span class="field-label">{t(site.remote ? "sites.disconnect" : "sites.delete")}</span>
            <span class="field-hint">{t(site.remote ? "sites.disconnectHint" : "sites.deleteHint")}</span>
            <div>
              <DeleteButton
                name={site.name}
                onDelete={() =>
                  void api
                    .deleteSite(site.id)
                    .then(() => onDeleted(site.id))
                    .catch((err: Error) => setError(err.message))
                }
              />
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}

const RETENTION = [6, 12, 24, 36, 60];

/** How long the site keeps its visits, and a download of everything it has. */
function Data({ site, onSaved }: { site: Site; onSaved: (site: Site) => void }) {
  const kept = site.retentionMonths ?? null;
  const [months, setMonths] = useState<number | null>(kept);
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");
  const [error, setError] = useState("");
  const label = (n: number) => (n % 12 === 0 ? t("data.years", { n: n / 12 }) : t("data.months", { n }));
  // Saving a shorter time deletes at once, so say from when before it happens.
  const cutoff = months === null || (kept !== null && months >= kept) ? null : (() => {
    const d = new Date();
    d.setMonth(d.getMonth() - months);
    return d.toLocaleDateString(currentLocale(), { day: "numeric", month: "long", year: "numeric" });
  })();

  const save = (e: Event) => {
    e.preventDefault();
    setState("saving");
    setError("");
    api
      .updateSite(site.id, { retentionMonths: months })
      .then((r) => {
        onSaved({ ...r.site, retentionMonths: months });
        setState("saved");
      })
      .catch((err: Error) => {
        setError(err.message);
        setState("idle");
      });
  };

  return (
    <>
      <form class="settings-group" onSubmit={save}>
        <Field label={t("data.retention")} hint={t("data.retentionHint")}>
          <select class="value" value={months === null ? "" : String(months)} onChange={(e) => {
            const v = (e.target as HTMLSelectElement).value;
            setMonths(v ? Number(v) : null);
            setState("idle");
          }}>
            <option value="">{t("data.forever")}</option>
            {RETENTION.map((n) => (
              <option value={String(n)}>{label(n)}</option>
            ))}
          </select>
        </Field>
        {cutoff ? <p class="settings-warning">{t("data.deletesBefore", { date: cutoff })}</p> : null}
        <div class="settings-actions">
          {error ? <span class="settings-error">{error}</span> : null}
          {state === "saved" && months === kept ? <span class="settings-ok">{t("settings.saved")}</span> : null}
          <button type="submit" class="solid" disabled={months === kept || state === "saving"}>
            <Icon name="save" />
            {t(state === "saving" ? "settings.saving" : "settings.save")}
          </button>
        </div>
      </form>
      <div class="settings-group">
        <div class="field-row">
          <span class="field-label">{t("data.export")}</span>
          <span class="field-hint">{t("data.exportHint")}</span>
          <div>
            <button type="button" class="ghost" onClick={() => void download("export", new URLSearchParams({ site: site.id, period: "all" })).catch((err: Error) => setError(err.message))}>
              <Icon name="download" />
              {t("data.download")}
            </button>
          </div>
        </div>
      </div>
    </>
  );
}

/** Where a connected site is counted, and either that its settings change from here or a way to allow it. */
function RemoteCallout({ site }: { site: Site }) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const allow = () => {
    setError("");
    setBusy(true);
    api
      .connect(site.remote!)
      .then((r) => location.assign(r.authorize))
      .catch((err: Error) => {
        setError(err.message);
        setBusy(false);
      });
  };
  return (
    <>
      <div class="prompt-row">
        <span class="callout-icon" aria-hidden="true">
          <Icon name="external" />
        </span>
        <span class="callout-text settings-text">
          <strong>{t("sites.remoteTitle")}</strong>
          {t(site.manage ? "sites.remoteManaged" : "sites.remoteNote", { url: site.remote! })}
        </span>
        {site.manage ? (
          <a class="box-button" href={site.remote} target="_blank" rel="noopener">
            <Icon name="external" />
            {t("sites.openRemote")}
          </a>
        ) : (
          <button type="button" class="box-button solid" disabled={busy} onClick={allow}>
            <Icon name="key" />
            {t("sites.allowChanges")}
          </button>
        )}
      </div>
      {error ? <p class="settings-error">{error}</p> : null}
    </>
  );
}

/** The key a WordPress, Drupal, or Craft plugin uses to report AI agents reading this site's pages. */
function PluginKey({ site }: { site: Site }) {
  const [key, setKey] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    api
      .observeKey(site.id)
      .then((r) => setKey(r.key))
      .catch((e: Error) => setError(e.message));
  }, [site.id]);
  const replace = () =>
    api
      .newObserveKey(site.id)
      .then((r) => setKey(r.key))
      .catch((e: Error) => setError(e.message));
  return (
    <div class="settings-group">
      <p class="settings-text">
        <strong>{t("pluginKey.title")}</strong>
      </p>
      <p class="settings-text">{t("pluginKey.intro")}</p>
      {key ? <Code>{key}</Code> : null}
      <div class="settings-actions start">
        <button type="button" class="ghost" onClick={() => void replace()}>
          <Icon name="refresh" />
          {t("pluginKey.replace")}
        </button>
      </div>
      {error ? <span class="settings-error">{error}</span> : null}
    </div>
  );
}

/** Settings, Import: visit history from Umami, or short links from any of several services. */
function Import({ site }: { site: Site }) {
  const [kind, setKind] = useState<"visits" | "links">("visits");
  return (
    <>
      <div class="ops import-kind" role="radiogroup" aria-label={t("settings.import")}>
        {(["visits", "links"] as const).map((k) => (
          <button type="button" role="radio" aria-checked={kind === k} class={kind === k ? "op on" : "op"} onClick={() => setKind(k)}>
            {t(k === "visits" ? "visits.tab" : "visits.linksTab")}
          </button>
        ))}
      </div>
      {kind === "visits" ? <ImportVisits site={site} /> : <ImportLinks site={site} />}
    </>
  );
}

export function Install({ site, sites }: { site: Site; sites: Site[] }) {
  const [ignored, setIgnored] = useState(() => {
    try {
      return localStorage.getItem("runlight_ignore") === "1";
    } catch {
      return false;
    }
  });
  const origin = location.origin;
  // The standalone server always names the site, since its script serves many.
  const several = sites.length > 1 || install.managed;
  // The standalone server's script names its site, so it carries only that site's click rules.
  const src = `${origin}${base}/s.js${install.managed ? `?site=${encodeURIComponent(site.id)}` : ""}`;
  const script = `<script defer src="${src}"${several ? ` data-site="${site.id}"` : ""}></script>`;
  const host = site.hostnames[0];
  const ignoreLink = host ? `https://${host}/?runlight=ignore` : "";

  const toggle = () => {
    try {
      if (ignored) localStorage.removeItem("runlight_ignore");
      else localStorage.setItem("runlight_ignore", "1");
      setIgnored(!ignored);
    } catch {}
  };

  return (
    <>
      <p class={site.lastSeen ? "status live" : "status"}>
        <span class={site.lastSeen ? "beat on" : "beat"} aria-hidden="true" />
        {site.lastSeen ? t("install.live", { when: ago(site.lastSeen) }) : t("install.none")}
      </p>
      <div class="prompt-row">
        <span class="callout-icon" aria-hidden="true">
          <Icon name="sparkle" />
        </span>
        <span class="callout-text settings-text">
          <strong>{t("prompt.title")}</strong>
          {t("prompt.installHint")}
        </span>
        <Copy class="prompt-button" label={t("prompt.copy")} text={install.managed ? scriptPrompt({ script, host }) : installPrompt({ origin: location.origin, base, site: several ? site.id : undefined })} />
      </div>
      <div class="settings-group">
        <p class="settings-text">{rich("install.script", { tag: <code>{"</head>"}</code> })}</p>
        <Code>{script}</Code>
        <p class="settings-text">{t("install.events")}</p>
        <Code>{`<button data-runlight="Signup" data-runlight-plan="pro">Sign up</button>`}</Code>
        <p class="settings-text">{t("install.eventsJs")}</p>
        <Code>{`runlight("Newsletter signup", { source: "footer" })`}</Code>
        {install.managed ? null : (
          <>
            <p class="settings-text">{t("install.agents")}</p>
            <Code>{`// proxy.ts (middleware.ts before Next.js 16)
import { rl } from "@/lib/runlight";
export function proxy(request: Request) {
  void rl.observe(request);
}`}</Code>
          </>
        )}
      </div>
      <PluginKey site={site} />
      <div class="settings-group">
        <div class="field-row">
          <span class="field-label">{t("install.ignore")}</span>
          {install.managed ? null : (
            <>
              <span class="settings-text">{t(ignored ? "install.ignored" : "install.counted")}</span>
              <div>
                <button type="button" class="ghost" onClick={toggle}>
                  <Icon name={ignored ? "refresh" : "x"} />
                  {t(ignored ? "install.trackButton" : "install.ignoreButton")}
                </button>
              </div>
            </>
          )}
          {ignoreLink ? (
            <span class={install.managed ? "settings-text" : "field-hint"}>
              {/* The server's dashboard is never on the site's own domain, so the setting has to be made there. */}
              {rich(install.managed ? "install.ignoreServer" : "install.ignoreElsewhere", {
                link: (
                  <a href={ignoreLink} target="_blank" rel="noopener">
                    {ignoreLink}
                  </a>
                ),
              })}
            </span>
          ) : null}
        </div>
      </div>
    </>
  );
}

function useDomainCheck(site: string, domain: string) {
  const [state, setState] = useState<{ working: boolean; reason: string } | null>(null);
  const check = () => {
    setState(null);
    api
      .checkLinkDomain(site, domain)
      .then((r) => setState(r))
      .catch((e: Error) => setState({ working: false, reason: e.message }));
  };
  useEffect(check, [domain]);
  return { state, check };
}

/** One domain: its name and status on the left, its actions side by side on the right. */
function DomainRow({ site, domain, onRemove }: { site: string; domain: string; onRemove: () => void }) {
  const { state, check } = useDomainCheck(site, domain);
  return (
    <li>
      <div class="domain-main">
        <span class="domain-name">{domain}</span>
        <span class={!state ? "domain-status" : state.working ? "domain-status ok" : "domain-status bad"}>
          {state ? <span class={state.working ? "beat on" : "beat off"} aria-hidden="true" /> : null}
          {!state ? t("links.checking") : state.working ? t("links.working") : t("links.notWorking", { reason: state.reason })}
        </span>
      </div>
      <div class="domain-actions">
        {state && !state.working ? (
          <button type="button" class="copy inline" onClick={check}>
            <Icon name="refresh" />
            {t("links.recheck")}
          </button>
        ) : null}
        <button type="button" class="copy inline danger" onClick={onRemove}>
          <Icon name="trash" />
          {t("links.removeDomain")}
        </button>
      </div>
    </li>
  );
}

/** Custom domains for short links, such as t.example.com, with the steps to set one up. */
function LinkDomains({ site }: { site: Site }) {
  // A connected site's links are answered by its own install, so its domains point there.
  const home = site.remote ? new URL(site.remote) : null;
  const hostname = home ? home.hostname : location.hostname;
  const host = home ? home.host : location.host;
  const [domains, setDomains] = useState<string[] | null>(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState("");
  const load = () => api.linkDomains(site.id).then((r) => setDomains(r.domains)).catch((e: Error) => setError(e.message));
  useEffect(() => {
    void load();
  }, [site.id]);
  const add = (e: Event) => {
    e.preventDefault();
    setError("");
    api
      .addLinkDomain(site.id, draft)
      .then(() => {
        setDraft("");
        return load();
      })
      .catch((err: Error) => setError(err.message));
  };
  return (
    <div class="settings-group">
      <div class="field-row">
        <span class="field-label">{t("links.domains")}</span>
        <span class="settings-text">{t("links.domainsHelp")}</span>
      </div>
      <div class="prompt-row">
        <span class="callout-icon" aria-hidden="true">
          <Icon name="sparkle" />
        </span>
        <span class="callout-text settings-text">
          <strong>{t("prompt.title")}</strong>
          {t("prompt.domainHint")}
        </span>
        <Copy
          class="prompt-button"
          label={t("prompt.copy")}
          text={domainPrompt({ domain: draft.trim() || domains?.[0] || "t.example.com", host: hostname, origin: home ? home.origin : location.origin, base: home ? home.pathname.replace(/\/$/, "") : base, linkPath: "/go" })}
        />
      </div>
      <ol class="steps">
        <li>{rich("links.step1", { host: <code>{hostname}</code> })}</li>
        <li>{t("links.step2")}</li>
        <li>{t("links.step3")}</li>
      </ol>
      <ul class="domain-list">
        <li>
          <span class="domain-name">{t("links.ownDomain", { prefix: `${host}/go` })}</span>
        </li>
        {(domains ?? []).map((d) => (
          <DomainRow
            site={site.id}
            domain={d}
            onRemove={() =>
              api
                .removeLinkDomain(site.id, d)
                .then(load)
                .catch((err: Error) => setError(err.message))
            }
          />
        ))}
      </ul>
      <p class="field-hint domain-note">{t("links.removeNote", { fallback: `${host}/go` })}</p>
      <form class="domain-add" onSubmit={add}>
        <input class="value" type="text" placeholder={t("links.domainPlaceholder")} value={draft} onInput={(e) => setDraft((e.target as HTMLInputElement).value)} />
        <button type="submit" class="solid" disabled={!draft.trim()}>
          <Icon name="globe" />
          {t("links.addDomain")}
        </button>
      </form>
      {error ? <span class="settings-error">{error}</span> : null}
    </div>
  );
}

export function SettingsModal({ site, sites, view, start, onClose, onSaved, onLanguage, onDeleted, me }: {
  site: Site;
  view: View;
  start?: Section;
  sites: Site[];
  onClose: () => void;
  onSaved: (site: Site) => void;
  onLanguage: (code: string) => void;
  onDeleted: (id: string) => void;
  /** Who is signed in, on the standalone server; owners also manage People there. */
  me?: Person | null;
}) {
  // A connected site is managed on its own install; here it has a name, a timezone, and a way to disconnect.
  // A connected site is counted on its own install. With a manage token its site settings change here and are saved there;
  // install-wide things (people, tokens, imports, sharing) stay with that install.
  const sections: Array<[Section, Key]> = site.remote
    ? site.manage
      ? SECTIONS.filter(([id]) => ["general", "goals", "email", "sharing", "links", "data"].includes(id))
      : [["general", "settings.general"]]
    : me?.role === "owner"
      ? [...SECTIONS, ["people", "settings.people"]]
      : SECTIONS;
  const [section, setSection] = useState<Section>(start ?? "general");
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    document.body.classList.add("locked");
    panel.current?.querySelector<HTMLElement>(".settings-nav button")?.focus();
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("locked");
    };
  }, []);

  return (
    <div class="scrim center" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div class="settings" role="dialog" aria-modal="true" aria-labelledby="settings-title" ref={panel}>
        <nav class="settings-nav" aria-label={t("settings.title")}>
          <h2 id="settings-title">{t("settings.title")}</h2>
          <p class="settings-site">{site.name}</p>
          {sections.map(([id, label]) => (
            <button type="button" class={section === id ? "settings-tab on" : "settings-tab"} aria-current={section === id ? "page" : undefined} onClick={() => setSection(id)}>
              {t(label)}
            </button>
          ))}
        </nav>
        <div class="settings-body">
          <header class="settings-head">
            <h3>{t(sections.find(([id]) => id === section)![1])}</h3>
            <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M4 4l8 8M12 4l-8 8" />
              </svg>
            </button>
          </header>
          <div class="settings-content">
            {section === "general" ? (
              <General site={site} onSaved={onSaved} onLanguage={onLanguage} onDeleted={onDeleted} />
            ) : section === "install" ? (
              <Install site={site} sites={sites} />
            ) : section === "goals" ? (
              <Goals site={site} view={view} />
            ) : section === "email" ? (
              <EmailReports site={site} />
            ) : section === "sharing" ? (
              <Sharing site={site} />
            ) : section === "people" && me ? (
              <People me={me} />
            ) : section === "api" ? (
              <Tokens sites={sites} />
            ) : section === "links" ? (
              <LinkDomains site={site} />
            ) : section === "data" ? (
              <Data site={site} onSaved={onSaved} />
            ) : section === "assistant" ? (
              <AssistantSettings owner={!me || me.role === "owner"} />
            ) : (
              <Import site={site} />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
