import { useRef, useState } from "preact/hooks";
import { api, type Site } from "./api.js";
import { count } from "./format.js";
import { Secret } from "./secret.js";
import { Icon } from "./icons.js";
import { t } from "./i18n.js";

interface Website {
  id: string;
  name: string;
  domain: string;
}

interface Progress {
  running: boolean;
  done: number;
  total: number;
  pageviews: number;
  events: number;
  visits: number;
  finished: boolean;
  stopped: boolean;
  error: string;
}

const idle: Progress = { running: false, done: 0, total: 0, pageviews: 0, events: 0, visits: 0, finished: false, stopped: false, error: "" };
const bare = (host: string) => host.toLowerCase().replace(/^https?:\/\//, "").replace(/^www\./, "").replace(/\/.*$/, "");

/** Settings, Import, Visits: an Umami site's history, a few days at a time, oldest first. */
export function ImportVisits({ site }: { site: Site }) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [auth, setAuth] = useState<"key" | "password">("key");
  const [websites, setWebsites] = useState<Website[] | null>(null);
  const [website, setWebsite] = useState("");
  const [finding, setFinding] = useState(false);
  const [progress, setProgress] = useState<Progress>(idle);
  const stop = useRef(false);

  const fields = auth === "key" ? (["url", "apiKey"] as const) : (["url", "username", "password"] as const);
  const credentials = () => Object.fromEntries(fields.map((f) => [f, values[f] ?? ""]));
  // New credentials may reach another Umami, so its websites are found again before anything imports.
  const forget = () => {
    setWebsites(null);
    setWebsite("");
  };
  const edit = (f: string, value: string) => {
    setValues({ ...values, [f]: value });
    forget();
  };

  const find = async () => {
    setFinding(true);
    setProgress(idle);
    try {
      const r = await api.umamiWebsites(credentials());
      setWebsites(r.websites);
      // The Umami website for this site's domain, when there is one.
      const match = r.websites.find((w) => site.hostnames.includes(bare(w.domain)));
      setWebsite(match?.id ?? r.websites[0]?.id ?? "");
    } catch (error) {
      setProgress({ ...idle, error: error instanceof Error ? error.message : String(error) });
    } finally {
      setFinding(false);
    }
  };

  const run = async () => {
    stop.current = false;
    let state: Progress = { ...idle, running: true };
    setProgress(state);
    let cursor: string | null = null;
    try {
      do {
        const step = await api.importVisits(site.id, credentials(), website, cursor);
        cursor = step.cursor;
        state = {
          ...state,
          done: step.done,
          total: step.total,
          pageviews: state.pageviews + step.pageviews,
          events: state.events + step.events,
          visits: state.visits + step.visits,
        };
        setProgress(state);
      } while (cursor && !stop.current);
      setProgress({ ...state, running: false, finished: !cursor, stopped: Boolean(cursor) });
    } catch (error) {
      setProgress({ ...state, running: false, error: error instanceof Error ? error.message : String(error) });
    }
  };

  const pct = progress.total ? Math.min(100, Math.round((progress.done / progress.total) * 100)) : 0;
  const label = (f: string) => t(f === "url" ? "import.url" : f === "apiKey" ? "import.apiKey" : f === "username" ? "import.username" : "import.password");

  return (
    <div class="settings-group">
      <p class="settings-text">{t("visits.intro")}</p>
      <div class="field-row">
        <span class="field-label">{t("import.signIn")}</span>
        <div class="ops" role="radiogroup" aria-label={t("import.signIn")}>
          {(["key", "password"] as const).map((a) => (
            <button
              type="button"
              role="radio"
              aria-checked={auth === a}
              class={auth === a ? "op on" : "op"}
              disabled={progress.running}
              onClick={() => {
                setAuth(a);
                forget();
              }}
            >
              {t(a === "key" ? "import.withKey" : "import.withPassword")}
            </button>
          ))}
        </div>
      </div>
      {fields.map((f) => (
        <label class="field-row">
          <span class="field-label">{label(f)}</span>
          {f === "url" || f === "username" ? (
            <input
              class="value"
              type={(f === "url" ? "url" : "text") as "text"}
              autoComplete="off"
              spellcheck={false}
              placeholder={f === "url" ? "https://stats.example.com" : undefined}
              value={values[f] ?? ""}
              disabled={progress.running}
              onInput={(e) => edit(f, (e.target as HTMLInputElement).value)}
            />
          ) : (
            <Secret
              class="value"
              autoComplete="off"
              spellcheck={false}
              value={values[f] ?? ""}
              disabled={progress.running}
              onInput={(e) => edit(f, (e.target as HTMLInputElement).value)}
            />
          )}
        </label>
      ))}
      <p class="field-hint">{t("import.umamiHelp")}</p>

      {websites ? (
        <label class="field-row">
          <span class="field-label">{t("visits.website")}</span>
          {websites.length ? (
            <select class="value" value={website} disabled={progress.running} onChange={(e) => setWebsite((e.target as HTMLSelectElement).value)}>
              {websites.map((w) => (
                <option value={w.id}>{w.domain && w.domain !== w.name ? `${w.name} (${w.domain})` : w.name}</option>
              ))}
            </select>
          ) : (
            <span class="settings-text">{t("visits.noWebsites")}</span>
          )}
        </label>
      ) : null}

      <div class="settings-actions start">
        {!websites || !website ? (
          <button type="button" class="solid" disabled={finding || !values.url} onClick={() => void find()}>
            <Icon name="refresh" />
            {t("visits.find")}
          </button>
        ) : progress.running ? (
          <button type="button" class="ghost" onClick={() => (stop.current = true)}>
            <Icon name="x" />
            {t("import.stop")}
          </button>
        ) : (
          <button type="button" class="solid" onClick={() => void run()}>
            <Icon name="upload" />
            {t("visits.start")}
          </button>
        )}
      </div>

      {progress.running || progress.finished || progress.stopped || progress.error ? (
        <div class="import-progress" aria-live="polite">
          {progress.running ? (
            <>
              <div class="progress-bar">
                <span class="progress-fill" style={{ width: `${pct}%` }} />
              </div>
              <span class="field-hint">{t("visits.running", { done: count(progress.done), total: count(progress.total), pageviews: count(progress.pageviews) })}</span>
            </>
          ) : null}
          {progress.error ? <p class="settings-error">{progress.error}</p> : null}
          {progress.finished ? (
            <p class="settings-ok-text">
              <Icon name="check" />
              {t("visits.done", { pageviews: count(progress.pageviews), visits: count(progress.visits), events: count(progress.events) })}
            </p>
          ) : null}
          {progress.stopped ? <p class="field-hint">{t("visits.stopped")}</p> : null}
        </div>
      ) : null}
    </div>
  );
}
