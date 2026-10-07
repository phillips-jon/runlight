import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { api, base, type Site } from "./api.js";
import { LANGUAGES, currentLocale, rich, t, type Key } from "./i18n.js";
import { setTheme, themeChoice, type ThemeChoice } from "./theme.js";

type Section = "general" | "install";
const SECTIONS: Array<[Section, Key]> = [
  ["general", "settings.general"],
  ["install", "settings.install"],
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

function Copy({ text }: { text: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      class="copy"
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
      {t(done ? "install.copied" : "install.copy")}
    </button>
  );
}

function Code({ children }: { children: string }) {
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

function General({ site, onSaved, onLanguage }: { site: Site; onSaved: (site: Site) => void; onLanguage: (code: string) => void }) {
  const [name, setName] = useState(site.name);
  const [timezone, setTimezone] = useState(site.timezone);
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");
  const [error, setError] = useState("");
  const [theme, setThemeChoice] = useState<ThemeChoice>(themeChoice());
  const zones = timezones();
  const changed = name.trim() !== site.name || timezone !== site.timezone;

  const save = (e: Event) => {
    e.preventDefault();
    setState("saving");
    setError("");
    api
      .updateSite(site.id, { name: name.trim(), timezone })
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
      <form class="settings-group" onSubmit={save}>
        <Field label={t("settings.siteName")}>
          <input class="value" type="text" maxLength={80} value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        </Field>
        <Field label={t("settings.timezone")} hint={t("settings.timezoneHint")}>
          <select class="field" value={timezone} onChange={(e) => setTimezone((e.target as HTMLSelectElement).value)}>
            {(zones.includes(timezone) ? zones : [timezone, ...zones]).map((z) => (
              <option value={z}>{z.replace(/_/g, " ")}</option>
            ))}
          </select>
        </Field>
        <div class="settings-actions">
          {error ? <span class="settings-error">{error}</span> : null}
          {state === "saved" && !changed ? <span class="settings-ok">{t("settings.saved")}</span> : null}
          <button type="submit" class="solid" disabled={!changed || state === "saving" || !name.trim()}>
            {t(state === "saving" ? "settings.saving" : "settings.save")}
          </button>
        </div>
      </form>
      <div class="settings-group">
        <Field label={t("settings.language")} hint={t("settings.languageHint")}>
          <select class="field" value={currentLocale()} onChange={(e) => onLanguage((e.target as HTMLSelectElement).value)}>
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
    </>
  );
}

function Install({ site, sites }: { site: Site; sites: Site[] }) {
  const [ignored, setIgnored] = useState(() => {
    try {
      return localStorage.getItem("runlight_ignore") === "1";
    } catch {
      return false;
    }
  });
  const origin = location.origin;
  const several = sites.length > 1;
  const script = `<script defer src="${origin}${base}/s.js"${several ? ` data-site="${site.id}"` : ""}></script>`;
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
      <div class="settings-group">
        <p class="settings-text">{rich("install.script", { tag: <code>{"</head>"}</code> })}</p>
        <Code>{script}</Code>
        <p class="settings-text">{t("install.events")}</p>
        <Code>{`<button data-runlight="Signup" data-runlight-plan="pro">Sign up</button>`}</Code>
        <p class="settings-text">{t("install.eventsJs")}</p>
        <Code>{`runlight("Newsletter signup", { source: "footer" })`}</Code>
        <p class="settings-text">{t("install.agents")}</p>
        <Code>{`// proxy.ts (middleware.ts before Next.js 16)
import { rl } from "@/lib/runlight";
export function proxy(request: Request) {
  void rl.observe(request);
}`}</Code>
      </div>
      <div class="settings-group">
        <div class="field-row">
          <span class="field-label">{t("install.ignore")}</span>
          <span class="settings-text">{t(ignored ? "install.ignored" : "install.counted")}</span>
          <div>
            <button type="button" class="ghost" onClick={toggle}>
              {t(ignored ? "install.trackButton" : "install.ignoreButton")}
            </button>
          </div>
          {ignoreLink ? (
            <span class="field-hint">
              {rich("install.ignoreElsewhere", {
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

export function SettingsModal({ site, sites, onClose, onSaved, onLanguage }: {
  site: Site;
  sites: Site[];
  onClose: () => void;
  onSaved: (site: Site) => void;
  onLanguage: (code: string) => void;
}) {
  const [section, setSection] = useState<Section>("general");
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
          {SECTIONS.map(([id, label]) => (
            <button type="button" class={section === id ? "settings-tab on" : "settings-tab"} aria-current={section === id ? "page" : undefined} onClick={() => setSection(id)}>
              {t(label)}
            </button>
          ))}
        </nav>
        <div class="settings-body">
          <header class="settings-head">
            <h3>{t(SECTIONS.find(([id]) => id === section)![1])}</h3>
            <button type="button" class="remove" aria-label={t("common.close")} onClick={onClose}>
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M4 4l8 8M12 4l-8 8" />
              </svg>
            </button>
          </header>
          <div class="settings-content">
            {section === "general" ? <General site={site} onSaved={onSaved} onLanguage={onLanguage} /> : <Install site={site} sites={sites} />}
          </div>
        </div>
      </div>
    </div>
  );
}
