import {
  EVENT_DIMENSIONS,
  SESSION_DIMENSIONS,
  isEventDimension,
  isSessionDimension,
  type Dimension,
  type Filter,
  type Query,
} from "./query.js";

/**
 * The little a store needs from a database driver. SQL uses `?` placeholders;
 * the Postgres driver numbers them.
 */
export interface Db {
  dialect: "sqlite" | "postgres";
  all<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>;
  run(sql: string, params?: unknown[]): Promise<void>;
  close?(): Promise<void>;
}

export interface SiteRow {
  id: string;
  name: string;
  hostnames: string[];
  timezone: string;
}

export interface SessionRow {
  id: string;
  site: string;
  visitor: string;
  startedAt: number;
  hostname: string;
  referrerHost: string;
  referrerPath: string;
  source: string;
  channel: string;
  utmSource: string;
  utmMedium: string;
  utmCampaign: string;
  utmTerm: string;
  utmContent: string;
  country: string;
  region: string;
  city: string;
  browser: string;
  browserVersion: string;
  os: string;
  osVersion: string;
  device: string;
  screen: string;
  language: string;
}

export interface EventRow {
  site: string;
  ts: number;
  kind: "pageview" | "event" | "engagement" | "click" | "fetch";
  visitor: string;
  session: string;
  pageview: string;
  path: string;
  hostname: string;
  title: string;
  name: string;
  props: Record<string, string> | null;
  engagedMs: number;
  scroll: number | null;
  link: string;
}

export interface Stats {
  visitors: number;
  visits: number;
  pageviews: number;
  viewsPerVisit: number;
  /** 0 to 1. */
  bounceRate: number;
  /** Median, milliseconds. */
  visitDuration: number;
}

export interface Bucket {
  start: number;
  end: number;
}

export interface SeriesPoint {
  start: number;
  visitors: number;
  visits: number;
  pageviews: number;
}

export interface BreakdownRow {
  value: string;
  visitors: number;
  visits?: number;
  pageviews?: number;
  events?: number;
  bounceRate?: number;
  /** Mean engaged time per pageview, milliseconds, for pages. */
  timeOnPage?: number;
  fetches?: number;
}

export interface Realtime {
  visitors: number;
  pages: Array<{ value: string; visitors: number }>;
  sources: Array<{ value: string; visitors: number }>;
  /** Pageviews per minute for the last 30 minutes, oldest first. */
  minutes: number[];
}

/** A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged. */
export const BOUNCE_MS = 10_000;
const BOUNCE = `(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < ${BOUNCE_MS}))`;
const VISIT_KINDS = "e.kind IN ('pageview', 'event')";

const SCHEMA_VERSION = 1;

function schema(dialect: Db["dialect"]): string[] {
  const id = dialect === "postgres" ? "BIGSERIAL PRIMARY KEY" : "INTEGER PRIMARY KEY AUTOINCREMENT";
  const text = "TEXT NOT NULL DEFAULT ''";
  return [
    `CREATE TABLE IF NOT EXISTS rl_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS rl_sites (
      id TEXT PRIMARY KEY, name ${text}, hostnames TEXT NOT NULL DEFAULT '[]',
      timezone TEXT NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS rl_salts (day TEXT PRIMARY KEY, salt TEXT NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS rl_sessions (
      id TEXT PRIMARY KEY, site TEXT NOT NULL, visitor TEXT NOT NULL,
      started_at BIGINT NOT NULL, last_at BIGINT NOT NULL,
      entry_path ${text}, exit_path ${text},
      pageviews INTEGER NOT NULL DEFAULT 0, events INTEGER NOT NULL DEFAULT 0,
      engaged_ms BIGINT, imported INTEGER NOT NULL DEFAULT 0,
      hostname ${text}, referrer_host ${text}, referrer_path ${text},
      source ${text}, channel ${text},
      utm_source ${text}, utm_medium ${text}, utm_campaign ${text}, utm_term ${text}, utm_content ${text},
      country ${text}, region ${text}, city ${text},
      browser ${text}, browser_version ${text}, os ${text}, os_version ${text},
      device ${text}, screen ${text}, language ${text})`,
    `CREATE INDEX IF NOT EXISTS rl_sessions_site_started ON rl_sessions (site, started_at)`,
    `CREATE INDEX IF NOT EXISTS rl_sessions_visitor ON rl_sessions (site, visitor, last_at)`,
    `CREATE TABLE IF NOT EXISTS rl_events (
      id ${id}, site TEXT NOT NULL, ts BIGINT NOT NULL, kind TEXT NOT NULL,
      visitor ${text}, session ${text}, pageview ${text},
      path ${text}, hostname ${text}, title ${text}, name ${text}, props TEXT,
      engaged_ms BIGINT NOT NULL DEFAULT 0, scroll INTEGER, link ${text})`,
    `CREATE INDEX IF NOT EXISTS rl_events_site_ts ON rl_events (site, ts)`,
    `CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (site, pageview)`,
  ];
}

