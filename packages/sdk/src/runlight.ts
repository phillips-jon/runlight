import { locate, type GeoLookup } from "./geo.js";
import { randomId, randomSalt, visitorHash } from "./hash.js";
import { seal, unseal } from "./mail/secret.js";
import { MailError, SERVICES, checkConfig, send, type MailConfig, type Message } from "./mail/transports.js";
import { buildReport, lastPeriod } from "./reports.js";
import { parsePayload, MAX_BODY, type Payload } from "./payload.js";
import { Links } from "./links.js";
import { PROVIDERS, type AssistantSettings } from "./assistant.js";
import { RateLimit } from "./limit.js";
import { createRoutes, type Routes, type RoutesOptions } from "./routes.js";
import { attribute, parsePage, stripWww, type Page } from "./sources.js";
import { EVENT_TAIL_MS, type ReportRow, type SiteOverrides, type SiteRow, type SqlStore } from "./store.js";
import { addDays, isTimezone, localDate, startOf } from "./time.js";
import { aiAgent, isBot, parseClient } from "./ua.js";

export interface SiteOptions {
  /** Stable id, stored with every row. Default "default". */
  id?: string;
  name?: string;
  /**
   * Hostnames that belong to this site, without www. With one site, empty
   * means any hostname. With several, each site needs at least one.
   */
  hostnames?: string[];
  /** IANA timezone for reports, such as "Europe/London". Default "UTC". */
  timezone?: string;
}

export interface RunlightOptions {
  store: SqlStore;
  /** The site this install counts. Ignored when `sites` is given. */
  site?: SiteOptions;
  /** Several sites in one install, told apart by hostname. */
  sites?: SiteOptions[];
  /**
   * Sites are added, changed, and deleted in the dashboard and kept in the
   * database, as the standalone server does. `site` and `sites` are ignored.
   */
  managedSites?: boolean;
  /** Looks up a location for an IP when the platform sends no location headers. */
  geo?: GeoLookup;
  /**
   * Read the client IP from forwarding headers: the last X-Forwarded-For
   * entry, which the nearest proxy wrote, then X-Real-IP, then
   * CF-Connecting-IP. Name one of them to read only that header, such as
   * "cf-connecting-ip" behind Cloudflare and another proxy. Default true:
   * analytics needs the visitor's address, and most apps sit behind a proxy.
   * False reads only the socket's address, for an app nothing sits in front of.
   */
  trustProxy?: boolean | "x-forwarded-for" | "x-real-ip" | "cf-connecting-ip";
  /** Where short links on the app's own domain live, as `{linkPath}/{slug}`. Default "/go". */
  linkPath?: string;
  /**
   * The mail service for email reports, in code. When set, the dashboard
   * shows it and cannot change it. Otherwise it is set up in Settings.
   */
  mail?: MailSettings;
  /**
   * Encrypts the keys kept in the database: the mail service's, the AI
   * Assistant's, and the tokens for connected installs. Default the
   * RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
   */
  secret?: string;
  /**
   * Tracker requests allowed per visitor address per minute, counted in
   * memory by each process. Default 120, which a real visitor never reaches;
   * false turns the limit off.
   */
  rateLimit?: number | false;
  /** For tests. */
  now?: () => number;
}

/** A mail service and who reports come from. */
export type MailSettings = MailConfig & { from: string; fromName?: string };

/** Per request facts an adapter knows and a Fetch Request does not carry. */
export interface RequestContext {
  /** The address of the connection, used when no forwarding header names the client. */
  ip?: string;
}

/** Another Runlight install a site is read from: its address, its token there, and its own id for the site. */
export interface Remote {
  url: string;
  token: string;
  site: string;
  hostnames: string[];
  /** "manage" when the token may change the site's settings there; older connections read only. */
  scope?: "read" | "manage";
}

/** A path on every link domain that answers when the domain reaches this Runlight. */
export const LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain";

/** Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. */
const ROLLUP_VERSION = 2;
/** Days of rollups built per site in one scheduled check, and how long after a day ends it is built. */
const ROLLUP_BATCH = 10;
const ROLLUP_DELAY_MS = 2 * 3_600_000;

/** The choices for how long a site keeps its visits. */
export const RETENTION_MONTHS = [6, 12, 24, 36, 60];

/** Thirty minutes without a request ends a session. */
export const SESSION_IDLE_MS = 30 * 60 * 1000;

function utcDay(ts: number): string {
  return new Date(ts).toISOString().slice(0, 10);
}

function siteRow(options: SiteOptions, index: number): SiteRow {
  const timezone = options.timezone ?? "UTC";
  if (!isTimezone(timezone)) throw new Error(`Runlight: unknown timezone "${timezone}"`);
  const id = options.id ?? (index === 0 ? "default" : "");
  if (!id || !/^[a-z0-9][a-z0-9._-]{0,63}$/i.test(id)) throw new Error(`Runlight: site id "${id}" must be letters, digits, dots, dashes, or underscores`);
  return {
    id,
    name: options.name ?? (options.hostnames?.[0] ?? "My site"),
    hostnames: (options.hostnames ?? []).map(stripWww),
    timezone,
  };
}

/** An environment variable, trimmed, or undefined when it is empty or the runtime has none. */
export const envValue = (name: string): string | undefined => {
  const value = typeof process === "undefined" ? undefined : process.env[name];
  return value?.trim() ? value.trim() : undefined;
};

/** What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets. */
export const EMAIL = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/;

export class Runlight {
  readonly store: SqlStore;
  /** The sites as configured in code, or as kept in the database when they are managed. */
  private configured: SiteRow[];
  /** Whether sites are managed in the dashboard. */
  readonly managedSites: boolean;
  /** Sites counted by another Runlight install, read through its API with the token it gave, read or manage. */
  private readonly remotes = new Map<string, Remote>();
  private readonly remoteSeen = new Map<string, { at: number; lastSeen: number | null; retentionMonths: number | null | undefined }>();
  private overrides = new Map<string, SiteOverrides>();
  private readonly geo: GeoLookup | undefined;
  private readonly trustProxy: boolean | "x-forwarded-for" | "x-real-ip" | "cf-connecting-ip";
  private readonly limit: RateLimit | null;
  readonly now: () => number;
  /** Short links: create, change, delete, and import. */
  readonly links: Links;
  /** Where links on the app's own domain are served, such as "/go". */
  readonly linkPath: string;
  private ready: Promise<void> | null = null;
  private linkDomainCache: { at: number; domains: Set<string> } | null = null;
  /** Work queued per key by oneAtATime, such as one visitor's session. */
  private readonly turns = new Map<string, Promise<void>>();
  /** Each timezone's salts for its current day, so a lookup is a map read until midnight there. */
  private readonly salts = new Map<string, { day: string; today: string; yesterday: string | null }>();
  private readonly mailInCode: MailSettings | undefined;
  /** Encrypts the keys kept in the database; null leaves them readable, and the dashboard says so. */
  readonly secret: string | null;

