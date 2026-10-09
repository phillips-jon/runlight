/**
 * Visit history from Umami: pageviews and custom events with where each
 * visit came from, its place, and its device, written as imported visits so
 * the dashboard's history does not start the day Runlight was installed.
 *
 * The dashboard drives it a few days at a time, oldest first, so it fits any
 * host's time limit and shows progress. It stops where Runlight's own visits
 * begin, so nothing is counted twice, and it remembers how far it got, so
 * running it again carries on from there.
 */
import { addDays, localDate } from "../time.js";
import type { Runlight } from "../runlight.js";
import { SESSION_IDLE_MS } from "../runlight.js";
import { attribute, parsePage } from "../sources.js";
import { EVENT_TAIL_MS, type SqlStore } from "../store.js";
import { getJson } from "./http.js";
import { ImportError } from "./types.js";
import { umamiSignIn } from "./umami.js";
import { CSV_BATCH, csvFormat, csvHit } from "./csvvisits.js";
import { browserName, deviceName, hexId, systemName } from "./write.js";

const DAY = 86_400_000;
/** Each step reads at most this many days, or stops after this many events. */
const STEP_DAYS = 14;
const STEP_EVENTS = 5_000;
/** A single day with more than this is refused rather than read without end. */
const MAX_DAY_EVENTS = 200_000;

/** Umami's event types that are visits: a pageview, and a custom event. */
const PAGEVIEW = 1;
const CUSTOM_EVENT = 2;

interface UmamiEvent {
  sessionId: string;
  createdAt: string;
  hostname?: string;
  urlPath: string;
  urlQuery?: string;
  referrerDomain?: string;
  referrerPath?: string;
  referrerQuery?: string;
  pageTitle?: string;
  eventType: number;
  eventName?: string;
  country?: string;
  city?: string;
  device?: string;
  os?: string;
  browser?: string;
}

interface UmamiSession {
  id: string;
  screen?: string;
  language?: string;
  region?: string;
  subdivision1?: string;
}

export interface UmamiWebsite {
  id: string;
  name: string;
  domain: string;
}

export interface VisitImportStep {
  cursor: string | null;
  /** Days read so far and in all, for the progress bar. */
  done: number;
  total: number;
  pageviews: number;
  events: number;
  visits: number;
}

interface Cursor {
  website: string;
  day: number;
  end: number;
  start: number;
  token?: string;
}

const progressKey = (site: string, website: string) => `import:umami-visits:${site}:${website}`;

/** The websites an Umami account can see, to pick which one becomes this site's history. */
export async function umamiWebsites(credentials: Record<string, string>): Promise<UmamiWebsite[]> {
  const { base, token } = await umamiSignIn(credentials);
  const headers = { authorization: `Bearer ${token}` };
  const out: UmamiWebsite[] = [];
  for (let page = 1; page < 100; page++) {
    const body = await getJson<{ data: Array<{ id: string; name: string; domain: string }>; count: number }>(`${base}/api/websites?page=${page}&pageSize=100`, { headers });
    out.push(...body.data.map((w) => ({ id: w.id, name: w.name, domain: w.domain })));
    if (out.length >= body.count || body.data.length === 0) break;
  }
  return out;
}

/** Every page of an Umami list for a time window. */
async function all<T>(base: string, path: string, headers: Record<string, string>, limit: number): Promise<T[]> {
  const out: T[] = [];
  for (let page = 1; ; page++) {
    const body = await getJson<{ data: T[]; count: number }>(`${base}/api${path}&page=${page}&pageSize=1000`, { headers });
    out.push(...body.data);
    if (out.length >= body.count || body.data.length === 0) return out;
    if (out.length > limit) throw new ImportError(`One day has more than ${limit.toLocaleString("en")} events, more than an import step can read`, "import_day_full", { limit: String(limit) });
  }
}

