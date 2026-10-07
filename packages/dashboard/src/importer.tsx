import { useRef, useState } from "preact/hooks";
import { api, type Site } from "./api.js";
import { count } from "./format.js";
import { Icon } from "./icons.js";
import { t, tn, type Key } from "./i18n.js";
import { parseCsv } from "./links.js";

type Source = "umami" | "dub" | "bitly" | "shortio" | "rebrandly" | "csv";

interface Field {
  name: string;
  label: Key;
  type?: "password" | "url";
  placeholder?: string;
}

const SOURCES: Array<{ id: Source; name: string; help: Key; history: "full" | "daily" | "none"; fields: Field[] }> = [
  { id: "umami", name: "Umami", help: "import.umamiHelp", history: "full", fields: [{ name: "url", label: "import.url", type: "url", placeholder: "https://stats.example.com" }] },
  { id: "dub", name: "Dub", help: "import.dubHelp", history: "full", fields: [{ name: "apiKey", label: "import.apiKey", type: "password", placeholder: "dub_..." }] },
  { id: "bitly", name: "Bitly", help: "import.bitlyHelp", history: "daily", fields: [{ name: "token", label: "import.token", type: "password" }] },
  { id: "shortio", name: "Short.io", help: "import.shortioHelp", history: "daily", fields: [{ name: "apiKey", label: "import.apiKey", type: "password", placeholder: "sk_..." }] },
  {
    id: "rebrandly",
    name: "Rebrandly",
    help: "import.rebrandlyHelp",
    history: "none",
    fields: [
      { name: "apiKey", label: "import.apiKey", type: "password" },
      { name: "workspace", label: "import.workspace" },
    ],
  },
  { id: "csv", name: "CSV", help: "import.csvHelp", history: "none", fields: [] },
];

interface Progress {
  running: boolean;
  done: number;
  total: number | null;
  links: number;
  clicks: number;
  skipped: number;
  failed: Array<{ slug: string; reason: string }>;
  finished: boolean;
  stopped: boolean;
  error: string;
}

const idle: Progress = { running: false, done: 0, total: null, links: 0, clicks: 0, skipped: 0, failed: [], finished: false, stopped: false, error: "" };

