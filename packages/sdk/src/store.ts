import {
  EVENT_DIMENSIONS,
  SESSION_DIMENSIONS,
  isEventDimension,
  isSessionDimension,
  type Dimension,
  type Filter,
  type Query,
  type SessionDimension,
} from "./query.js";

/**
 * The little a store needs from a database driver. SQL uses `?` placeholders;
 * the Postgres driver numbers them.
 */
export interface Db {
  dialect: "sqlite" | "postgres";
  all<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>;
  run(sql: string, params?: unknown[]): Promise<void>;
  /**
   * Runs `fn` while holding a database-wide lock, so two processes starting
   * at once do not race to create the same tables. Optional: SQLite's file
   * lock already serialises its writers.
   */
  exclusive?<T>(fn: (db: Db) => Promise<T>): Promise<T>;
  /**
   * Runs `fn` in one transaction on one connection. Optional: without it the
   * store sends BEGIN and COMMIT itself, which is only safe when nothing else
   * can run on the connection meanwhile. A store with one shared connection
   * should wrap its Db in `oneConnection()`, which provides this.
   */
  transaction?<T>(fn: (db: Db) => Promise<T>): Promise<T>;
  close?(): Promise<void>;
}

/**
 * For a store with one connection shared by every request (SQLite through
 * better-sqlite3 or Bun). Statements and transactions take turns, so a
 * request's insert can never land inside an import's open transaction, and
 * a rollback can only undo the transaction's own writes.
 */
export function oneConnection(inner: Db): Db {
  let tail: Promise<unknown> = Promise.resolve();
  const turn = <T>(fn: () => Promise<T>): Promise<T> => {
    const result = tail.then(fn, fn);
    tail = result.catch(() => {});
    return result;
  };
  return {
    ...inner,
    all: (sql, params) => turn(() => inner.all(sql, params)),
    run: (sql, params) => turn(() => inner.run(sql, params)),
    // Statements inside the transaction use the connection directly; they already hold the turn.
    transaction: (fn) =>
      turn(async () => {
        await inner.run("BEGIN");
        try {
          const result = await fn(inner);
          await inner.run("COMMIT");
          return result;
        } catch (error) {
          await inner.run("ROLLBACK");
          throw error;
        }
      }),
  };
}

export interface SiteRow {
  id: string;
  name: string;
  hostnames: string[];
  timezone: string;
}

/** What the dashboard may change about a site. */
export interface SiteOverrides {
  name?: string;
  timezone?: string;
}

/**
 * Something worth counting. An event goal counts a named event; a page goal
 * counts pageviews of a path or pattern (`/thanks*`); a click goal is a rule
 * the tracker applies itself, sending an event named after the goal. Goals are
 * worked out when stats are read, so a new goal counts past visits too.
 */
export interface GoalRow {
  id: string;
  site: string;
  name: string;
  kind: "event" | "page" | "click";
  /** The event name, the path pattern, or for a click goal a CSS selector or URL pattern. */
  match: string;
  /** For click goals: what `match` is. */
  clickBy: "selector" | "link" | "";
  /** No money, the same amount each time, or the amount sent in an event property. */
  valueMode: "none" | "fixed" | "prop";
  value: number;
  valueProp: string;
  currency: string;
  createdAt: number;
}

/** Someone who gets a site's report by email. `token` is the unsubscribe key. */
export interface ReportRow {
  id: string;
  site: string;
  email: string;
  frequency: "weekly" | "monthly";
  lang: string;
  token: string;
  /** Where the dashboard lives, for the links in the email. */
  origin: string;
  /** The last period sent, like w:2026-09-28 or m:2026-09, so nothing goes out twice. */
  lastPeriod: string;
  lastSentAt: number | null;
  createdAt: number;
}

export interface GoalTotals {
  conversions: number;
  visitors: number;
  revenue: number;
}

/** A public, read-only view of one site's stats, opened by its unguessable id. */
export interface ShareRow {
  id: string;
  site: string;
  name: string;
  createdAt: number;
}

/** One step of a funnel: reaching a page (with * as a wildcard), or sending an event. */
export interface FunnelStep {
  kind: "page" | "event";
  match: string;
}

/** Steps a visit is expected to take in order, such as pricing, then signup, then the welcome page. */
export interface FunnelRow {
  id: string;
  site: string;
  name: string;
  steps: FunnelStep[];
  createdAt: number;
}

/** An API token. Only its hash is stored; the token itself is shown once. */
export interface TokenRow {
  id: string;
  name: string;
  /** "" reads every site; otherwise the one site it may read. */
  site: string;
  hash: string;
  /** The token's last four characters, so people can tell theirs apart. */
  hint: string;
  createdAt: number;
  lastUsedAt: number | null;
}

export interface LinkRow {
  id: string;
  site: string;
  /** A custom link domain, or "" for the app's own. */
  domain: string;
  slug: string;
  name: string;
  url: string;
  createdAt: number;
  updatedAt: number;
}

export interface LinkStats {
  clicks: number;
  visitors: number;
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
  /** Mean engaged time per visit, milliseconds. */
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
  /** Of the visits that started in this bucket. */
  viewsPerVisit: number;
  bounceRate: number;
  visitDuration: number;
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
  /** Mean deepest scroll, percent, for pages. */
  scrollDepth?: number;
  /** Mean engaged time per visit, milliseconds, for visit dimensions. */
  visitDuration?: number;
  fetches?: number;
}

export interface Realtime {
  visitors: number;
  pages: Array<{ value: string; visitors: number }>;
  sources: Array<{ value: string; visitors: number }>;
  countries: Array<{ value: string; visitors: number }>;
  /** Pageviews per minute for the last 30 minutes, oldest first. */
  minutes: number[];
  /** The latest pageviews and events, newest first: what happened, never who. */
  recent: Array<{ ts: number; kind: string; path: string; name: string; country: string; city: string; source: string; device: string }>;
}

