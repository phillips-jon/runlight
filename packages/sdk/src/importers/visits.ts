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
import { BROWSERS, DEVICES, SYSTEMS, hexId, title } from "./write.js";

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
    const resumed = Number((await runlight.store.setting(progressKey(siteId, website))) ?? 0);
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

  const counts = { pageviews: 0, events: 0, visits: 0 };
  const visits = events
    .filter((e) => e.eventType === PAGEVIEW || (e.eventType === CUSTOM_EVENT && e.eventName))
    .map((e) => ({ ...e, ts: Date.parse(e.createdAt) }))
    .filter((e) => Number.isFinite(e.ts) && e.ts < state.end)
    .sort((a, b) => a.ts - b.ts);
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
    for (const e of visits) {
      const made = await writeEvent(store, site, website, e, info.get(e.sessionId));
      if (made) counts.visits++;
      if (e.eventType === PAGEVIEW) counts.pageviews++;
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
    await store.setSetting(progressKey(siteId, website), String(to));
  });

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
 * Writes one Umami event as part of a Runlight visit. Visitors are hashed
 * per day from Umami's session id, as live visitors are hashed per day, and
 * an event within thirty minutes of the visitor's last one joins that visit.
 * Returns whether it started a new visit.
 */
async function writeEvent(store: SqlStore, site: { id: string; hostnames: string[]; timezone: string }, website: string, e: UmamiEvent & { ts: number }, session: UmamiSession | undefined): Promise<boolean> {
  // The site's own day, as live visitors are counted, so days add up the same way in rollups.
  const day = localDate(e.ts, site.timezone);
  const visitor = await hexId(`umami-visits:${website}:${e.sessionId}:${day}`, 16);
  // A visit that runs past midnight keeps the id it started with, as a live one does.
  const yesterday = await hexId(`umami-visits:${website}:${e.sessionId}:${addDays(day, -1)}`, 16);
  const host = (e.hostname || site.hostnames[0] || "imported.invalid").toLowerCase();
  let page;
  try {
    page = parsePage(new URL(`https://${host}${e.urlPath || "/"}${e.urlQuery ? `?${e.urlQuery.replace(/^\?/, "")}` : ""}`));
  } catch {
    page = parsePage(new URL(`https://${host}/`));
  }
  const open = await store.openSession(site.id, [visitor, yesterday], e.ts - SESSION_IDLE_MS);
  let id = open?.id;
  if (!id) {
    id = await hexId(`umami-visits:${website}:${e.sessionId}:${e.ts}`);
    await store.db.run(`DELETE FROM rl_sessions WHERE id = ?`, [id]);
    const referrer = e.referrerDomain ? `https://${e.referrerDomain}${e.referrerPath || "/"}${e.referrerQuery ? `?${e.referrerQuery.replace(/^\?/, "")}` : ""}` : "";
    const country = (e.country || "").toUpperCase().slice(0, 2);
    const rawRegion = session?.subdivision1 || session?.region || "";
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
      browser: BROWSERS[(e.browser || "").toLowerCase()] ?? title(e.browser || ""),
      browserVersion: "",
      os: SYSTEMS[(e.os || "").toLowerCase()] ?? e.os ?? "",
      osVersion: "",
      device: DEVICES[(e.device || "").toLowerCase()] ?? "",
      screen: session?.screen ?? "",
      language: session?.language ?? "",
    });
    // No engaged time is known, so duration falls back to first-to-last pageview.
    await store.db.run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", [id]);
  }
  const kind = e.eventType === PAGEVIEW ? "pageview" : "event";
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
    title: kind === "pageview" ? (e.pageTitle || "").slice(0, 300) : "",
    name: kind === "event" ? (e.eventName || "").slice(0, 120) : "",
    props: null,
    engagedMs: 0,
    scroll: null,
    link: "",
  });
  return !open;
}