/** One step: read the next few days from Umami and write them as imported visits. */
export async function importUmamiVisits(
  runlight: Runlight,
  siteId: string,
  credentials: Record<string, string>,
  website: string,
  cursor: string | null,
): Promise<VisitImportStep> {
  await runlight.init();
  const site = runlight.site(siteId);
  if (!site) throw new ImportError("Unknown site", "unknown_site");
  if (!/^[A-Za-z0-9-]{1,64}$/.test(website)) throw new ImportError("Pick the Umami website to import", "import_website");

  let state: Cursor;
  const saved = cursor ? (JSON.parse(cursor) as Cursor) : null;
  const { base, token } = await umamiSignIn(credentials, saved?.token);
  const headers = { authorization: `Bearer ${token}` };
  if (saved && saved.website === website) state = saved;
  else {
    const info = await getJson<{ createdAt: string }>(`${base}/api/websites/${website}`, { headers });
    const created = Date.parse(info.createdAt) || runlight.now();
    // Carry on where an earlier run stopped, and end where Runlight's own visits begin.
    // A saved place that does not read as a number is ignored, as if there were none.
    const stored = Number((await runlight.store.setting(progressKey(siteId, website))) ?? 0);
    const resumed = Number.isFinite(stored) ? stored : 0;
    // Never older than the site keeps, or the next scheduled check would delete it again.
    const cutoff = (await runlight.retentionCutoff(siteId)) ?? 0;
    const start = Math.max(Math.floor(created / DAY) * DAY, resumed, Math.ceil(cutoff / DAY) * DAY);
    const own = await runlight.store.firstOwnVisit(siteId);
    state = { website, day: start, start, end: own ?? runlight.now() };
  }
  const usesKey = Boolean(credentials.apiKey?.trim());

  // Read whole days until the step has enough.
  const events: UmamiEvent[] = [];
  const from = state.day;
  let to = state.day;
  while (to < state.end && to - from < STEP_DAYS * DAY && events.length < STEP_EVENTS) {
    const next = Math.min(to + DAY, state.end);
    // One at a time: spreading a busy day's events as arguments would pass the call stack's limit.
    for (const e of await all<UmamiEvent>(base, `/websites/${website}/events?startAt=${to}&endAt=${next - 1}`, headers, MAX_DAY_EVENTS)) events.push(e);
    to = next;
  }
  const sessions = events.length ? await all<UmamiSession>(base, `/websites/${website}/sessions?startAt=${from}&endAt=${to - 1}`, headers, MAX_DAY_EVENTS * STEP_DAYS) : [];
  const info = new Map(sessions.map((s) => [s.id, s]));

  const ns = `umami-visits:${website}`;
  const visits = events
    .filter((e) => e.eventType === PAGEVIEW || (e.eventType === CUSTOM_EVENT && e.eventName))
    .map((e) => ({ ...e, ts: Date.parse(e.createdAt) }))
    .filter((e) => Number.isFinite(e.ts) && e.ts < state.end)
    .sort((a, b) => a.ts - b.ts)
    .map((e) => ({ ns, hit: fromUmami(e, info.get(e.sessionId)) }));
  const counts = await writeStep(runlight, siteId, from, to, visits, (store) => store.setSetting(progressKey(siteId, website), String(to)));

  const totalDays = Math.max(1, Math.ceil((state.end - state.start) / DAY));
  const doneDays = Math.min(totalDays, Math.ceil((to - state.start) / DAY));
  const more = to < state.end;
  return {
    cursor: more ? JSON.stringify({ ...state, day: to, ...(usesKey ? {} : { token }) }) : null,
    done: doneDays,
    total: totalDays,
    ...counts,
  };
}

/**
 * Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an earlier import
 * left in those times is cleared first, so a step can always run again, and a visit carried in from the step
 * before is counted again from its rows. `done` runs in the same transaction, to remember how far it got.
 */