  constructor(options: RunlightOptions) {
    if (!options?.store) throw new Error("Runlight: pass a store, such as sqlite({ path: \"./data/runlight.db\" })");
    this.store = options.store;
    this.managedSites = options.managedSites ?? false;
    const configured = this.managedSites ? [] : options.sites?.length ? options.sites : [options.site ?? {}];
    this.configured = configured.map(siteRow);
    if (this.configured.length > 1 && this.configured.some((site) => site.hostnames.length === 0)) {
      throw new Error("Runlight: with several sites, give each one its hostnames");
    }
    if (new Set(this.configured.map((site) => site.id)).size !== this.configured.length) {
      throw new Error("Runlight: two sites share an id");
    }
    this.geo = options.geo;
    this.trustProxy = options.trustProxy ?? true;
    const perMinute = options.rateLimit ?? 120;
    // false, 0, or anything that is not a positive number means no limit, never a limit of nothing.
    this.limit = perMinute === false || !(Number(perMinute) > 0) ? null : new RateLimit(Number(perMinute), () => this.now());
    this.now = options.now ?? Date.now;
    this.links = new Links(this);
    this.linkPath = `/${(options.linkPath ?? "/go").replace(/^\/+|\/+$/g, "")}`;
    this.mailInCode = options.mail;
    this.secret = options.secret ?? envValue("RUNLIGHT_SECRET") ?? envValue("RUNLIGHT_TOKEN") ?? null;
  }

  /** The mail service: from code, or as saved in the dashboard. Null when there is none. */
  async mailSettings(): Promise<(MailSettings & { source: "code" | "dashboard" }) | null> {
    if (this.mailInCode) return { ...this.mailInCode, source: "code" };
    await this.init();
    const sealed = await this.store.setting("mail");
    if (!sealed) return null;
    const opened = await unseal(sealed, this.secret);
    if (!opened) return null;
    return { ...(JSON.parse(opened) as MailSettings), source: "dashboard" };
  }

  /**
   * Saves the mail service from the dashboard. A secret field left blank
   * keeps the saved value, so the browser never needs to see it.
   */
  async saveMailSettings(input: Record<string, unknown> | null): Promise<void> {
    if (this.mailInCode) throw new MailError("The mail service is set in code");
    if (input === null) return this.store.setSetting("mail", null);
    const before = await this.mailSettings();
    const service = SERVICES.find((x) => x.id === input.service);
    if (!service) throw new MailError("Pick a mail service");
    const settings: Record<string, string> = { service: service.id };
    for (const f of service.fields) if (!f.secret) settings[f.name] = String(input[f.name] ?? "").trim();
    // A blank secret keeps the saved one only while the connection is the same,
    // so changing the host cannot send a saved password somewhere new.
    const sameConnection = before?.service === service.id && service.fields.every((f) => f.secret || String(before[f.name] ?? "") === settings[f.name]);
    for (const f of service.fields) {
      if (!f.secret) continue;
      const given = String(input[f.name] ?? "").trim();
      settings[f.name] = !given && sameConnection ? String(before?.[f.name] ?? "") : given;
    }
    const from = String(input.from ?? "").trim();
    if (!EMAIL.test(from)) throw new MailError("Enter the address reports come from, like reports@example.com");
    const fromName = String(input.fromName ?? "").trim().slice(0, 80);
    const config = { ...settings, from, ...(fromName ? { fromName } : {}) } as MailSettings;
    checkConfig(config);
    await this.store.setSetting("mail", await seal(JSON.stringify(config), this.secret));
  }

  /** Sends one email through the mail service. */
  async sendMail(message: Omit<Message, "from" | "fromName">): Promise<void> {
    const settings = await this.mailSettings();
    if (!settings) throw new MailError("Set up a mail service first");
    await send(settings, { ...message, from: settings.from, fromName: settings.fromName });
  }

  /**
   * Sends every report that is due: last week's on Monday from 8am, last
   * month's on the 1st, in each site's timezone. Safe to run often; each
   * period goes out once. Called by check().
   */
  async sendReports(): Promise<{ sent: number; failed: number }> {
    await this.init();
    const result = { sent: 0, failed: 0 };
    const reports = await this.store.reports();
    if (reports.length === 0 || !(await this.mailSettings())) return result;
    const now = this.now();
    for (const r of reports) {
      const site = this.site(r.site);
      if (!site) continue;
      const period = lastPeriod(r.frequency, now, site.timezone);
      if (now < period.dueAt || r.lastPeriod === period.key) continue;
      if (!(await this.store.claimReport(r.id, period.key, now))) continue;
      try {
        await this.deliverReport(r, site, period);
        result.sent++;
      } catch (error) {
        await this.store.releaseReport(r.id, period.key, r.lastPeriod);
        console.error(`Runlight: could not send the ${r.frequency} report for ${site.name} to ${r.email}:`, (error as Error).message);
        result.failed++;
      }
    }
    return result;
  }