const num = (value: unknown): number => {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
};

const escapeLike = (value: string): string => value.replace(/[\\%_]/g, (c) => `\\${c}`);

function column(dimension: Filter["dimension"]): string {
  return isSessionDimension(dimension) ? `s.${SESSION_DIMENSIONS[dimension]}` : `e.${EVENT_DIMENSIONS[dimension]}`;
}

/** WHERE fragments for a query's filters, and whether they need the sessions table. */
function filterSql(filters: Filter[]): { sql: string; params: unknown[]; needsSession: boolean } {
  const parts: string[] = [];
  const params: unknown[] = [];
  let needsSession = false;
  for (const filter of filters) {
    if (isSessionDimension(filter.dimension)) needsSession = true;
    const col = column(filter.dimension);
    if (filter.op === "is") parts.push(`${col} = ?`);
    else if (filter.op === "not") parts.push(`${col} <> ?`);
    else parts.push(`LOWER(${col}) LIKE ? ESCAPE '\\'`);
    params.push(filter.op === "contains" ? `%${escapeLike(filter.value.toLowerCase())}%` : filter.value);
  }
  return { sql: parts.map((p) => ` AND ${p}`).join(""), params, needsSession };
}

export class SqlStore {
  private ready: Promise<void> | null = null;

  constructor(readonly db: Db) {}