async function writeStep(
  runlight: Runlight,
  siteId: string,
  from: number,
  to: number,
  hits: Array<{ ns: string; hit: ImportedHit }>,
  done?: (store: SqlStore) => Promise<void>,
): Promise<{ pageviews: number; events: number; visits: number }> {
  const site = runlight.site(siteId);
  if (!site) throw new ImportError("Unknown site", "unknown_site");
  const counts = { pageviews: 0, events: 0, visits: 0 };
  await runlight.store.transaction(async (store) => {
    // Days this step writes into are added up again later, with the imported visits in them.
    await store.clearRollups(siteId, { from, to });
    // A failed earlier try at these days (on D1, which has no transactions) can
    // have left part of them behind. Clear it, so every step can safely run again.
    const imported = `SELECT id FROM rl_sessions WHERE site = ? AND imported = 1`;
    await store.db.run(`DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN (${imported})`, [siteId, from, to, siteId]);
    // Visits of these days that kept no rows go too. Their rows would come within EVENT_TAIL_MS of the step,
    // so the time bounds let the (site, ts) index find them, with no scan of every event.
    await store.db.run(
      `DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?
         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)`,
      [siteId, from, to, siteId, from, to + EVENT_TAIL_MS],
    );
    for (const { ns, hit } of hits) {
      const made = await writeEvent(store, site, ns, hit);
      if (made) counts.visits++;
      if (hit.kind === "pageview") counts.pageviews++;
      else counts.events++;
    }
    // A visit that began in an earlier step and went on into this one is counted
    // again from its rows, so a repeated step cannot leave it with doubled totals.
    // The day it began may already be built, so that day is built again too.
    const carried = await store.db.all<{ id: string; started_at: unknown }>(
      `SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s
       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?
         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)`,
      [siteId, from, from - EVENT_TAIL_MS, siteId, from, to],
    );
    if (carried.length) {
      const earliest = Math.min(...carried.map((c) => Number(c.started_at)));
      await store.clearRollups(siteId, { from: earliest, to: from });
      // Their rows lie between the earliest start and this step's end, which the (site, ts) index reads in one pass.
      // Ninety ids a statement, within Cloudflare D1's 100 values.
      const rows: Array<{ session: string; kind: string; ts: unknown; path: string }> = [];
      for (let i = 0; i < carried.length; i += 90) {
        const ids = carried.slice(i, i + 90).map((c) => c.id);
        rows.push(
          ...(await store.db.all<{ session: string; kind: string; ts: unknown; path: string }>(
            `SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e
             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN (${ids.map(() => "?").join(", ")})
             ORDER BY e.ts, e.id`,
            [siteId, earliest, to, ...ids],
          )),
        );
      }
      const totals = new Map<string, { pageviews: number; events: number; last: number; exit: string | null }>();
      for (const r of rows) {
        const t = totals.get(r.session) ?? { pageviews: 0, events: 0, last: 0, exit: null };
        if (r.kind === "pageview") {
          t.pageviews++;
          t.exit = r.path;
        } else t.events++;
        t.last = Math.max(t.last, Number(r.ts));
        totals.set(r.session, t);
      }
      for (const [id, t] of totals) {
        await store.db.run(`UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?`, [t.pageviews, t.events, t.last, t.exit, id]);
      }
    }
    if (done) await done(store);
  });
  return counts;
}

/**
 * One pageview or event from another tool, in the shape every visit import writes.
 * `key` groups rows into visitors, as Umami's session id does.
 */
export interface ImportedHit {
  ts: number;
  key: string;
  kind: "pageview" | "event";
  hostname: string;
  path: string;
  query: string;
  referrer: string;
  title: string;
  name: string;
  country: string;
  region: string;
  city: string;
  browser: string;
  os: string;
  device: string;
  screen: string;
  language: string;
}

const referrerOf = (domain?: string, path?: string, query?: string) =>
  domain ? `https://${domain}${path || "/"}${query ? `?${query.replace(/^\?/, "")}` : ""}` : "";

function fromUmami(e: UmamiEvent & { ts: number }, session: UmamiSession | undefined): ImportedHit {
  return {
    ts: e.ts,
    key: e.sessionId,
    kind: e.eventType === PAGEVIEW ? "pageview" : "event",
    hostname: e.hostname ?? "",
    path: e.urlPath,
    query: e.urlQuery ?? "",
    referrer: referrerOf(e.referrerDomain, e.referrerPath, e.referrerQuery),
    title: e.pageTitle ?? "",
    name: e.eventName ?? "",
    country: e.country ?? "",
    region: session?.subdivision1 || session?.region || "",
    city: e.city ?? "",
    browser: e.browser ?? "",
    os: e.os ?? "",
    device: e.device ?? "",
    screen: session?.screen ?? "",
    language: session?.language ?? "",
  };
}

/**
 * Writes one imported pageview or event as part of a Runlight visit. Visitors
 * are hashed per day from the hit's key, as live visitors are hashed per day,
 * and a hit within thirty minutes of the visitor's last one joins that visit.
 * Ids come from `ns` and the key, so importing the same rows again makes the
 * same ids. Returns whether it started a new visit.
 */