/** A session's bounce: one page, nothing clicked that was tracked, under ten seconds engaged. */
export const BOUNCE_MS = 10_000;
const BOUNCE = `(s.pageviews = 1 AND s.events = 0 AND (s.engaged_ms IS NULL OR s.engaged_ms < ${BOUNCE_MS}))`;
const VISIT_KINDS = "e.kind IN ('pageview', 'event')";
/** Engaged time, or for imported visits with none, first to last request. */
const DURATION = "COALESCE(s.engaged_ms, s.last_at - s.started_at)";

const SCHEMA_VERSION = 9;

function schema(dialect: Db["dialect"]): string[] {
  const id = dialect === "postgres" ? "BIGSERIAL PRIMARY KEY" : "INTEGER PRIMARY KEY AUTOINCREMENT";
  const text = "TEXT NOT NULL DEFAULT ''";
  return [
    `CREATE TABLE IF NOT EXISTS rl_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS rl_sites (
      id TEXT PRIMARY KEY, name ${text}, hostnames TEXT NOT NULL DEFAULT '[]',
      timezone TEXT NOT NULL DEFAULT 'UTC', created_at BIGINT NOT NULL,
      overrides TEXT NOT NULL DEFAULT '{}')`,
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
    // Goals and events read one kind of row in a range; created on start for older databases too.
    `CREATE INDEX IF NOT EXISTS rl_events_site_kind_ts ON rl_events (site, kind, ts)`,
    `CREATE INDEX IF NOT EXISTS rl_events_pageview ON rl_events (site, pageview)`,
    // Version 3: short links; "" is the app's own domain. Version 4: a slug is unique
    // across every domain, so a link whose domain is removed can fall back to the
    // app's own link path without colliding with another.
    `CREATE TABLE IF NOT EXISTS rl_links (
      id TEXT PRIMARY KEY, site TEXT NOT NULL, domain ${text}, slug TEXT NOT NULL,
      name ${text}, url TEXT NOT NULL, created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
      deleted_at BIGINT)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS rl_links_slug_unique ON rl_links (slug) WHERE deleted_at IS NULL`,
    `CREATE INDEX IF NOT EXISTS rl_events_link ON rl_events (link, ts)`,
    `CREATE TABLE IF NOT EXISTS rl_link_domains (domain TEXT PRIMARY KEY, site TEXT NOT NULL, created_at BIGINT NOT NULL)`,
    // Version 5: share links.
    `CREATE TABLE IF NOT EXISTS rl_shares (id TEXT PRIMARY KEY, site TEXT NOT NULL, name ${text}, created_at BIGINT NOT NULL)`,
    // Version 6: goals.
    `CREATE TABLE IF NOT EXISTS rl_goals (
      id TEXT PRIMARY KEY, site TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, match TEXT NOT NULL,
      click_by ${text}, value_mode TEXT NOT NULL DEFAULT 'none', value REAL NOT NULL DEFAULT 0,
      value_prop ${text}, currency TEXT NOT NULL DEFAULT 'USD', created_at BIGINT NOT NULL)`,
    // Version 7: install-wide settings (the mail service) and email report subscriptions.
    `CREATE TABLE IF NOT EXISTS rl_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
    `CREATE TABLE IF NOT EXISTS rl_reports (
      id TEXT PRIMARY KEY, site TEXT NOT NULL, email TEXT NOT NULL, frequency TEXT NOT NULL,
      lang TEXT NOT NULL DEFAULT 'en', token TEXT NOT NULL, origin ${text},
      last_period ${text}, last_sent_at BIGINT, created_at BIGINT NOT NULL)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS rl_reports_token ON rl_reports (token)`,
    // Version 8: read-only API tokens, for scripts and AI assistants over MCP.
    `CREATE TABLE IF NOT EXISTS rl_tokens (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, site ${text}, hash TEXT NOT NULL, hint ${text},
      created_at BIGINT NOT NULL, last_used_at BIGINT)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS rl_tokens_hash ON rl_tokens (hash)`,
    // Version 9: funnels.
    `CREATE TABLE IF NOT EXISTS rl_funnels (id TEXT PRIMARY KEY, site TEXT NOT NULL, name TEXT NOT NULL, steps TEXT NOT NULL, created_at BIGINT NOT NULL)`,
  ];
}

function goalRow(r: Record<string, unknown>): GoalRow {
  return {
    id: String(r.id),
    site: String(r.site),
    name: String(r.name),
    kind: String(r.kind) as GoalRow["kind"],
    match: String(r.match),
    clickBy: String(r.click_by ?? "") as GoalRow["clickBy"],
    valueMode: String(r.value_mode) as GoalRow["valueMode"],
    value: Number(r.value ?? 0),
    valueProp: String(r.value_prop ?? ""),
    currency: String(r.currency ?? "USD"),
    createdAt: Number(r.created_at),
  };
}

/** A `*` pattern as SQLite GLOB, everything else taken literally ([ and ? are GLOB's own). */
const globPattern = (pattern: string): string => pattern.split("*").map((part) => part.replace(/[[?]/g, (c) => `[${c}]`)).join("*");

/** A `*` pattern as SQL LIKE, everything else taken literally. */
const likePattern = (pattern: string): string => pattern.split("*").map(escapeLike).join("%");

function linkRow(row: Record<string, unknown>): LinkRow {
  return {
    id: String(row.id),
    site: String(row.site),
    domain: String(row.domain ?? ""),
    slug: String(row.slug),
    name: String(row.name ?? ""),
    url: String(row.url),
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
  };
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
    const create = async (db: Db) => {
      await db.run(`CREATE TABLE IF NOT EXISTS rl_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`);
      const [found] = await db.all<{ value: string }>(`SELECT value FROM rl_meta WHERE key = 'schema'`);
      const from = found ? Number(found.value) : SCHEMA_VERSION;
      for (const statement of schema(db.dialect)) await db.run(statement);
      // Version 2: settings changed in the dashboard, kept apart from the ones in code.
      if (from < 2) await db.run(`ALTER TABLE rl_sites ADD COLUMN overrides TEXT NOT NULL DEFAULT '{}'`);
      if (from < 4) await db.run(`DROP INDEX IF EXISTS rl_links_slug`);
      await db.run(
        `INSERT INTO rl_meta (key, value) VALUES ('schema', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
        [String(SCHEMA_VERSION)],
      );
    };
    this.ready ??= (this.db.exclusive ? this.db.exclusive(create) : create(this.db)).catch((error) => {
      this.ready = null;
      throw error;
    });
    return this.ready;
  }

  async close(): Promise<void> {
    await this.db.close?.();
  }

  /** Runs `fn` with a store whose every query is in one transaction. */
  async transaction<T>(fn: (store: SqlStore) => Promise<T>): Promise<T> {
    if (this.db.transaction) return this.db.transaction((db) => fn(new SqlStore(db)));
    await this.db.run("BEGIN");
    try {
      const result = await fn(this);
      await this.db.run("COMMIT");
      return result;
    } catch (error) {
      await this.db.run("ROLLBACK");
      throw error;
    }
  }

  // Sites

  async upsertSite(site: SiteRow, now: number): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_sites (id, name, hostnames, timezone, created_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, hostnames = excluded.hostnames, timezone = excluded.timezone`,
      [site.id, site.name, JSON.stringify(site.hostnames), site.timezone, now],
    );
  }

  /** Settings changed in the dashboard, by site. They win over the ones in code. */
  async siteOverrides(): Promise<Map<string, SiteOverrides>> {
    const rows = await this.db.all<{ id: string; overrides: string }>(`SELECT id, overrides FROM rl_sites`);
    const out = new Map<string, SiteOverrides>();
    for (const row of rows) {
      try {
        out.set(row.id, JSON.parse(row.overrides) as SiteOverrides);
      } catch {
        out.set(row.id, {});
      }
    }
    return out;
  }

  /** Deletes a site and everything recorded for it. Used by the standalone server's "Delete site". */
  async deleteSite(id: string): Promise<void> {
    await this.transaction(async (store) => {
      for (const table of ["rl_events", "rl_sessions", "rl_links", "rl_link_domains", "rl_shares", "rl_goals", "rl_funnels", "rl_reports", "rl_tokens", "rl_sites"]) {
        await store.db.run(`DELETE FROM ${table} WHERE ${table === "rl_sites" ? "id" : "site"} = ?`, [id]);
      }
    });
  }

  async setSiteOverrides(id: string, overrides: SiteOverrides): Promise<void> {
    await this.db.run(`UPDATE rl_sites SET overrides = ? WHERE id = ?`, [JSON.stringify(overrides), id]);
  }

  /** When the site last recorded a visit, or null if it never has. */
  async lastSeen(site: string): Promise<number | null> {
    const [row] = await this.db.all(`SELECT MAX(ts) AS t FROM rl_events WHERE site = ? AND kind IN ('pageview', 'event')`, [site]);
    return row?.t === null || row?.t === undefined ? null : num(row.t);
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

  async touchSession(id: string, ts: number, kind: "pageview" | "event" | "click", path: string): Promise<void> {
    if (kind === "click") {
      await this.db.run(`UPDATE rl_sessions SET last_at = ? WHERE id = ?`, [ts, id]);
    } else if (kind === "pageview") {
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

  // Links

  /** The live link with a slug. Slugs are unique across every domain. */
  async linkBySlug(slug: string): Promise<LinkRow | null> {
    const rows = await this.db.all(`SELECT * FROM rl_links WHERE slug = ? AND deleted_at IS NULL LIMIT 1`, [slug]);
    return rows[0] ? linkRow(rows[0]) : null;
  }

  async linkById(id: string): Promise<LinkRow | null> {
    const rows = await this.db.all(`SELECT * FROM rl_links WHERE id = ? AND deleted_at IS NULL LIMIT 1`, [id]);
    return rows[0] ? linkRow(rows[0]) : null;
  }

  async insertLink(link: LinkRow): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_links (id, site, domain, slug, name, url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [link.id, link.site, link.domain, link.slug, link.name, link.url, link.createdAt, link.updatedAt],
    );
  }

  async updateLink(link: LinkRow): Promise<void> {
    await this.db.run(`UPDATE rl_links SET domain = ?, slug = ?, name = ?, url = ?, updated_at = ? WHERE id = ?`, [
      link.domain, link.slug, link.name, link.url, link.updatedAt, link.id,
    ]);
  }

  /** Hides a link and frees its slug; its clicks stay in the history. */
  async deleteLink(id: string, now: number): Promise<void> {
    await this.db.run(`UPDATE rl_links SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL`, [now, id]);
  }

  // Shares

  async shares(site: string): Promise<ShareRow[]> {
    const rows = await this.db.all(`SELECT id, site, name, created_at FROM rl_shares WHERE site = ? ORDER BY created_at DESC`, [site]);
    return rows.map((r) => ({ id: String(r.id), site: String(r.site), name: String(r.name ?? ""), createdAt: Number(r.created_at) }));
  }

  async shareById(id: string): Promise<ShareRow | null> {
    const [r] = await this.db.all(`SELECT id, site, name, created_at FROM rl_shares WHERE id = ?`, [id]);
    return r ? { id: String(r.id), site: String(r.site), name: String(r.name ?? ""), createdAt: Number(r.created_at) } : null;
  }

  async insertShare(share: ShareRow): Promise<void> {
    await this.db.run(`INSERT INTO rl_shares (id, site, name, created_at) VALUES (?, ?, ?, ?)`, [share.id, share.site, share.name, share.createdAt]);
  }

  async renameShare(id: string, name: string): Promise<void> {
    await this.db.run(`UPDATE rl_shares SET name = ? WHERE id = ?`, [name, id]);
  }

  /** Deleting a share is how it is revoked: the link stops working at once. */
  async deleteShare(id: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_shares WHERE id = ?`, [id]);
  }

  // Funnels

  async funnels(site: string): Promise<FunnelRow[]> {
    const rows = await this.db.all(`SELECT * FROM rl_funnels WHERE site = ? ORDER BY created_at`, [site]);
    return rows.map((r) => ({ id: String(r.id), site: String(r.site), name: String(r.name), steps: JSON.parse(String(r.steps)) as FunnelStep[], createdAt: Number(r.created_at) }));
  }

  async saveFunnel(f: FunnelRow): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_funnels (id, site, name, steps, created_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, steps = excluded.steps`,
      [f.id, f.site, f.name, JSON.stringify(f.steps), f.createdAt],
    );
  }

  async deleteFunnel(id: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_funnels WHERE id = ?`, [id]);
  }

  /**
   * How many visits reached each step, in order, within the same visit. Step
   * one is the first matching row in the range; each later step must come
   * after the step before it. Filters choose which visits enter the funnel.
   */
  async funnelCounts(query: Query, funnel: FunnelRow): Promise<number[]> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    // A filter picks visits: those with any matching row, wherever it falls in the visit.
    const chosen = query.filters.length
      ? ` AND e.session IN (SELECT DISTINCT e.session FROM rl_events e ${join} WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql})`
      : "";
    const ctes: string[] = [];
    const params: unknown[] = [];
    funnel.steps.forEach((step, i) => {
      const scope = this.goalScope({ kind: step.kind, match: step.match, name: step.match } as GoalRow);
      if (i === 0) {
        ctes.push(
          `s0 AS (SELECT e.session AS session, MIN(e.ts) AS t FROM rl_events e
            WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.session <> '' AND ${scope.sql}${chosen} GROUP BY e.session)`,
        );
        params.push(query.site, query.from, query.to, ...scope.params, ...(query.filters.length ? [query.site, query.from, query.to, ...f.params] : []));
      } else {
        ctes.push(
          `s${i} AS (SELECT e.session AS session, MIN(e.ts) AS t FROM rl_events e JOIN s${i - 1} p ON p.session = e.session AND e.ts > p.t
            WHERE e.site = ? AND e.ts < ? AND ${scope.sql} GROUP BY e.session)`,
        );
        params.push(query.site, query.to, ...scope.params);
      }
    });
    const [row] = await this.db.all(
      `WITH ${ctes.join(", ")} SELECT ${funnel.steps.map((_, i) => `(SELECT COUNT(*) FROM s${i}) AS n${i}`).join(", ")}`,
      params,
    );
    return funnel.steps.map((_, i) => num(row?.[`n${i}`]));
  }

  // API tokens

  private tokenRow(r: Record<string, unknown>): TokenRow {
    return {
      id: String(r.id),
      name: String(r.name),
      site: String(r.site ?? ""),
      hash: String(r.hash),
      hint: String(r.hint ?? ""),
      createdAt: Number(r.created_at),
      lastUsedAt: r.last_used_at === null || r.last_used_at === undefined ? null : Number(r.last_used_at),
    };
  }

  async tokens(): Promise<TokenRow[]> {
    return (await this.db.all(`SELECT * FROM rl_tokens ORDER BY created_at DESC`)).map((r) => this.tokenRow(r));
  }

  async tokenByHash(hash: string): Promise<TokenRow | null> {
    const [row] = await this.db.all(`SELECT * FROM rl_tokens WHERE hash = ?`, [hash]);
    return row ? this.tokenRow(row) : null;
  }

  async insertToken(t: TokenRow): Promise<void> {
    await this.db.run(`INSERT INTO rl_tokens (id, name, site, hash, hint, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?)`, [
      t.id,
      t.name,
      t.site,
      t.hash,
      t.hint,
      t.createdAt,
      t.lastUsedAt,
    ]);
  }

  async touchToken(id: string, now: number): Promise<void> {
    await this.db.run(`UPDATE rl_tokens SET last_used_at = ? WHERE id = ?`, [now, id]);
  }

  /** Deleting a token is how it is revoked: it stops working at once. */
  async deleteToken(id: string): Promise<boolean> {
    const rows = await this.db.all(`DELETE FROM rl_tokens WHERE id = ? RETURNING id`, [id]);
    return rows.length === 1;
  }

  // Settings

  async setting(key: string): Promise<string | null> {
    const [row] = await this.db.all(`SELECT value FROM rl_settings WHERE key = ?`, [key]);
    return row ? String(row.value) : null;
  }

  async setSetting(key: string, value: string | null): Promise<void> {
    if (value === null) await this.db.run(`DELETE FROM rl_settings WHERE key = ?`, [key]);
    else await this.db.run(`INSERT INTO rl_settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, [key, value]);
  }

  // Email reports

  private reportRow(r: Record<string, unknown>): ReportRow {
    return {
      id: String(r.id),
      site: String(r.site),
      email: String(r.email),
      frequency: String(r.frequency) as ReportRow["frequency"],
      lang: String(r.lang ?? "en"),
      token: String(r.token),
      origin: String(r.origin ?? ""),
      lastPeriod: String(r.last_period ?? ""),
      lastSentAt: r.last_sent_at === null || r.last_sent_at === undefined ? null : Number(r.last_sent_at),
      createdAt: Number(r.created_at),
    };
  }

  async reports(site?: string): Promise<ReportRow[]> {
    const rows = site
      ? await this.db.all(`SELECT * FROM rl_reports WHERE site = ? ORDER BY created_at`, [site])
      : await this.db.all(`SELECT * FROM rl_reports ORDER BY created_at`);
    return rows.map((r) => this.reportRow(r));
  }

  async reportBy(field: "id" | "token", value: string): Promise<ReportRow | null> {
    const [row] = await this.db.all(`SELECT * FROM rl_reports WHERE ${field === "id" ? "id" : "token"} = ?`, [value]);
    return row ? this.reportRow(row) : null;
  }

  async insertReport(r: ReportRow): Promise<void> {
    await this.db.run(
      `INSERT INTO rl_reports (id, site, email, frequency, lang, token, origin, last_period, last_sent_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [r.id, r.site, r.email, r.frequency, r.lang, r.token, r.origin, r.lastPeriod, r.lastSentAt, r.createdAt],
    );
  }

  /** Records a period as sent. Only one caller wins, so two cron runs at once cannot both send it. */
  async claimReport(id: string, period: string, now: number): Promise<boolean> {
    // One statement, so of two cron runs at once only one gets the row back.
    const rows = await this.db.all(
      `UPDATE rl_reports SET last_period = ?, last_sent_at = ? WHERE id = ? AND last_period <> ? RETURNING id`,
      [period, now, id, period],
    );
    return rows.length === 1;
  }

  /** Puts a period back when its email failed, so the next run tries again. */
  async releaseReport(id: string, period: string, previous: string): Promise<void> {
    await this.db.run(`UPDATE rl_reports SET last_period = ? WHERE id = ? AND last_period = ?`, [previous, id, period]);
  }

  async deleteReport(id: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_reports WHERE id = ?`, [id]);
  }

  // Goals

  async goals(site?: string): Promise<GoalRow[]> {
    const rows = site
      ? await this.db.all(`SELECT * FROM rl_goals WHERE site = ? ORDER BY created_at`, [site])
      : await this.db.all(`SELECT * FROM rl_goals ORDER BY created_at`);
    return rows.map(goalRow);
  }

  async goalById(id: string): Promise<GoalRow | null> {
    const [row] = await this.db.all(`SELECT * FROM rl_goals WHERE id = ?`, [id]);
    return row ? goalRow(row) : null;
  }

  async saveGoal(g: GoalRow, before?: GoalRow): Promise<void> {
    // A click goal is counted by its name, which the tracker sends as the event
    // name. Renaming one renames its past clicks too, so its history stays.
    if (before?.kind === "click" && g.kind === "click" && before.name !== g.name) {
      await this.db.run(`UPDATE rl_events SET name = ? WHERE site = ? AND kind = 'event' AND name = ?`, [g.name, g.site, before.name]);
    }
    await this.db.run(
      `INSERT INTO rl_goals (id, site, name, kind, match, click_by, value_mode, value, value_prop, currency, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, kind = excluded.kind, match = excluded.match,
         click_by = excluded.click_by, value_mode = excluded.value_mode, value = excluded.value,
         value_prop = excluded.value_prop, currency = excluded.currency`,
      [g.id, g.site, g.name, g.kind, g.match, g.clickBy, g.valueMode, g.value, g.valueProp, g.currency, g.createdAt],
    );
  }

  async deleteGoal(id: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_goals WHERE id = ?`, [id]);
  }

  /** The events a goal counts, as a WHERE fragment over rl_events e. */
  private goalScope(goal: GoalRow): { sql: string; params: unknown[] } {
    if (goal.kind === "page") {
      return goal.match.includes("*")
        ? this.db.dialect === "postgres"
          ? { sql: `e.kind = 'pageview' AND e.path LIKE ? ESCAPE '\\'`, params: [likePattern(goal.match)] }
          : // SQLite's LIKE ignores case; GLOB does not, so both databases agree with each other and with exact matches.
            { sql: `e.kind = 'pageview' AND e.path GLOB ?`, params: [globPattern(goal.match)] }
        : { sql: `e.kind = 'pageview' AND e.path = ?`, params: [goal.match] };
    }
    // Event goals count the named event; click goals count the event the tracker sends for them.
    return { sql: `e.kind = 'event' AND e.name = ?`, params: [goal.kind === "click" ? goal.name : goal.match] };
  }

  /** A numeric event property for one row, as SQL (0 when it is not a number). Property names are checked before they get here. */
  private propValue(prop: string): { sql: string; params: unknown[] } {
    if (this.db.dialect === "postgres") {
      return {
        sql: `(CASE WHEN (e.props::jsonb ->> ?) ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (e.props::jsonb ->> ?)::numeric ELSE 0 END)`,
        params: [prop, prop],
      };
    }
    // As Postgres's pattern: a JSON number, or text of digits with an optional sign and one decimal point.
    const path = `$."${prop}"`;
    const text = `CAST(json_extract(e.props, ?) AS TEXT)`;
    return {
      sql: `(CASE
        WHEN json_type(e.props, ?) IN ('integer', 'real') THEN json_extract(e.props, ?)
        WHEN json_type(e.props, ?) = 'text' AND ${text} GLOB '[0-9]*' AND ${text} NOT GLOB '*[^0-9.]*' AND ${text} NOT GLOB '*.*.*' AND ${text} NOT GLOB '*.' THEN CAST(${text} AS REAL)
        WHEN json_type(e.props, ?) = 'text' AND ${text} GLOB '-[0-9]*' AND substr(${text}, 2) NOT GLOB '*[^0-9.]*' AND ${text} NOT GLOB '*.*.*' AND ${text} NOT GLOB '*.' THEN CAST(${text} AS REAL)
        ELSE 0 END)`,
      params: new Array(14).fill(path),
    };
  }

  /** The property names sent with an event in a query's range, most used first. */
  async eventPropKeys(query: Query, event: string): Promise<Array<{ key: string; events: number }>> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const where = `e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.props IS NOT NULL${f.sql}`;
    const params = [query.site, query.from, query.to, event, ...f.params];
    const rows =
      this.db.dialect === "postgres"
        ? await this.db.all(
            `SELECT k AS key, COUNT(*) AS events FROM rl_events e ${join} CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(e.props::jsonb) = 'object' THEN e.props::jsonb ELSE '{}'::jsonb END) AS k
             WHERE ${where} GROUP BY k ORDER BY events DESC, key LIMIT 30`,
            params,
          )
        : await this.db.all(
            `SELECT j.key AS key, COUNT(*) AS events FROM rl_events e ${join}, json_each(e.props) j
             WHERE ${where} AND json_type(e.props) = 'object' GROUP BY j.key ORDER BY events DESC, key LIMIT 30`,
            params,
          );
    return rows.map((r) => ({ key: String(r.key), events: num(r.events) }));
  }

  /** The values one property of an event took, with how often and by how many visitors. */
  async eventPropValues(query: Query, event: string, key: string, limit: number): Promise<Array<{ value: string; events: number; visitors: number }>> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const value = this.db.dialect === "postgres" ? `(e.props::jsonb ->> ?)` : `CAST(json_extract(e.props, ?) AS TEXT)`;
    const path = this.db.dialect === "postgres" ? key : `$."${key}"`;
    const rows = await this.db.all(
      `SELECT ${value} AS value, COUNT(*) AS events, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e ${join}
       WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND ${value} IS NOT NULL${f.sql}
       GROUP BY 1 ORDER BY events DESC, value LIMIT ?`,
      [path, query.site, query.from, query.to, event, path, ...f.params, limit],
    );
    return rows.map((r) => ({ value: String(r.value), events: num(r.events), visitors: num(r.visitors) }));
  }

  /** A goal's worth for one converting row, as SQL. */
  private revenueValue(goal: GoalRow): { sql: string; params: unknown[] } {
    if (goal.valueMode === "prop" && goal.valueProp) return this.propValue(goal.valueProp);
    if (goal.valueMode === "fixed") return { sql: `CAST(? AS DOUBLE PRECISION)`, params: [goal.value] };
    return { sql: `0`, params: [] };
  }

  /**
   * Every goal's totals in one pass over the range's events, instead of a query
   * per goal: each goal adds a conditional count, distinct count, and sum.
   */
  async goalTotalsAll(query: Query, goals: GoalRow[]): Promise<Map<string, GoalTotals>> {
    const out = new Map<string, GoalTotals>();
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    // A few dozen goals per query keeps the statement a sensible size.
    for (let start = 0; start < goals.length; start += 40) {
      const chunk = goals.slice(start, start + 40);
      const columns: string[] = [];
      const params: unknown[] = [];
      chunk.forEach((goal, i) => {
        const scope = this.goalScope(goal);
        const value = this.revenueValue(goal);
        columns.push(
          `SUM(CASE WHEN ${scope.sql} THEN 1 ELSE 0 END) AS c${i}`,
          `COUNT(DISTINCT CASE WHEN ${scope.sql} THEN e.visitor END) AS v${i}`,
          `SUM(CASE WHEN ${scope.sql} THEN ${value.sql} ELSE 0 END) AS r${i}`,
        );
        params.push(...scope.params, ...scope.params, ...scope.params, ...value.params);
      });
      const [row] = await this.db.all(
        `SELECT ${columns.join(", ")} FROM rl_events e ${join}
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event')${f.sql}`,
        [...params, query.site, query.from, query.to, ...f.params],
      );
      chunk.forEach((goal, i) =>
        out.set(goal.id, { conversions: num(row?.[`c${i}`]), visitors: num(row?.[`v${i}`]), revenue: Math.round(num(row?.[`r${i}`]) * 100) / 100 }),
      );
    }
    return out;
  }

  private revenueSql(goal: GoalRow): { sql: string; params: unknown[] } {
    if (goal.valueMode === "prop" && goal.valueProp) {
      const value = this.propValue(goal.valueProp);
      return { sql: `SUM(${value.sql})`, params: value.params };
    }
    // Cast, so Postgres does not read the bound value as a bigint and refuse 9.99.
    if (goal.valueMode === "fixed") return { sql: `COUNT(*) * CAST(? AS DOUBLE PRECISION)`, params: [goal.value] };
    return { sql: `0`, params: [] };
  }

  /** One goal's conversions, converting visitors, and revenue for a query's range and filters. */
  async goalTotals(query: Query, goal: GoalRow): Promise<GoalTotals> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const scope = this.goalScope(goal);
    const revenue = this.revenueSql(goal);
    const [row] = await this.db.all(
      `SELECT COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, ${revenue.sql} AS revenue
       FROM rl_events e ${join}
       WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${scope.sql}${f.sql}`,
      [...revenue.params, query.site, query.from, query.to, ...scope.params, ...f.params],
    );
    return { conversions: num(row?.conversions), visitors: num(row?.visitors), revenue: Math.round(num(row?.revenue) * 100) / 100 };
  }

  /** A goal's conversions split by where the visit came from, or by the page it happened on. */
  async goalBreakdown(query: Query, goal: GoalRow, by: "source" | "channel" | "path", limit = 10): Promise<Array<{ value: string } & GoalTotals>> {
    const f = filterSql(query.filters);
    const session = by !== "path" || f.needsSession;
    const col = by === "path" ? "e.path" : `s.${by}`;
    const scope = this.goalScope(goal);
    const revenue = this.revenueSql(goal);
    const rows = await this.db.all(
      `SELECT ${col} AS value, COUNT(*) AS conversions, COUNT(DISTINCT e.visitor) AS visitors, ${revenue.sql} AS revenue
       FROM rl_events e ${session ? "JOIN rl_sessions s ON s.id = e.session" : ""}
       WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${scope.sql}${f.sql}
       GROUP BY ${col} ORDER BY conversions DESC, value LIMIT ?`,
      [...revenue.params, query.site, query.from, query.to, ...scope.params, ...f.params, limit],
    );
    return rows.map((r) => ({
      value: String(r.value ?? ""),
      conversions: num(r.conversions),
      visitors: num(r.visitors),
      revenue: Math.round(num(r.revenue) * 100) / 100,
    }));
  }

  /** A goal's conversions and revenue in each bucket. */
  async goalSeries(query: Omit<Query, "from" | "to">, goal: GoalRow, buckets: Bucket[]): Promise<Array<{ start: number; conversions: number; revenue: number }>> {
    if (buckets.length === 0) return [];
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const cast = this.db.dialect === "postgres";
    const values = buckets.map((_, i) => (cast && i === 0 ? "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))" : "(?, ?, ?)")).join(", ");
    const scope = this.goalScope(goal);
    const revenue = this.revenueSql(goal);
    const rows = await this.db.all(
      `WITH b (i, bs, be) AS (VALUES ${values})
       SELECT b.i AS i, COUNT(*) AS conversions, ${revenue.sql} AS revenue
       FROM b JOIN rl_events e ON e.site = ? AND e.ts >= b.bs AND e.ts < b.be ${join}
       WHERE ${scope.sql}${f.sql}
       GROUP BY b.i`,
      [...buckets.flatMap((b, i) => [i, b.start, b.end]), ...revenue.params, query.site, ...scope.params, ...f.params],
    );
    const found = new Map(rows.map((r) => [num(r.i), r]));
    return buckets.map((b, i) => ({ start: b.start, conversions: num(found.get(i)?.conversions), revenue: Math.round(num(found.get(i)?.revenue) * 100) / 100 }));
  }

  async linkDomains(): Promise<Array<{ domain: string; site: string }>> {
    return this.db.all(`SELECT domain, site FROM rl_link_domains ORDER BY domain`);
  }

  async addLinkDomain(domain: string, site: string, now: number): Promise<void> {
    await this.db.run(`INSERT INTO rl_link_domains (domain, site, created_at) VALUES (?, ?, ?) ON CONFLICT (domain) DO NOTHING`, [domain, site, now]);
  }

  /**
   * Removes a domain. Its links keep it as their home and fall back to the
   * app's own link path until the domain is added again.
   */
  async removeLinkDomain(domain: string): Promise<void> {
    await this.db.run(`DELETE FROM rl_link_domains WHERE domain = ?`, [domain]);
  }

  /**
   * A site's links, newest first, with their clicks in a range. Clicks
   * imported as daily counts have no visitor, so they add to clicks only.
   */
  async links(site: string, from: number, to: number): Promise<Array<LinkRow & LinkStats>> {
    const rows = await this.db.all(
      `SELECT l.*, COALESCE(c.clicks, 0) AS clicks, COALESCE(c.visitors, 0) AS visitors
       FROM rl_links l LEFT JOIN (
         SELECT link, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(visitor, '')) AS visitors FROM rl_events
         WHERE site = ? AND kind = 'click' AND ts >= ? AND ts < ? GROUP BY link
       ) c ON c.link = l.id
       WHERE l.site = ? AND l.deleted_at IS NULL
       ORDER BY l.created_at DESC, l.id`,
      [site, from, to, site],
    );
    return rows.map((row) => ({ ...linkRow(row), clicks: num(row.clicks), visitors: num(row.visitors) }));
  }

  /** One link's clicks per bucket. */
  async linkSeries(site: string, link: string, buckets: Bucket[]): Promise<Array<{ start: number; clicks: number; visitors: number }>> {
    if (buckets.length === 0) return [];
    const cast = this.db.dialect === "postgres";
    const values = buckets.map((_, i) => (cast && i === 0 ? "(CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT))" : "(?, ?, ?)")).join(", ");
    const rows = await this.db.all(
      `WITH b (i, bs, be) AS (VALUES ${values})
       SELECT b.i AS i, COUNT(*) AS clicks, COUNT(DISTINCT NULLIF(e.visitor, '')) AS visitors
       FROM b JOIN rl_events e ON e.link = ? AND e.ts >= b.bs AND e.ts < b.be
       WHERE e.site = ? AND e.kind = 'click' GROUP BY b.i`,
      [...buckets.flatMap((b, i) => [i, b.start, b.end]), link, site],
    );
    const found = new Map(rows.map((row) => [num(row.i), row]));
    return buckets.map((bucket, i) => ({ start: bucket.start, clicks: num(found.get(i)?.clicks), visitors: num(found.get(i)?.visitors) }));
  }

  /** One link's clicks by a visit dimension: where they came from, where they were, what they used. */
  async linkBreakdown(site: string, link: string, from: number, to: number, dimension: SessionDimension, limit: number): Promise<BreakdownRow[]> {
    const col = `s.${SESSION_DIMENSIONS[dimension]}`;
    const rows = await this.db.all(
      `SELECT ${col} AS value, COUNT(*) AS clicks, COUNT(DISTINCT e.visitor) AS visitors
       FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.link = ? AND e.kind = 'click' AND e.ts >= ? AND e.ts < ? AND ${col} <> ''
       GROUP BY ${col} ORDER BY clicks DESC, value LIMIT ?`,
      [site, link, from, to, limit],
    );
    return rows.map((row) => ({ value: String(row.value), visitors: num(row.visitors), events: num(row.clicks) }));
  }

  // Reports

  /** When the site's first visit was recorded, or null with no data yet. */
  /** When Runlight itself first counted a visit, leaving out imported history. */
  async firstOwnVisit(site: string): Promise<number | null> {
    const [row] = await this.db.all(`SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ? AND imported = 0`, [site]);
    return row?.t === null || row?.t === undefined ? null : num(row.t);
  }

  async firstSeen(site: string): Promise<number | null> {
    const [row] = await this.db.all(`SELECT MIN(started_at) AS t FROM rl_sessions WHERE site = ?`, [site]);
    return row?.t === null || row?.t === undefined ? null : num(row.t);
  }

  /** Just the visitor count from stats(), in one query, for conversion rates. */
  async visitors(query: Query): Promise<number> {
    const f = filterSql(query.filters);
    const join = f.needsSession ? "JOIN rl_sessions s ON s.id = e.session" : "";
    const [row] = await this.db.all(
      `SELECT COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e ${join} WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql}`,
      [query.site, query.from, query.to, ...f.params],
    );
    return num(row?.visitors);
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
    const [bounces] = await this.db.all(
      `SELECT COUNT(*) AS n, SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(${DURATION}) AS duration ${sessions}`,
      params,
    );
    const n = num(bounces?.n);

    const visits = num(totals?.visits);
    const pageviews = num(totals?.pageviews);
    return {
      visitors: num(totals?.visitors),
      visits,
      pageviews,
      viewsPerVisit: visits > 0 ? Math.round((pageviews / visits) * 100) / 100 : 0,
      bounceRate: n > 0 ? num(bounces?.bounced) / n : 0,
      visitDuration: n > 0 ? Math.round(num(bounces?.duration) / n) : 0,
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
    // Bounce, duration, and views per visit belong to visits, counted in the
    // bucket each visit started in.
    const first = buckets[0]!.start;
    const last = buckets[buckets.length - 1]!.end;
    const matching = query.filters.length
      ? ` AND s.id IN (SELECT DISTINCT e.session FROM rl_events e JOIN rl_sessions s ON s.id = e.session
           WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql})`
      : "";
    const visitRows = await this.db.all<{ i: unknown; n: unknown; bounced: unknown; duration: unknown; views: unknown }>(
      `WITH b (i, bs, be) AS (VALUES ${values})
       SELECT b.i AS i, COUNT(*) AS n, SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced,
         SUM(${DURATION}) AS duration, SUM(s.pageviews) AS views
       FROM b JOIN rl_sessions s ON s.site = ? AND s.started_at >= b.bs AND s.started_at < b.be
       WHERE 1 = 1${matching}
       GROUP BY b.i`,
      [...params, query.site, ...(query.filters.length ? [query.site, first, last, ...f.params] : [])],
    );
    const found = new Map(rows.map((row) => [num(row.i), row]));
    const visitFound = new Map(visitRows.map((row) => [num(row.i), row]));
    return buckets.map((bucket, i) => {
      const row = found.get(i);
      const v = visitFound.get(i);
      const n = num(v?.n);
      return {
        start: bucket.start,
        visitors: num(row?.visitors),
        visits: num(row?.visits),
        pageviews: num(row?.pageviews),
        viewsPerVisit: n > 0 ? Math.round((num(v?.views) / n) * 100) / 100 : 0,
        bounceRate: n > 0 ? num(v?.bounced) / n : 0,
        visitDuration: n > 0 ? Math.round(num(v?.duration) / n) : 0,
      };
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
          `SELECT e.path AS value, SUM(e.engaged_ms) AS total, COUNT(DISTINCT e.pageview) AS views,
             AVG(e.scroll) AS scroll
           FROM rl_events e ${join} WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'engagement'${f.sql}
           AND e.path IN (${out.map(() => "?").join(", ")}) GROUP BY e.path`,
          [...params, ...out.map((row) => row.value)],
        );
        const byPath = new Map(times.map((t) => [String(t.value), t]));
        for (const row of out) {
          const time = byPath.get(row.value);
          row.timeOnPage = time && num(time.views) > 0 ? Math.round(num(time.total) / num(time.views)) : 0;
          row.scrollDepth = time?.scroll === null || time?.scroll === undefined ? 0 : Math.round(num(time.scroll));
        }
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
    const out: BreakdownRow[] = rows.map((row) => ({
      value: String(row.value),
      visitors: num(row.visitors),
      visits: num(row.visits),
      pageviews: num(row.pageviews),
    }));
    if (out.length === 0) return out;
    // A visit has one value of each visit dimension, so its bounce and
    // duration belong to exactly one row.
    const extras = await this.db.all(
      `SELECT ${col} AS value, COUNT(*) AS n, SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced, SUM(${DURATION}) AS duration
       FROM rl_sessions s WHERE s.id IN (
         SELECT DISTINCT e.session FROM rl_events e ${sessionJoin}
         WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql})
       AND ${col} IN (${out.map(() => "?").join(", ")})
       GROUP BY ${col}`,
      [...params, ...out.map((row) => row.value)],
    );
    const byValue = new Map(extras.map((x) => [String(x.value), x]));
    for (const row of out) {
      const x = byValue.get(row.value);
      const n = num(x?.n);
      row.bounceRate = n > 0 ? num(x?.bounced) / n : 0;
      row.visitDuration = n > 0 ? Math.round(num(x?.duration) / n) : 0;
    }
    return out;
  }

  /**
   * Visits started in each UTC hour of a range, as epoch hour numbers. The
   * caller folds them into local weekdays and hours, which keeps time zones
   * (DST included) out of SQL.
   */
  /**
   * Visits by quarter hour since the epoch. Quarters, not hours, so a site in a
   * half-hour or 45-minute timezone (India, Nepal) folds each into the right local hour.
   */
  async hourly(query: Query): Promise<Array<{ quarter: number; visits: number; visitors: number; pageviews: number; bounced: number }>> {
    const f = filterSql(query.filters);
    const matching = query.filters.length
      ? ` AND s.id IN (SELECT DISTINCT e.session FROM rl_events e JOIN rl_sessions s ON s.id = e.session
           WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND ${VISIT_KINDS}${f.sql})`
      : "";
    const rows = await this.db.all(
      `SELECT s.started_at / 900000 AS quarter, COUNT(*) AS visits, COUNT(DISTINCT s.visitor) AS visitors,
         SUM(s.pageviews) AS pageviews, SUM(CASE WHEN ${BOUNCE} THEN 1 ELSE 0 END) AS bounced
       FROM rl_sessions s
       WHERE s.site = ? AND s.started_at >= ? AND s.started_at < ?${matching}
       GROUP BY 1`,
      [query.site, query.from, query.to, ...(query.filters.length ? [query.site, query.from, query.to, ...f.params] : [])],
    );
    return rows.map((row) => ({
      quarter: Math.floor(num(row.quarter)),
      visits: num(row.visits),
      visitors: num(row.visitors),
      pageviews: num(row.pageviews),
      bounced: num(row.bounced),
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
    const countries = await this.db.all(
      `SELECT s.country AS value, COUNT(DISTINCT e.visitor) AS visitors FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') AND s.country <> ''
       GROUP BY s.country ORDER BY visitors DESC, value LIMIT 10`,
      [site, since],
    );
    const recent = await this.db.all(
      `SELECT e.ts, e.kind, e.path, e.name, s.country, s.city, s.source, s.device FROM rl_events e JOIN rl_sessions s ON s.id = e.session
       WHERE e.site = ? AND e.ts >= ? AND e.kind IN ('pageview', 'event') ORDER BY e.ts DESC LIMIT 20`,
      [site, start],
    );
    const pairs = (rows: Record<string, unknown>[]) => rows.map((row) => ({ value: String(row.value), visitors: num(row.visitors) }));
    return {
      visitors: num(active?.n),
      pages: pairs(pages),
      sources: pairs(sources),
      countries: pairs(countries),
      minutes,
      recent: recent.map((r) => ({
        ts: num(r.ts),
        kind: String(r.kind),
        path: String(r.path ?? ""),
        name: String(r.name ?? ""),
        country: String(r.country ?? ""),
        city: String(r.city ?? ""),
        source: String(r.source ?? ""),
        device: String(r.device ?? ""),
      })),
    };
  }
}