/** Settings, Import links: pick a service, sign in, and watch it come across a few links at a time. */
export function ImportLinks({ site }: { site: Site }) {
  const [source, setSource] = useState<Source>("umami");
  const [values, setValues] = useState<Record<string, string>>({});
  const [umamiAuth, setUmamiAuth] = useState<"key" | "password">("key");
  const [progress, setProgress] = useState<Progress>(idle);
  const stop = useRef(false);
  const file = useRef<HTMLInputElement>(null);
  const def = SOURCES.find((s) => s.id === source)!;

  const fields: Field[] =
    source === "umami"
      ? [
          ...def.fields,
          ...(umamiAuth === "key"
            ? [{ name: "apiKey", label: "import.apiKey" as Key, type: "password" as const }]
            : [
                { name: "username", label: "import.username" as Key },
                { name: "password", label: "import.password" as Key, type: "password" as const },
              ]),
        ]
      : def.fields;

  const run = async () => {
    stop.current = false;
    let state: Progress = { ...idle, running: true };
    setProgress(state);
    const credentials = Object.fromEntries(fields.map((f) => [f.name, values[f.name] ?? ""]));
    let cursor: string | null = null;
    try {
      do {
        const step = await api.importStep(site.id, source, credentials, cursor, state.done);
        cursor = step.cursor;
        state = {
          ...state,
          done: step.done,
          total: step.total,
          links: state.links + step.links,
          clicks: state.clicks + step.clicks,
          skipped: state.skipped + step.skipped,
          failed: [...state.failed, ...step.failed],
        };
        setProgress(state);
      } while (cursor && !stop.current);
      setProgress({ ...state, running: false, finished: !cursor, stopped: Boolean(cursor) });
    } catch (error) {
      setProgress({ ...state, running: false, error: error instanceof Error ? error.message : String(error) });
    }
  };

  const importCsv = async (f: File) => {
    setProgress({ ...idle, running: true });
    try {
      const rows = parseCsv(await f.text());
      const result = await api.importLinks(site.id, rows);
      setProgress({ ...idle, finished: true, links: result.created, done: rows.length, total: rows.length, failed: result.failed.map((x) => ({ slug: `#${x.row}`, reason: x.reason })) });
    } catch (error) {
      setProgress({ ...idle, error: error instanceof Error ? error.message : String(error) });
    }
  };

  const pct = progress.total ? Math.min(100, Math.round((progress.done / progress.total) * 100)) : null;

  return (
    <div class="settings-group">
      <p class="settings-text">{t("import.intro")}</p>
      <div class="field-row">
        <span class="field-label">{t("import.source")}</span>
        <div class="source-grid" role="radiogroup" aria-label={t("import.source")}>
          {SOURCES.map((s) => (
            <button
              type="button"
              role="radio"
              aria-checked={source === s.id}
              class={source === s.id ? "source on" : "source"}
              disabled={progress.running}
              onClick={() => {
                setSource(s.id);
                setProgress(idle);
              }}
            >
              <strong>{s.id === "csv" ? t("import.csv") : s.name}</strong>
              <span>{t(`import.history.${s.history}`)}</span>
            </button>
          ))}
        </div>
      </div>
      <p class="field-hint">{t(def.help)}</p>

      {source === "umami" ? (
        <div class="field-row">
          <span class="field-label">{t("import.signIn")}</span>
          <div class="ops" role="radiogroup" aria-label={t("import.signIn")}>
            {(["key", "password"] as const).map((a) => (
              <button type="button" role="radio" aria-checked={umamiAuth === a} class={umamiAuth === a ? "op on" : "op"} onClick={() => setUmamiAuth(a)}>
                {t(a === "key" ? "import.withKey" : "import.withPassword")}
              </button>
            ))}
          </div>
        </div>
      ) : null}

      {fields.map((f) => (
        <label class="field-row">
          <span class="field-label">{t(f.label)}</span>
          <input
            class="value"
            type={(f.type ?? "text") as "text"}
            autoComplete="off"
            spellcheck={false}
            placeholder={f.placeholder}
            value={values[f.name] ?? ""}
            onInput={(e) => setValues({ ...values, [f.name]: (e.target as HTMLInputElement).value })}
          />
        </label>
      ))}

      <p class="field-hint">{t("import.moveNote", { fallback: `${location.host}/go` })}</p>

      <div class="settings-actions start">
        {source === "csv" ? (
          <>
            <button type="button" class="solid" disabled={progress.running} onClick={() => file.current?.click()}>
              <Icon name="upload" />
              {t("import.chooseFile")}
            </button>
            <input
              ref={file}
              type="file"
              accept=".csv,text/csv"
              hidden
              onChange={(e) => {
                const f = (e.target as HTMLInputElement).files?.[0];
                if (f) void importCsv(f);
                (e.target as HTMLInputElement).value = "";
              }}
            />
          </>
        ) : progress.running ? (
          <button type="button" class="ghost" onClick={() => (stop.current = true)}>
            <Icon name="x" />
            {t("import.stop")}
          </button>
        ) : (
          <button type="button" class="solid" onClick={() => void run()}>
            <Icon name="upload" />
            {t("import.start")}
          </button>
        )}
      </div>

      {progress.running || progress.finished || progress.stopped || progress.error ? (
        <div class="import-progress" aria-live="polite">
          {progress.running ? (
            <>
              <div class="progress-bar">
                <span class={pct === null ? "progress-fill indeterminate" : "progress-fill"} style={pct === null ? undefined : { width: `${pct}%` }} />
              </div>
              <span class="field-hint">
                {progress.total ? t("import.running", { done: count(progress.done), total: count(progress.total) }) : tn("import.soFar", progress.links, { n: count(progress.links) })}
                {progress.clicks ? ` · ${tn("links.total", progress.clicks, { n: count(progress.clicks) })}` : ""}
              </span>
            </>
          ) : null}
          {progress.error ? <p class="settings-error">{progress.error}</p> : null}
          {progress.finished ? (
            <p class="settings-ok-text">
              <Icon name="check" />
              {t("import.done", { links: count(progress.links), clicks: count(progress.clicks), skipped: count(progress.skipped) })}
            </p>
          ) : null}
          {progress.stopped ? <p class="field-hint">{t("import.stopped", { done: count(progress.done), total: count(progress.total ?? progress.done) })}</p> : null}
          {progress.failed.length ? (
            <div class="import-result">
              <strong>{t("import.failed")}</strong>
              {progress.failed.slice(0, 20).map((f) => (
                <span>
                  {f.slug}: {f.reason}
                </span>
              ))}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
