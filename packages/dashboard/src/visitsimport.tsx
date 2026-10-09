import { useRef, useState } from "preact/hooks";
import { api, type Site } from "./api.js";
import { count } from "./format.js";
import { Secret } from "./secret.js";
import { Callout } from "./callout.js";
import { Icon } from "./icons.js";
import { t } from "./i18n.js";
import { parseCsv } from "./links.js";
import { CSV_BATCH, csvFormat, rowTime, type CsvFormat } from "../../sdk/src/importers/csvvisits.js";

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

/** Settings, Import, Visits: history from Umami's API or from a CSV file. */
export function ImportVisits({ site }: { site: Site }) {
  const [from, setFrom] = useState<"umami" | "csv">("umami");
  return (
    <div class="settings-group">
      <p class="settings-text">{t("visits.intro")}</p>
      <Callout icon="chart" title={t("visits.onlyUmamiTitle")}>
        {t("visits.onlyUmami")}
      </Callout>
      <div class="field-row">
        <span class="field-label">{t("visits.from")}</span>
        <div class="ops" role="radiogroup" aria-label={t("visits.from")}>
          {(["umami", "csv"] as const).map((f) => (
            <button type="button" role="radio" aria-checked={from === f} class={from === f ? "op on" : "op"} onClick={() => setFrom(f)}>
              {t(f === "umami" ? "visits.fromUmami" : "visits.fromCsv")}
            </button>
          ))}
        </div>
      </div>
      {from === "umami" ? <UmamiVisits site={site} /> : <CsvVisits site={site} />}
    </div>
  );
}

/** Rows sorted oldest first, cut into batches that never split one moment, so each batch's time span is its own. */
function batches(rows: Array<Record<string, string>>, format: CsvFormat): Array<Array<Record<string, string>>> | null {
  const timed = rows.map((row) => ({ row, ts: rowTime(row, format) })).filter((r) => Number.isFinite(r.ts));
  timed.sort((a, b) => a.ts - b.ts);
  const out: Array<Array<Record<string, string>>> = [];
  let i = 0;
  while (i < timed.length) {
    let j = Math.min(i + CSV_BATCH, timed.length);
    // Back up to the start of a moment that would otherwise be split.
    while (j < timed.length && j > i && timed[j]!.ts === timed[j - 1]!.ts) j--;
    if (j === i) return null;
    out.push(timed.slice(i, j).map((r) => r.row));
    i = j;
  }
  return out;
}

/** Settings, Import, Visits, from a CSV file: Umami's export or Runlight's own columns, sent a batch at a time. */
function CsvVisits({ site }: { site: Site }) {
  const [file, setFile] = useState<{ name: string; rows: Array<Record<string, string>>; format: CsvFormat } | null>(null);
  const [progress, setProgress] = useState<Progress & { skipped: number }>({ ...idle, skipped: 0 });
  const input = useRef<HTMLInputElement>(null);
  const stop = useRef(false);

  const choose = async (f: File) => {
    setFile(null);
    setProgress({ ...idle, skipped: 0 });
    const rows = parseCsv(await f.text());
    const format = csvFormat(Object.keys(rows[0] ?? {}));
    if (!format || !rows.length) {
      setProgress({ ...idle, skipped: 0, error: t("error.import_csv_format") });
      return;
    }
    setFile({ name: f.name, rows, format });
  };

  const run = async () => {
    if (!file) return;
    stop.current = false;
    const parts = batches(file.rows, file.format);
    if (!parts) {
      setProgress({ ...idle, skipped: 0, error: t("visits.csvMoment", { max: count(CSV_BATCH) }) });
      return;
    }
    const unreadable = file.rows.length - parts.reduce((n, p) => n + p.length, 0);
    let state = { ...idle, skipped: unreadable, running: true, total: file.rows.length };
    setProgress(state);
    try {
      for (const part of parts) {
        if (stop.current) break;
        const step = await api.importCsvVisits(site.id, part);
        state = {
          ...state,
          done: state.done + part.length,
          pageviews: state.pageviews + step.pageviews,
          events: state.events + step.events,
          visits: state.visits + step.visits,
          skipped: state.skipped + step.skipped,
        };
        setProgress(state);
      }
      const finished = state.done + unreadable >= file.rows.length;
      setProgress({ ...state, running: false, finished, stopped: !finished });
    } catch (error) {
      setProgress({ ...state, running: false, error: error instanceof Error ? error.message : String(error) });
    }
  };

  const pct = progress.total ? Math.min(100, Math.round((progress.done / progress.total) * 100)) : 0;
  return (
    <>
      <p class="field-hint">{t("visits.csvHelp")}</p>
      <div class="settings-actions start">
        {progress.running ? (
          <button type="button" class="ghost" onClick={() => (stop.current = true)}>
            <Icon name="x" />
            {t("import.stop")}
          </button>
        ) : (
          <>
            <button type="button" class={file ? "ghost" : "solid"} onClick={() => input.current?.click()}>
              <Icon name="upload" />
              {t(file ? "visits.csvOther" : "visits.csvChoose")}
            </button>
            {file ? (
              <button type="button" class="solid" onClick={() => void run()}>
                <Icon name="upload" />
                {t("visits.start")}
              </button>
            ) : null}
          </>
        )}
        <input
          ref={input}
          type="file"
          accept=".csv,text/csv"
          hidden
          onChange={(e) => {
            const f = (e.target as HTMLInputElement).files?.[0];
            if (f) void choose(f);
            (e.target as HTMLInputElement).value = "";
          }}
        />
      </div>
      {file && !progress.running && !progress.finished ? (
        <p class="field-hint">{t(file.format === "umami" ? "visits.csvUmami" : "visits.csvRunlight", { name: file.name, rows: count(file.rows.length) })}</p>
      ) : null}
      {progress.running || progress.finished || progress.stopped || progress.error ? (
        <div class="import-progress" aria-live="polite">
          {progress.running ? (
            <>
              <div class="progress-bar">
                <span class="progress-fill" style={{ width: `${pct}%` }} />
              </div>
              <span class="field-hint">{t("visits.csvRunning", { done: count(progress.done), total: count(progress.total), pageviews: count(progress.pageviews) })}</span>
            </>
          ) : null}
          {progress.error ? <p class="settings-error">{progress.error}</p> : null}
          {progress.finished ? (
            <p class="settings-ok-text">
              <Icon name="check" />
              {t("visits.done", { pageviews: count(progress.pageviews), visits: count(progress.visits), events: count(progress.events) })}
            </p>
          ) : null}
          {(progress.finished || progress.stopped) && progress.skipped ? <p class="field-hint">{t("visits.csvSkipped", { n: count(progress.skipped) })}</p> : null}
          {progress.stopped ? <p class="field-hint">{t("visits.csvStopped")}</p> : null}
        </div>
      ) : null}
    </>
  );
}

/** Settings, Import, Visits, from Umami: an Umami site's history, a few days at a time, oldest first. */
function UmamiVisits({ site }: { site: Site }) {
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
    <>
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
    </>
  );
}