  /** Creates the tables on first use. Safe to call any number of times. */
  migrate(): Promise<void> {
    this.ready ??= (async () => {
      for (const statement of schema(this.db.dialect)) await this.db.run(statement);
      await this.db.run(
        `INSERT INTO rl_meta (key, value) VALUES ('schema', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
        [String(SCHEMA_VERSION)],
      );
    })().catch((error) => {
      this.ready = null;
      throw error;
    });
    return this.ready;
  }

  async close(): Promise<void> {
    await this.db.close?.();
  }

  // Sites

  async upsertSite(site: SiteRow, now: number): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_sites (id, name, hostnames, timezone, created_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, hostnames = excluded.hostnames, timezone = excluded.timezone`,
      [site.id, site.name, JSON.stringify(site.hostnames), site.timezone, now],
    );
  }

  async sites(): Promise<SiteRow[]> {
    const rows = await this.db.all<{ id: string; name: string; hostnames: string; timezone: string }>(
      `SELECT id, name, hostnames, timezone FROM rl_sites ORDER BY name, id`,
    );
    return rows.map((row) => ({ ...row, hostnames: JSON.parse(row.hostnames) as string[] }));
  }

  // Salts

  /** The salt for a day, made on first ask. Two racing callers agree on one. */
  async salt(day: string, fresh: string): Promise<string> {
    await this.db.run(`INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING`, [day, fresh]);
    const rows = await this.db.all<{ salt: string }>(`SELECT salt FROM rl_salts WHERE day = ?`, [day]);
    return rows[0]?.salt ?? fresh;
  }

  async saltIfExists(day: string): Promise<string | null> {
    const rows = await this.db.all<{ salt: string }>(`SELECT salt FROM rl_salts WHERE day = ?`, [day]);
    return rows[0]?.salt ?? null;
  }

  /** Deletes every salt older than `day`, so old hashes can never be recomputed. */
  async dropSaltsBefore(day: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_salts WHERE day < ?`, [day]);
  }

  // Ingest

  /** The visitor's open session: any of their hashes, active since `since`. */
  async openSession(site: string, visitors: string[], since: number): Promise<{ id: string; visitor: string } | null> {
    if (visitors.length === 0) return null;
    const rows = await this.db.all<{ id: string; visitor: string }>(
      `SELECT id, visitor FROM rl_sessions WHERE site = ? AND visitor IN (${visitors.map(() => "?").join(", ")}) AND last_at >= ?
       ORDER BY last_at DESC LIMIT 1`,
      [site, ...visitors, since],
    );
    return rows[0] ?? null;
  }

  async insertSession(row: SessionRow): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, engaged_ms, hostname, referrer_host, referrer_path,
        source, channel, utm_source, utm_medium, utm_campaign, utm_term, utm_content, country, region, city,
        browser, browser_version, os, os_version, device, screen, language)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.id, row.site, row.visitor, row.startedAt, row.startedAt, row.hostname, row.referrerHost, row.referrerPath,
        row.source, row.channel, row.utmSource, row.utmMedium, row.utmCampaign, row.utmTerm, row.utmContent,
        row.country, row.region, row.city, row.browser, row.browserVersion, row.os, row.osVersion, row.device,
        row.screen, row.language,
      ],
    );
  }

  async touchSession(id: string, ts: number, kind: "pageview" | "event", path: string): Promise<void> {
    if (kind === "pageview") {
      await this.db.run(
        `UPDATE rl_sessions SET pageviews = pageviews + 1, last_at = ?, exit_path = ?,
           entry_path = CASE WHEN entry_path = '' THEN ? ELSE entry_path END WHERE id = ?`,
        [ts, path, path, id],
      );
    } else {
      await this.db.run(`UPDATE rl_sessions SET events = events + 1, last_at = ? WHERE id = ?`, [ts, id]);
    }
  }

  async addEngagement(id: string, ms: number): Promise<void> {
    await this.db.run(`UPDATE rl_sessions SET engaged_ms = COALESCE(engaged_ms, 0) + ? WHERE id = ?`, [ms, id]);
  }

  /** The pageview an engagement ping or event belongs to. */
  async pageview(site: string, pageview: string): Promise<{ session: string; visitor: string; path: string; hostname: string } | null> {
    const rows = await this.db.all<{ session: string; visitor: string; path: string; hostname: string }>(
      `SELECT session, visitor, path, hostname FROM rl_events WHERE site = ? AND pageview = ? AND kind = 'pageview' LIMIT 1`,
      [site, pageview],
    );
    return rows[0] ?? null;
  }

  async insertEvent(row: EventRow): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname, title, name, props, engaged_ms, scroll, link)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.site, row.ts, row.kind, row.visitor, row.session, row.pageview, row.path, row.hostname, row.title,
        row.name, row.props ? JSON.stringify(row.props) : null, row.engagedMs, row.scroll, row.link,
      ],
    );
  }

  // Reports

  /** When the site's first visit was recorded, or null with no data yet. */
  async firstSeen(site: string): Promise<number | null> {
    const [row] = await this.db.all(`SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?`, [site]);
    return row?.t === null || row?.t === undefined ? null : num(row.t);
  }

  async stats(query: Query): Promise<Stats> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const scope = `FROM rl_events e ${join} WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql}`;
    const params = [query.site, query.from, query.to, ...f.params];

    const [totals] = await this.db.all(
      `SELECT COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits,
         SUM(CASE WHEN e.kind = 'pageview' THEN 1 ELSE 0 END) AS pageviews ${scope}`,
      params,
    );
    const sessions = `FROM rl_sessions s WHERE s.id IN (SELECT DISTINCT e.session ${scope})`;
    const [bounces] = await this.db.all(`SELECT COUNT(*) AS n, SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced ${sessions}`, params);
    const n = num(bounces?.n);
    let visitDuration = 0;
    if (n > 0) {
      const [median] = await this.db.all(
        `SELECT COALESCE(s.engaged_ms, s.last_at - s.started_at) AS d ${sessions} ORDER BY d LIMIT 1 OFFSET ?`,
        [...params, Math.floor((n - 1) / 2)],
      );
      visitDuration = num(median?.d);
    }

    const visits = num(totals?.visits);
    const pageviews = num(totals?.pageviews);
    return {
      visitors: num(totals?.visitors),
      visits,
      pageviews,
      viewsPerVisit: visits > 0 ? Math.round((pageviews / visits) * 100) / 100 : 0,
      bounceRate: n > 0 ? num(bounces?.bounced) / n : 0,
      visitDuration,
    };
  }

  async series(query: Omit<Query, "from" | "to">, buckets: Bucket[]): Promise<SeriesPoint[]> {
    if (buckets.length === 0) return [];
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const cast = this.db.dialect === "postgres";
    const values = buckets
      .map((_, i) => (cast && i === 0 ? "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))" : "(?, ?, ?)"))
      .join(", ");
    const params: unknown[] = buckets.flatMap((b, i) => [i, b.start, b.end]);
    const rows = await this.db.all<{ i: unknown; visitors: unknown; visits: unknown; pageviews: unknown }>(
      `WITH b (i, bs, be) AS (VALUES ${values})
       SELECT b.i AS i, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits,
         SUM(CASE WHEN e.kind = 'pageview' THEN 1 ELSE 0 END) AS pageviews
       FROM b JOIN rl_events e ON e.site = ? AND e.ts >= b.bs AND e.ts < b.be ${join}
       WHERE ${VISIT_KINDS}${f.sql}
       GROUP BY b.i`,
      [...params, query.site, ...f.params],
    );
    const found = new Map(rows.map((row) => [num(row.i), row]));
    return buckets.map((bucket, i) => {
      const row = found.get(i);
      return { start: bucket.start, visitors: num(row?.visitors), visits: num(row?.visits), pageviews: num(row?.pageviews) };
    });
  }

  async breakdown(query: Query, dimension: Dimension, limit: number, offset: number): Promise<BreakdownRow[]> {
    const page = [limit, offset];
    if (dimension === "ai_agent" || dimension === "ai_page") {
      const col = dimension === "ai_agent" ? "e.name" : "e.path";
      const rows = await this.db.all(
        `SELECT ${col} AS value, COUNT(*) AS fetches FROM rl_events e
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'fetch'
         GROUP BY ${col} ORDER BY fetches DESC, value LIMIT ? OFFSET ?`,
        [query.site, query.from, query.to, ...page],
      );
      return rows.map((row) => ({ value: String(row.value), visitors: 0, fetches: num(row.fetches) }));
    }

    const f = filterSql(query.filters);
    const params = [query.site, query.from, query.to, ...f.params];
    const sessionJoin = "JOIN rl_sessions s ON s.id = e.session";

    if (dimension === "entry" || dimension === "exit") {
      const col = `s.${SESSION_DIMENSIONS[dimension]}`;
      const rows = await this.db.all(
        `SELECT ${col} AS value, COUNT(DISTINCT s.visitor) AS visitors, COUNT(*) AS visits,
           SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced
         FROM rl_sessions s WHERE s.id IN (
           SELECT DISTINCT e.session FROM rl_events e ${sessionJoin}
           WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql})
         AND ${col} <> ''
         GROUP BY ${col} ORDER BY visits DESC, value LIMIT ? OFFSET ?`,
        [...params, ...page],
      );
      return rows.map((row) => ({
        value: String(row.value),
        visitors: num(row.visitors),
        visits: num(row.visits),
        bounceRate: num(row.visits) > 0 ? num(row.bounced) / num(row.visits) : 0,
      }));
    }

    if (dimension === "page" || dimension === "hostname") {
      const col = `e.${EVENT_DIMENSIONS[dimension]}`;
      const join = f.needsSession ? sessionJoin : "";
      const rows = await this.db.all(
        `SELECT ${col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS pageviews
         FROM rl_events e ${join}
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'pageview'${f.sql}
         GROUP BY ${col} ORDER BY visitors DESC, pageviews DESC, value LIMIT ? OFFSET ?`,
        [...params, ...page],
      );
      const out: BreakdownRow[] = rows.map((row) => ({ value: String(row.value), visitors: num(row.visitors), pageviews: num(row.pageviews) }));
      if (dimension === "page" && out.length > 0) {
        const times = await this.db.all(
          `SELECT e.path AS value, SUM(e.engaged_ms) AS total, COUNT(DISTINCT e.pageview) AS views
           FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'
           AND e.path IN (${out.map(() => "?").join(", ")}) GROUP BY e.path`,
          [query.site, query.from, query.to, ...out.map((row) => row.value)],
        );
        const byPath = new Map(times.map((t) => [String(t.value), num(t.views) > 0 ? num(t.total) / num(t.views) : 0]));
        for (const row of out) row.timeOnPage = Math.round(byPath.get(row.value) ?? 0);
      }
      return out;
    }

    if (dimension === "event") {
      const join = f.needsSession ? sessionJoin : "";
      const rows = await this.db.all(
        `SELECT e.name AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(*) AS events
         FROM rl_events e ${join}
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event'${f.sql}
         GROUP BY e.name ORDER BY visitors DESC, events DESC, value LIMIT ? OFFSET ?`,
        [...params, ...page],
      );
      return rows.map((row) => ({ value: String(row.value), visitors: num(row.visitors), events: num(row.events) }));
    }

    if (!isSessionDimension(dimension) || isEventDimension(dimension)) return [];
    const col = `s.${SESSION_DIMENSIONS[dimension]}`;
    const rows = await this.db.all(
      `SELECT ${col} AS value, COUNT(DISTINCT e.visitor) AS visitors, COUNT(DISTINCT e.session) AS visits,
         SUM(CASE WHEN e.kind = 'pageview' THEN 1 ELSE 0 END) AS pageviews
       FROM rl_events e ${sessionJoin}
       WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql} AND ${col} <> ''
       GROUP BY ${col} ORDER BY visitors DESC, visits DESC, value LIMIT ? OFFSET ?`,
      [...params, ...page],
    );
    return rows.map((row) => ({
      value: String(row.value),
      visitors: num(row.visitors),
      visits: num(row.visits),
      pageviews: num(row.pageviews),
    }));
  }

  async realtime(site: string, now: number): Promise<Realtime> {
    const since = now - 5 * 60_000;
    const [active] = await this.db.all(
      `SELECT COUNT(DISTINCT visitor) AS n FROM rl_events WHERE site = ? AND ts >= ? AND kind IN ('pageview', 'event', 'engagement')`,
      [site, since],
    );
    const pages = await this.db.all(
      `SELECT path AS value, COUNT(DISTINCT visitor) AS visitors FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY path ORDER BY visitors DESC, value LIMIT 10`,
      [site, since],
    );
    const sources = await this.db.all(
      `SELECT s.source AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.source <> ''
       GROUP BY s.source ORDER BY visitors DESC, value LIMIT 10`,
      [site, since],
    );
    const start = Math.floor(now / 60_000) * 60_000 - 29 * 60_000;
    const perMinute = await this.db.all(
      `SELECT (ts - ?) / 60000 AS m, COUNT(*) AS n FROM rl_events
       WHERE site = ? AND ts >= ? AND kind = 'pageview' GROUP BY 1`,
      [start, site, start],
    );
    const minutes = new Array<number>(30).fill(0);
    for (const row of perMinute) {
      const index = Math.floor(num(row.m));
      if (index >= 0 && index < 30) minutes[index] = (minutes[index] ?? 0) + num(row.n);
    }
    const pairs = (rows: Record<string, unknown>[]) => rows.map((row) => ({ value: String(row.value), visitors: num(row.visitors) }));
    return { visitors: num(active?.n), pages: pairs(pages), sources: pairs(sources), minutes };
  }
}