async function writeEvent(store: SqlStore, site: { id: string; hostnames: string[]; timezone: string }, ns: string, e: ImportedHit): Promise<boolean> {
  // The site's own day, as live visitors are counted, so days add up the same way in rollups.
  const day = localDate(e.ts, site.timezone);
  const visitor = await hexId(`${ns}:${e.key}:${day}`, 16);
  // A visit that runs past midnight keeps the id it started with, as a live one does.
  const yesterday = await hexId(`${ns}:${e.key}:${addDays(day, -1)}`, 16);
  const host = (e.hostname || site.hostnames[0] || "imported.invalid").toLowerCase();
  let page;
  try {
    page = parsePage(new URL(`https://${host}${e.path || "/"}${e.query ? `?${e.query.replace(/^\?/, "")}` : ""}`));
  } catch {
    page = parsePage(new URL(`https://${host}/`));
  }
  const open = await store.openSession(site.id, [visitor, yesterday], e.ts - SESSION_IDLE_MS);
  let id = open?.id;
  if (!id) {
    id = await hexId(`${ns}:${e.key}:${e.ts}`);
    await store.db.run(`DELETE FROM rl_sessions WHERE id = ?`, [id]);
    const referrer = e.referrer;
    const country = (e.country || "").toUpperCase().slice(0, 2);
    const rawRegion = e.region;
    const region = rawRegion ? (rawRegion.includes("-") ? rawRegion : `${country}-${rawRegion}`).toUpperCase().slice(0, 10) : "";
    await store.insertSession({
      id,
      site: site.id,
      visitor,
      startedAt: e.ts,
      hostname: page.hostname,
      ...attribute(page, referrer, site.hostnames),
      utmSource: page.utm.source,
      utmMedium: page.utm.medium,
      utmCampaign: page.utm.campaign,
      utmTerm: page.utm.term,
      utmContent: page.utm.content,
      country: /^[A-Z]{2}$/.test(country) ? country : "",
      region: /^[A-Z]{2}$/.test(country) ? region : "",
      city: (e.city || "").slice(0, 100),
      browser: browserName(e.browser || ""),
      browserVersion: "",
      os: systemName(e.os || ""),
      osVersion: "",
      device: deviceName(e.device || ""),
      screen: e.screen.slice(0, 20),
      language: e.language.slice(0, 35),
    });
    // No engaged time is known, so duration falls back to first-to-last pageview.
    await store.db.run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id]);
  }
  const kind = e.kind;
  await store.touchSession(id, e.ts, kind, page.path);
  await store.insertEvent({
    site: site.id,
    ts: e.ts,
    kind,
    // The visit's own visitor, which for one running past midnight is the id of the day it started.
    visitor: open?.visitor ?? visitor,
    session: id,
    pageview: "",
    path: page.path,
    hostname: page.hostname,
    title: kind === "pageview" ? e.title.slice(0, 300) : "",
    name: kind === "event" ? e.name.slice(0, 120) : "",
    props: null,
    engagedMs: 0,
    scroll: null,
    link: "",
  });
  return !open;
}

/**
 * One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from before
 * Runlight's own first visit, and within what the site keeps, are written. A batch can run again: its
 * time span is cleared first, so batches must not share a moment, which the dashboard sees to.
 */
export async function importCsvVisits(runlight: Runlight, siteId: string, rows: unknown): Promise<{ pageviews: number; events: number; visits: number; skipped: number }> {
  await runlight.init();
  if (!runlight.site(siteId)) throw new ImportError("Unknown site", "unknown_site");
  if (!Array.isArray(rows) || rows.length > CSV_BATCH) throw new ImportError(`Send at most ${CSV_BATCH} rows at a time`, "import_csv_batch", { max: String(CSV_BATCH) });
  const clean = rows.map((r) =>
    Object.fromEntries(Object.entries(r && typeof r === "object" ? (r as Record<string, unknown>) : {}).map(([k, v]) => [k.trim().toLowerCase(), String(v ?? "")])),
  );
  const format = csvFormat(Object.keys(clean[0] ?? {}));
  if (!format) throw new ImportError("This CSV is not an Umami export or Runlight's visit format", "import_csv_format");
  const cutoff = (await runlight.retentionCutoff(siteId)) ?? 0;
  const end = Math.min((await runlight.store.firstOwnVisit(siteId)) ?? Infinity, runlight.now());
  const hits = clean
    .map((row) => csvHit(row, format))
    .filter((h): h is NonNullable<typeof h> => h !== null && h.hit.ts >= cutoff && h.hit.ts < end)
    .sort((a, b) => a.hit.ts - b.hit.ts);
  const skipped = clean.length - hits.length;
  if (!hits.length) return { pageviews: 0, events: 0, visits: 0, skipped };
  const counts = await writeStep(runlight, siteId, hits[0]!.hit.ts, hits[hits.length - 1]!.hit.ts + 1, hits);
  return { ...counts, skipped };
}