  /** Builds and sends one report. Also used by "Send a sample now". */
  async deliverReport(r: ReportRow, site: SiteRow, period = lastPeriod(r.frequency, this.now(), site.timezone)): Promise<void> {
    const unsubscribe = `${r.origin}/unsubscribe/${r.token}`;
    const report = await buildReport(this, site, r.frequency, period, r.lang, { dashboard: `${r.origin}/?site=${encodeURIComponent(site.id)}`, unsubscribe });
    await this.sendMail({
      to: r.email,
      subject: report.subject,
      html: report.html,
      text: report.text,
      headers: { "List-Unsubscribe": `<${unsubscribe}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" },
    });
  }

  /** Creates tables and records the configured sites. Runs once. */
  init(): Promise<void> {
    this.ready ??= (async () => {
      await this.store.migrate();
      if (this.managedSites) {
        this.configured = await this.store.sites();
        await this.loadRemotes();
      }
      for (const site of this.configured) await this.store.upsertSite(site, this.now());
      this.overrides = await this.store.siteOverrides();
      // A process starting with a timezone set in code is the newest word on it: if the code changed it,
      // the days built in the old one are cleared here, once, and never by a process still running.
      for (const site of this.sites) {
        if (this.remotes.has(site.id)) continue;
        const stored = await this.store.setting(`rollup-zone:${site.id}`);
        const zone = stored ? (JSON.parse(stored) as { zone: string }).zone : null;
        if (zone === null) await this.store.setSetting(`rollup-zone:${site.id}`, JSON.stringify({ zone: site.timezone, since: 0 }));
        else if (zone !== site.timezone) await this.zoneChanged(site.id, site.timezone);
      }
    })().catch((error) => {
      this.ready = null;
      throw error;
    });
    return this.ready;
  }

  routes(options: RoutesOptions = {}): Routes {
    return createRoutes(this, options);
  }

  /** The sites, with any settings changed in the dashboard applied. */
  get sites(): SiteRow[] {
    return this.configured.map((site) => ({ ...site, ...this.overrides.get(site.id) }));
  }

  /** Checks a list of hostnames for a managed site: at least one, each a domain, none taken. */
  private hostnamesFor(input: unknown, except?: string): string[] {
    const list = (Array.isArray(input) ? input : String(input ?? "").split(/[\s,]+/))
      .map((h) => stripWww(String(h).trim().replace(/^https?:\/\//, "").replace(/[/:].*$/, "")))
      .filter(Boolean);
    const hostnames = [...new Set(list)];
    if (hostnames.length === 0) throw new RangeError("Add the site's domain, like example.com");
    for (const host of hostnames) {
      if (!/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(host) && host !== "localhost") throw new RangeError(`"${host}" is not a domain name`);
      const owner = this.configured.find((site) => site.id !== except && site.hostnames.includes(host));
      if (owner) throw new RangeError(`${host} already belongs to ${owner.name}`);
    }
    return hostnames;
  }

  private async loadRemotes(): Promise<void> {
    this.remotes.clear();
    for (const { key, value } of await this.store.settingsStartingWith("remote:")) {
      const opened = await unseal(value, this.secret);
      if (opened) this.remotes.set(key.slice("remote:".length), JSON.parse(opened) as Remote);
    }
  }

  /** The install a site is read from, when it is counted elsewhere. */
  remote(id: string): Remote | null {
    return this.remotes.get(id) ?? null;
  }

  /** When a connected install's site last had a visit, asked at most once a minute. */
  async remoteLastSeen(id: string): Promise<number | null> {
    return (await this.remoteInfo(id))?.lastSeen ?? null;
  }

  /**
   * What a connected install says about its site: its last visit and how long it keeps visits, asked
   * at most once a minute. Retention is undefined while the install cannot be reached.
   */
  async remoteInfo(id: string): Promise<{ lastSeen: number | null; retentionMonths: number | null | undefined } | null> {
    const remote = this.remotes.get(id);
    if (!remote) return null;
    const cached = this.remoteSeen.get(id);
    if (cached && this.now() - cached.at < 60_000) return cached;
    let info: { lastSeen: number | null; retentionMonths: number | null | undefined } = { lastSeen: cached?.lastSeen ?? null, retentionMonths: cached?.retentionMonths };
    try {
      const answer = await fetch(`${remote.url}/api/sites`, { headers: { authorization: `Bearer ${remote.token}` }, signal: AbortSignal.timeout(8000) });
      const body = (await answer.json().catch(() => null)) as { sites?: Array<{ id: string; lastSeen: number | null; retentionMonths?: number | null }> } | null;
      const there = body?.sites?.find((s) => s.id === remote.site);
      if (there) info = { lastSeen: there.lastSeen ?? null, retentionMonths: there.retentionMonths ?? null };
    } catch {}
    this.remoteSeen.set(id, { at: this.now(), ...info });
    return info;
  }

  /** Forgets what a connected install said, after a change made through it. */
  forgetRemoteInfo(id: string): void {
    this.remoteSeen.delete(id);
  }

  /** Asks a connected install to delete the token this server holds for it. A failure leaves it listed there. */
  private async revokeRemoteToken(remote: Remote): Promise<void> {
    await fetch(`${remote.url}/api/token`, { method: "DELETE", headers: { authorization: `Bearer ${remote.token}` }, signal: AbortSignal.timeout(5_000) }).catch(() => null);
  }

  /**
   * Connects a site counted by another Runlight (an app's own install) so this
   * server shows it too. Takes the install's address, as its dashboard is
   * (https://example.com/runlight), and an API token made there.
   */
  private async addRemoteSite(input: { url?: unknown; token?: unknown; site?: unknown; name?: unknown }): Promise<SiteRow> {
    const url = String(input.url ?? "").trim().replace(/\/+$/, "");
    if (!/^https:\/\/[^/]+|^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/.test(url)) throw new RangeError("Enter the install's address, like https://example.com/runlight");
    const token = String(input.token ?? "").trim();
    if (!token) throw new RangeError("Enter an API token from that install");
    let answer: Response;
    try {
      answer = await fetch(`${url}/api/sites`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
    } catch {
      throw new RangeError(`Could not reach ${url}`);
    }
    if (answer.status === 401 || answer.status === 403) throw new RangeError("That install refused the token");
    const body = (await answer.json().catch(() => null)) as { sites?: Array<{ id: string; name: string; timezone: string; hostnames: string[] }> } | null;
    if (!answer.ok || !body?.sites?.length) throw new RangeError(`${url} did not answer like a Runlight install`);
    // What the token may do there; an install from before manage tokens has no /api/token and reads only.
    let scope: "read" | "manage" = "read";
    let tokenSite = "";
    try {
      const about = await fetch(`${url}/api/token`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
      const info = about.ok ? ((await about.json().catch(() => null)) as { scope?: string; site?: string } | null) : null;
      if (info?.scope === "manage") scope = "manage";
      tokenSite = String(info?.site ?? "");
    } catch {}
    const there = body.sites.find((s) => s.id === (tokenSite || input.site)) ?? body.sites[0]!;
    // Connecting the same site again (to allow changes, or with a new token) updates it in place.
    for (const [existing, known] of this.remotes) {
      if (known.url === url && known.site === there.id) {
        const updated: Remote = { ...known, token, scope, hostnames: there.hostnames };
        if (known.token !== token) await this.revokeRemoteToken(known);
        await this.store.setSetting(`remote:${existing}`, await seal(JSON.stringify(updated), this.secret));
        this.remotes.set(existing, updated);
        this.remoteSeen.delete(existing);
        return this.site(existing)!;
      }
    }
    const host = (there.hostnames[0] ?? new URL(url).host).replace(/[^a-z0-9._-]/gi, "-").toLowerCase();
    let id = host.slice(0, 56);
    for (let n = 2; this.configured.some((site) => site.id === id); n++) id = `${host.slice(0, 56)}-${n}`;
    const name = String(input.name ?? "").trim().slice(0, 80) || there.name;
    // No hostnames: tracker hits never land on a site that is counted elsewhere.
    const site: SiteRow = { id, name, hostnames: [], timezone: isTimezone(there.timezone) ? there.timezone : "UTC" };
    const remote: Remote = { url, token, site: there.id, hostnames: there.hostnames, scope };
    await this.store.upsertSite(site, this.now());
    await this.store.setSetting(`remote:${id}`, await seal(JSON.stringify(remote), this.secret));
    this.remotes.set(id, remote);
    this.configured = [...this.configured, site].sort((a, b) => a.name.localeCompare(b.name));
    return site;
  }

  /** Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another install. */
  async addSite(input: { name?: unknown; hostnames?: unknown; timezone?: unknown; remote?: unknown }): Promise<SiteRow> {
    await this.init();
    if (!this.managedSites) throw new RangeError("Sites are set in code");
    if (input.remote && typeof input.remote === "object") return this.addRemoteSite({ ...(input.remote as Record<string, unknown>), name: input.name });
    const hostnames = this.hostnamesFor(input.hostnames);
    const name = String(input.name ?? "").trim() || hostnames[0]!;
    if (name.length > 80) throw new RangeError("A site name is 1 to 80 characters");
    const timezone = String(input.timezone ?? "UTC");
    if (!isTimezone(timezone)) throw new RangeError(`Unknown timezone "${timezone}"`);
    const stem = hostnames[0]!.replace(/[^a-z0-9._-]/g, "-").slice(0, 56);
    let id = stem;
    for (let n = 2; this.configured.some((site) => site.id === id); n++) id = `${stem}-${n}`;
    const site: SiteRow = { id, name, hostnames, timezone };
    await this.store.upsertSite(site, this.now());
    this.configured = [...this.configured, site].sort((a, b) => a.name.localeCompare(b.name));
    return site;
  }

  /** Deletes a site and everything recorded for it, when sites are managed in the dashboard. */
  async deleteSite(id: string): Promise<void> {
    await this.init();
    if (!this.managedSites) throw new RangeError("Sites are set in code");
    if (!this.configured.some((site) => site.id === id)) throw new RangeError("Unknown site");
    await this.store.deleteSite(id);
    await this.store.setSetting(`retention:${id}`, null);
    await this.store.setSetting(`observe-key:${id}`, null);
    await this.store.setSetting(`rollup-zone:${id}`, null);
    // A site made again with the same id starts its Umami import from the beginning.
    for (const { key } of await this.store.settingsStartingWith(`import:umami-visits:${id}:`)) await this.store.setSetting(key, null);
    // A connected install keeps its own data; only the connection goes, and its token there with it.
    const remote = this.remotes.get(id);
    if (remote) {
      await this.revokeRemoteToken(remote);
      this.remotes.delete(id);
      await this.store.setSetting(`remote:${id}`, null);
    }
    this.configured = this.configured.filter((site) => site.id !== id);
    this.overrides.delete(id);
  }

  /**
   * Changes a site's name or timezone from the dashboard. Stored apart from
   * the settings in code, which keep being written on every start. A managed
   * site has no settings in code, so its changes, hostnames too, go to its row.
   */
  async updateSite(id: string, patch: SiteOverrides & { hostnames?: unknown }): Promise<SiteRow> {
    await this.init();
    const current = this.configured.find((site) => site.id === id);
    if (!current) throw new RangeError("Unknown site");
    if (this.managedSites) {
      const next: SiteRow = { ...current };
      if (patch.name !== undefined) {
        const name = String(patch.name).trim();
        if (!name || name.length > 80) throw new RangeError("A site name is 1 to 80 characters");
        next.name = name;
      }
      if (patch.timezone !== undefined) {
        if (!isTimezone(String(patch.timezone))) throw new RangeError(`Unknown timezone "${patch.timezone}"`);
        next.timezone = String(patch.timezone);
        if (next.timezone !== this.site(id)?.timezone) await this.zoneChanged(id, next.timezone);
      }
      if (patch.hostnames !== undefined && !this.remotes.has(id)) next.hostnames = this.hostnamesFor(patch.hostnames, id);
      await this.store.upsertSite(next, this.now());
      this.configured = this.configured.map((site) => (site.id === id ? next : site));
      return this.site(id)!;
    }
    const next: SiteOverrides = { ...this.overrides.get(id) };
    if (patch.name !== undefined) {
      const name = String(patch.name).trim();
      if (!name || name.length > 80) throw new RangeError("A site name is 1 to 80 characters");
      next.name = name;
    }
    if (patch.timezone !== undefined) {
      if (!isTimezone(String(patch.timezone))) throw new RangeError(`Unknown timezone "${patch.timezone}"`);
      next.timezone = String(patch.timezone);
      if (next.timezone !== this.site(id)?.timezone) await this.zoneChanged(id, next.timezone);
    }
    await this.store.setSiteOverrides(id, next);
    this.overrides.set(id, next);
    return this.site(id)!;
  }

  /** How many months of visits a site keeps, or null to keep everything (the default). */
  async retention(site: string): Promise<number | null> {
    const value = Number(await this.store.setting(`retention:${site}`));
    return RETENTION_MONTHS.includes(value) ? value : null;
  }

  async setRetention(site: string, months: number | null): Promise<void> {
    if (!this.site(site) || this.remotes.has(site)) throw new RangeError("Unknown site");
    if (months !== null && !RETENTION_MONTHS.includes(months)) throw new RangeError(`Keep visits for ${RETENTION_MONTHS.join(", ")} months, or forever`);
    await this.store.setSetting(`retention:${site}`, months === null ? null : String(months));
    // Deleting a long history takes a while, so it runs in pieces after the answer, with tracking going on between them.
    this.pruning = this.pruning.then(() => this.applyRetention(site)).catch((error) => console.error("Runlight: could not apply retention", error));
  }

  /** Retention work still running; the scheduled check and tests wait for it. */
  private pruning: Promise<void> = Promise.resolve();
  async idle(): Promise<void> {
    await this.pruning;
  }

  /**
   * Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded before
   * the change were made per day of the old timezone, and could count one person twice in a new day, so
   * only days that start after the change are built; earlier ones are always counted visit by visit.
   */
  private async zoneChanged(id: string, timezone: string): Promise<number> {
    const since = this.now();
    await this.store.clearRollups(id);
    await this.store.setSetting(`rollup-zone:${id}`, JSON.stringify({ zone: timezone, since }));
    return since;
  }

  /**
   * Since when a site's days may be built: 0 for always, or when its timezone last changed. Null when
   * this process holds a different timezone than the one on record, such as an older copy still running
   * during a deploy, or one that has not yet seen a change made in the dashboard. It builds nothing for
   * that site, and reports read the visits themselves for any day not built, so nothing is wrong meanwhile.
   */
  private async rollupSince(site: SiteRow): Promise<number | null> {
    const stored = await this.store.setting(`rollup-zone:${site.id}`);
    if (!stored) {
      await this.store.setSetting(`rollup-zone:${site.id}`, JSON.stringify({ zone: site.timezone, since: 0 }));
      return 0;
    }
    const zone = JSON.parse(stored) as { zone: string; since: number };
    return zone.zone === site.timezone ? zone.since : null;
  }

  /**
   * Adds up each site's finished days, so long ranges read a row a day instead
   * of every visit. A day is built two hours after it ends in the site's
   * timezone, once late engagement has landed, and at most ROLLUP_BATCH days
   * a run, so a long history fills in over a few runs. Reports read the raw
   * visits for any day not built yet, so the numbers are the same either way.
   * Only a visit still going two hours past midnight, with no 30 minute gap,
   * could add to a day after it is built.
   */
  async buildRollups(): Promise<number> {
    // Days rolled up by an earlier way of counting are cleared once, and built again below.
    if ((await this.store.setting("rollup-version")) !== String(ROLLUP_VERSION)) {
      for (const site of this.sites) await this.store.clearRollups(site.id);
      await this.store.setSetting("rollup-version", String(ROLLUP_VERSION));
    }
    let built = 0;
    const now = this.now();
    for (const site of this.sites) {
      if (this.remotes.has(site.id)) continue;
      const first = await this.store.firstSeen(site.id);
      if (first === null) continue;
      const cutoff = (await this.retentionCutoff(site.id)) ?? 0;
      const since = await this.rollupSince(site);
      if (since === null) continue;
      const done = await this.store.rollupDays(site.id);
      const today = localDate(now, site.timezone);
      let made = 0;
      // Newest first, so recent ranges speed up before a long history is done.
      for (let day = addDays(today, -1); day >= localDate(Math.max(first, cutoff), site.timezone) && made < ROLLUP_BATCH; day = addDays(day, -1)) {
        if (done.has(day)) continue;
        const start = startOf(day, site.timezone);
        const end = startOf(addDays(day, 1), site.timezone);
        if (start < since) break;
        if (now < end + ROLLUP_DELAY_MS || start < cutoff) continue;
        try {
          await this.store.buildRollupDay(site.id, day, start, end);
          made++;
        } catch (error) {
          // Another process building the same day at once loses nothing: the day is there either way.
          if (!(await this.store.rollupDays(site.id)).has(day)) console.error(`Runlight: could not add up ${day} for ${site.id}`, error);
        }
        // A pause between days, so tracker hits are written while a long history fills in.
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
      built += made;
    }
    return built;
  }

  /** The dashboard assistant's provider, model, and key, kept sealed like the mail keys. Null until an owner sets it up. */
  async assistantSettings(): Promise<AssistantSettings | null> {
    const stored = await this.store.setting("assistant");
    const opened = stored ? await unseal(stored, this.secret) : null;
    return opened ? (JSON.parse(opened) as AssistantSettings) : null;
  }

  /** Saves the assistant's settings; an empty key keeps the one saved for the same provider. Null removes them. */
  async saveAssistantSettings(input: Record<string, unknown> | null): Promise<void> {
    if (!input) return this.store.setSetting("assistant", null);
    const provider = PROVIDERS.find((p) => p.id === input.provider);
    if (!provider) throw new RangeError("Choose a provider");
    const baseUrl = String(input.baseUrl ?? "").trim().replace(/\/+$/, "");
    if (baseUrl) {
      let parsed: URL | null = null;
      try {
        parsed = new URL(baseUrl);
      } catch {}
      if (!parsed || (parsed.protocol !== "https:" && parsed.protocol !== "http:")) throw new RangeError("Enter the service's address, starting with https://");
    }
    if (!baseUrl && !provider.baseUrl) throw new RangeError("Enter the service's address");
    const model = String(input.model ?? "").trim().slice(0, 200);
    if (!model && !provider.model) throw new RangeError("Enter the model to use");
    const before = await this.assistantSettings();
    let key = String(input.key ?? "").trim();
    // A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
    if (!key && before?.provider === provider.id && (before.baseUrl || provider.baseUrl) === (baseUrl || provider.baseUrl)) key = before.key;
    if (!key && provider.key === "yes") throw new RangeError(`Enter your ${provider.name} key`);
    const settings: AssistantSettings = { provider: provider.id, model, baseUrl, key };
    await this.store.setSetting("assistant", await seal(JSON.stringify(settings), this.secret));
  }

  /** The oldest moment a site keeps visits from, or null when it keeps everything. */
  async retentionCutoff(site: string): Promise<number | null> {
    const months = await this.retention(site);
    if (months === null) return null;
    const cutoff = new Date(this.now());
    cutoff.setUTCMonth(cutoff.getUTCMonth() - months);
    return cutoff.getTime();
  }

  /** Deletes visits older than each site's retention allows. Cheap when there is nothing to delete. */
  private async applyRetention(only?: string): Promise<void> {
    for (const site of this.sites) {
      if ((only && site.id !== only) || this.remotes.has(site.id)) continue;
      const cutoff = await this.retentionCutoff(site.id);
      if (cutoff !== null) await this.store.dropBefore(site.id, cutoff);
    }
  }

  site(id: string | null | undefined): SiteRow | null {
    if (!id) return this.sites[0] ?? null;
    return this.sites.find((site) => site.id === id) ?? null;
  }

  /** The site a page belongs to, or null if it belongs to none. */
  siteFor(hostname: string, id?: string): SiteRow | null {
    const host = stripWww(hostname);
    // A site counted by another install never takes hits here.
    if (this.remotes.size) {
      const local = this.sites.filter((site) => !this.remotes.has(site.id));
      if (id) return this.remotes.has(id) ? null : this.siteForAmong(local, host, id);
      return this.siteForAmong(local, host);
    }
    return this.siteForAmong(this.sites, host, id);
  }

  private siteForAmong(sites: SiteRow[], host: string, id?: string): SiteRow | null {
    if (id) {
      const site = sites.find((s) => s.id === id) ?? null;
      return site && (site.hostnames.length === 0 || site.hostnames.includes(host)) ? site : null;
    }
    if (sites.length === 1) {
      const only = sites[0]!;
      return only.hostnames.length === 0 || only.hostnames.includes(host) ? only : null;
    }
    return sites.find((site) => site.hostnames.includes(host)) ?? null;
  }

  /**
   * A test from a developer's own machine while a site is being set up. A site
   * with no visits yet accepts hits from localhost and .local or .test names,
   * so the install screen confirms it works; after its first visit they are
   * ignored again, so local browsing never mixes with real traffic.
   */
  private async setupSite(hostname: string, id?: string): Promise<SiteRow | null> {
    const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
    if (!(host === "localhost" || host === "127.0.0.1" || host === "::1" || /\.(localhost|local|test)$/.test(host))) return null;
    const site = id ? this.site(id) : this.sites.length === 1 ? this.sites[0]! : null;
    if (!site || this.remotes.has(site.id)) return null;
    return (await this.store.lastSeen(site.id)) === null ? site : null;
  }

  /**
   * The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes
   * from a header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote
   * and a client cannot choose (Vercel, Netlify, Cloudflare, Caddy, and nginx all append there),
   * then X-Real-IP and CF-Connecting-IP. Naming one header (after another proxy in front, such as
   * Cloudflare before nginx) reads only that one.
   */
  clientIp(request: Request, context: RequestContext = {}): string {
    if (this.trustProxy) {
      const h = request.headers;
      const last = (name: string) => h.get(name)?.split(",").map((x) => x.trim()).filter(Boolean).pop();
      const forwarded =
        this.trustProxy === true ? (last("x-forwarded-for") ?? h.get("x-real-ip") ?? h.get("cf-connecting-ip")) : this.trustProxy === "x-forwarded-for" ? last("x-forwarded-for") : h.get(this.trustProxy);
      if (forwarded?.trim()) return forwarded.trim();
    }
    return context.ip ?? "";
  }

  /**
   * Today's salt in a site's timezone and, if it still exists, yesterday's.
   * Salts follow the site's own days, as its reports do, so a visitor is one
   * visitor for the whole of that site's day. Old salts go on the way.
   */
  private async currentSalts(now: number, timezone: string): Promise<{ today: string; yesterday: string | null }> {
    const day = localDate(now, timezone);
    const cached = this.salts.get(timezone);
    if (cached?.day === day) return cached;
    const today = await this.store.salt(day, randomSalt());
    const yesterday = await this.store.saltIfExists(addDays(day, -1));
    await this.dropOldSalts(now);
    const salts = { day, today, yesterday };
    this.salts.set(timezone, salts);
    return salts;
  }

  /**
   * Deletes salts whose day has ended everywhere. The earliest timezone is a
   * day behind UTC and still needs its yesterday, so a salt goes two UTC days
   * after its date.
   */
  private async dropOldSalts(now: number): Promise<void> {
    await this.store.dropSaltsBefore(utcDay(now - 2 * 86_400_000));
  }

  /** Handles one tracker request. Always resolves; bad input is dropped quietly. */
  async collect(request: Request, context: RequestContext = {}): Promise<void> {
    const length = Number(request.headers.get("content-length") ?? 0);
    if (length > MAX_BODY) return;
    // Read no more than a tracker hit can be, whatever the length header says (or when there is none).
    const text = await readCapped(request, MAX_BODY);
    if (text === null) return;
    const payload = parsePayload(text);
    if (!payload) return;

    const ua = request.headers.get("user-agent") ?? "";
    if (aiAgent(ua) || isBot(ua)) return;
    if (this.limit && !(await this.limit.allow(this.clientIp(request, context)))) return;

    // Managed sites load from the database in init(), so it must come first.
    await this.init();
    const site = this.siteFor(payload.url.hostname, payload.site) ?? (await this.setupSite(payload.url.hostname, payload.site));
    if (!site) return;

    const now = this.now();
    if (payload.kind === "engagement") return this.engagement(site, payload, now);

    const page = parsePage(payload.url);
    let session: { id: string; visitor: string } | null = null;
    let reopen = true;
    if (payload.kind === "event" && payload.pageviewId) {
      const pageview = await this.store.pageview(site.id, payload.pageviewId);
      // An event joins its page's visit unless that visit began longer ago than reports look for its rows
      // (a tab left open for days); it then starts a visit of its own, as any later activity would.
      if (pageview && now - pageview.startedAt < EVENT_TAIL_MS) {
        session = { id: pageview.session, visitor: pageview.visitor };
        // A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
        reopen = now - pageview.lastAt <= SESSION_IDLE_MS;
        if (now - pageview.startedAt > 3_600_000) await this.store.touchedOldVisit(site.id, pageview.startedAt, now - ROLLUP_DELAY_MS + 3_600_000);
      }
    }
    session ??= await this.sessionFor(site, request, context, page, payload.referrer, now, {
      screenWidth: payload.screenWidth,
      screen: payload.screenWidth && payload.screenHeight ? `${payload.screenWidth}x${payload.screenHeight}` : "",
      language: payload.language,
    });

    await this.store.touchSession(session.id, now, payload.kind, page.path, reopen);
    await this.store.insertEvent({
      site: site.id,
      ts: now,
      kind: payload.kind,
      visitor: session.visitor,
      session: session.id,
      pageview: payload.pageviewId,
      path: page.path,
      hostname: page.hostname,
      title: payload.kind === "pageview" ? payload.title : "",
      name: payload.kind === "event" ? payload.name : "",
      props: payload.props,
      engagedMs: 0,
      scroll: null,
      link: "",
    });
  }

  /**
   * The visitor's open session on a site, or a new one attributed to this
   * request. Shared by tracker hits and short link clicks.
   */
  private async sessionFor(
    site: SiteRow,
    request: Request,
    context: RequestContext,
    page: Page,
    referrer: string,
    now: number,
    client: { screenWidth?: number; screen: string; language: string },
  ): Promise<{ id: string; visitor: string }> {
    const ua = request.headers.get("user-agent") ?? "";
    const ip = this.clientIp(request, context);
    const salts = await this.currentSalts(now, site.timezone);
    const today = await visitorHash(salts.today, site.id, ip, ua);
    const candidates = [today];
    if (salts.yesterday) candidates.push(await visitorHash(salts.yesterday, site.id, ip, ua));
    // One visitor's requests often arrive together (a pageview and the event
    // right after it). Taking turns per visitor means only the first opens a
    // session and the rest find it, instead of each opening its own.
    return this.oneAtATime(`${site.id}:${today}`, async () => {
      const open = await this.store.openSession(site.id, candidates, now - SESSION_IDLE_MS);
      if (open) return open;

      const session = { id: randomId(), visitor: today };
      const attribution = attribute(page, referrer, site.hostnames);
      const parsed = parseClient(
        ua,
        {
          brands: request.headers.get("sec-ch-ua"),
          mobile: request.headers.get("sec-ch-ua-mobile"),
          platform: request.headers.get("sec-ch-ua-platform"),
        },
        client.screenWidth,
      );
      const location = await locate(request.headers, ip, this.geo);
      await this.store.insertSession({
        id: session.id,
        site: site.id,
        visitor: session.visitor,
        startedAt: now,
        hostname: page.hostname,
        ...attribution,
        utmSource: page.utm.source,
        utmMedium: page.utm.medium,
        utmCampaign: page.utm.campaign,
        utmTerm: page.utm.term,
        utmContent: page.utm.content,
        ...location,
        ...parsed,
        screen: client.screen,
        language: client.language,
      });
      return session;
    });
  }

  /**
   * The link domains, read at most every 30 seconds. Every request to a
   * standalone server asks, so this saves a query on each tracker hit; a
   * change made here clears it at once, one made by another process within
   * half a minute.
   */
  private async linkDomainSet(): Promise<Set<string>> {
    const now = this.now();
    if (this.linkDomainCache && now - this.linkDomainCache.at < 30_000) return this.linkDomainCache.domains;
    await this.init();
    const domains = new Set((await this.store.linkDomains()).map((d) => d.domain));
    this.linkDomainCache = { at: now, domains };
    return domains;
  }

  /** Clears the cached link domains after one is added or removed. */
  forgetLinkDomains(): void {
    this.linkDomainCache = null;
  }

  /** Runs `fn` after any earlier call with the same key has finished. */
  private oneAtATime<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const previous = this.turns.get(key) ?? Promise.resolve();
    const result = previous.then(fn, fn);
    const settled = result.then(
      () => {},
      () => {},
    );
    this.turns.set(key, settled);
    void settled.then(() => {
      if (this.turns.get(key) === settled) this.turns.delete(key);
    });
    return result;
  }

  /**
   * Handles `{linkPath}/{slug}` on the app's own domain. In Next.js:
   * app/go/[slug]/route.ts with `export const GET = rl.linkHandler();`
   */
  linkHandler(): (request: Request, context?: RequestContext) => Promise<Response> {
    return async (request, context = {}) => {
      const path = new URL(request.url).pathname;
      const slug = path.startsWith(`${this.linkPath}/`) ? decodeURIComponent(path.slice(this.linkPath.length + 1)) : "";
      const found = slug && !slug.includes("/") ? await this.redirect(request, slug, "", context) : null;
      return found ?? new Response("Not found", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
    };
  }

  /**
   * For middleware: when a request arrives on a link domain added in
   * Settings (such as t.example.com), answers `/{slug}` there with the
   * redirect, and anything else with a 404. Null for every other host, so
   * the app carries on as normal.
   */
  async linkDomainResponse(request: Request, context: RequestContext = {}): Promise<Response | null> {
    const url = new URL(request.url);
    // A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
    const given = (this.trustProxy ? request.headers.get("x-forwarded-host") : null) ?? request.headers.get("host") ?? url.host;
    const host = stripWww(given.split(",")[0]!.trim().split(":")[0] ?? "");
    if (!(await this.linkDomainSet()).has(host)) return null;
    // Lets the dashboard confirm that requests to this domain reach Runlight.
    if (url.pathname === LINK_DOMAIN_CHECK) {
      return new Response(JSON.stringify({ runlight: true, domain: host }), {
        headers: { "content-type": "application/json", "cache-control": "no-store" },
      });
    }
    const slug = decodeURIComponent(url.pathname.slice(1));
    const found = slug && !slug.includes("/") ? await this.redirect(request, slug, host, context) : null;
    return found ?? new Response("Not found", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
  }

  /**
   * Answers a request for a short link: a redirect to its destination, with
   * the click recorded like a visit (source, place, device, and any campaign
   * tags on the short URL) but kept out of visitor and pageview counts.
   * Bots are redirected and not counted. `domain` is the link domain the
   * request came in on, or "" for the app's own link path, which answers for
   * every link. Null when no link fits.
   */
  async redirect(request: Request, slug: string, domain: string, context: RequestContext = {}): Promise<Response | null> {
    await this.init();
    const url = new URL(request.url);
    const host = stripWww((request.headers.get("x-forwarded-host") ?? request.headers.get("host") ?? url.host).split(":")[0] ?? "");
    const link = await this.store.linkBySlug(slug);
    // The app's own link path answers for every link, so a link whose domain
    // was removed keeps working; a link domain answers only for its own links.
    if (!link || (domain !== "" && link.domain !== domain)) return null;
    const site = this.site(link.site) ?? this.sites[0];
    const ua = request.headers.get("user-agent") ?? "";
    if (site && !aiAgent(ua) && !isBot(ua) && request.method === "GET") {
      try {
        const now = this.now();
        const language = (request.headers.get("accept-language") ?? "").split(",")[0]?.split(";")[0]?.trim().slice(0, 35) ?? "";
        const session = await this.sessionFor(site, request, context, parsePage(url), request.headers.get("referer") ?? "", now, { screen: "", language });
        await this.store.touchSession(session.id, now, "click", url.pathname);
        await this.store.insertEvent({
          site: site.id,
          ts: now,
          kind: "click",
          visitor: session.visitor,
          session: session.id,
          pageview: "",
          path: url.pathname.slice(0, 1000),
          hostname: host,
          title: "",
          name: link.slug,
          props: null,
          engagedMs: 0,
          scroll: null,
          link: link.id,
        });
      } catch (error) {
        // A failed count must never break the redirect.
        console.error("Runlight: could not record a link click", error);
      }
    }
    return new Response(null, { status: 302, headers: { location: link.url, "cache-control": "no-store", "referrer-policy": "no-referrer-when-downgrade" } });
  }

  private async engagement(site: SiteRow, payload: Payload, now: number): Promise<void> {
    if (payload.engagedMs <= 0) return;
    const pageview = await this.store.pageview(site.id, payload.pageviewId);
    // Reports look for a visit's rows only so long after it began, so later time on it is let go.
    if (!pageview || now - pageview.startedAt >= EVENT_TAIL_MS) return;
    await this.store.addEngagement(pageview.session, payload.engagedMs);
    // Only a visit that began more than an hour ago can belong to a day that is already added up.
    if (now - pageview.startedAt > 3_600_000) await this.store.touchedOldVisit(site.id, pageview.startedAt, now - ROLLUP_DELAY_MS + 3_600_000);
    await this.store.insertEvent({
      site: site.id,
      ts: now,
      kind: "engagement",
      visitor: pageview.visitor,
      session: pageview.session,
      pageview: payload.pageviewId,
      path: pageview.path,
      hostname: pageview.hostname,
      title: "",
      name: "",
      props: null,
      engagedMs: payload.engagedMs,
      scroll: payload.scroll ?? null,
      link: "",
    });
  }

  /**
   * Records a request from a known AI agent. Call it from middleware for
   * every page request; it ignores everything else and never throws.
   * Agents do not run JavaScript, so the tracker cannot see them.
   */
  async observe(request: Request, at?: number): Promise<boolean> {
    try {
      if (request.method !== "GET") return false;
      const agent = aiAgent(request.headers.get("user-agent") ?? "");
      if (!agent) return false;
      const url = new URL(request.url);
      // Pages, not their assets.
      const ext = /\.([a-z0-9]+)$/i.exec(url.pathname)?.[1]?.toLowerCase();
      if (ext && !["html", "htm", "md", "txt", "php"].includes(ext)) return false;
      const host = request.headers.get("x-forwarded-host") ?? request.headers.get("host") ?? url.hostname;
      await this.init();
      const site = this.siteFor(host.split(":")[0] ?? host);
      if (!site) return false;
      // A log reader sends when the page was served. Older than a week is dropped, so a first run over
      // an old log does not land as one spike on today; a time ahead of now counts as now.
      const now = this.now();
      if (at !== undefined && Number.isFinite(at) && at < now - 7 * 86_400_000) return false;
      const ts = at !== undefined && Number.isFinite(at) && at <= now ? Math.floor(at) : now;
      await this.store.insertEvent({
        site: site.id,
        ts,
        kind: "fetch",
        visitor: "",
        session: "",
        pageview: "",
        path: url.pathname.slice(0, 1000),
        hostname: stripWww(url.hostname),
        title: "",
        name: agent.name,
        props: { company: agent.company, kind: agent.kind },
        engagedMs: 0,
        scroll: null,
        link: "",
      });
      return true;
    } catch (error) {
      // Analytics must never break the page it watches, but a failure should still be seen.
      console.error("Runlight: could not record an AI agent fetch", error);
      return false;
    }
  }

  /**
   * Scheduled upkeep, safe to run every minute. It rotates salts, sends the email
   * reports that are due, deletes visits past each site's retention, and builds
   * daily rollups. It also rereads sites, their dashboard settings, and connected
   * installs, so a change made by another process sharing the database shows up here too.
   */
  async check(): Promise<{ ok: true; reports: { sent: number; failed: number } }> {
    // A check still running when the next is due (a long retention, say) is shared, never run twice at once.
    this.checking ??= this.runCheck().finally(() => {
      this.checking = null;
    });
    return this.checking;
  }

  private checking: Promise<{ ok: true; reports: { sent: number; failed: number } }> | null = null;
  private optimizedAt = 0;

  private async runCheck(): Promise<{ ok: true; reports: { sent: number; failed: number } }> {
    await this.init();
    if (this.managedSites) {
      this.configured = await this.store.sites();
      await this.loadRemotes();
    }
    // A name or timezone changed in the dashboard by another process reaches this one too.
    this.overrides = await this.store.siteOverrides();
    this.salts.clear();
    for (const timezone of new Set(this.sites.map((s) => s.timezone))) await this.currentSalts(this.now(), timezone);
    await this.dropOldSalts(this.now());
    this.pruning = this.pruning.then(() => this.applyRetention()).catch((error) => console.error("Runlight: could not apply retention", error));
    await this.pruning;
    if (this.now() - this.optimizedAt >= 86_400_000) {
      this.optimizedAt = this.now();
      await this.store.optimize();
    }
    await this.buildRollups();
    return { ok: true, reports: await this.sendReports() };
  }
}

/** A request body as text, or null when it is longer than `max` bytes. */
async function readCapped(request: Request, max: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > max) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.length;
  }
  return new TextDecoder().decode(all);
}
