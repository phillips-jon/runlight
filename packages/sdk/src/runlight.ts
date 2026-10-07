import { locate, type GeoLookup } from "./geo.js";
import { randomId, randomSalt, visitorHash } from "./hash.js";
import { parsePayload, MAX_BODY, type Payload } from "./payload.js";
import { Links } from "./links.js";
import { createRoutes, type Routes, type RoutesOptions } from "./routes.js";
import { attribute, parsePage, stripWww, type Page } from "./sources.js";
import type { SiteOverrides, SiteRow, SqlStore } from "./store.js";
import { isTimezone } from "./time.js";
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
  /** Looks up a location for an IP when the platform sends no location headers. */
  geo?: GeoLookup;
  /**
   * Read the client IP from forwarding headers (CF-Connecting-IP,
   * X-Real-IP, then the first X-Forwarded-For). Default true: analytics
   * needs the visitor's address, and most apps sit behind a proxy. A
   * client can forge these, which can only skew its own counts.
   */
  trustProxy?: boolean;
  /** Where short links on the app's own domain live, as `{linkPath}/{slug}`. Default "/go". */
  linkPath?: string;
  /** For tests. */
  now?: () => number;
}

/** Per request facts an adapter knows and a Fetch Request does not carry. */
export interface RequestContext {
  /** The address of the connection, used when no forwarding header names the client. */
  ip?: string;
}

/** A path on every link domain that answers when the domain reaches this Runlight. */
export const LINK_DOMAIN_CHECK = "/.well-known/runlight-link-domain";

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

export class Runlight {
  readonly store: SqlStore;
  /** The sites as configured in code. */
  private readonly configured: SiteRow[];
  private overrides = new Map<string, SiteOverrides>();
  private readonly geo: GeoLookup | undefined;
  private readonly trustProxy: boolean;
  readonly now: () => number;
  /** Short links: create, change, delete, and import. */
  readonly links: Links;
  /** Where links on the app's own domain are served, such as "/go". */
  readonly linkPath: string;
  private ready: Promise<void> | null = null;
  private salts: { day: string; today: string; yesterday: string | null } | null = null;

  constructor(options: RunlightOptions) {
    if (!options?.store) throw new Error("Runlight: pass a store, such as sqlite({ path: \"./data/runlight.db\" })");
    this.store = options.store;
    const configured = options.sites?.length ? options.sites : [options.site ?? {}];
    this.configured = configured.map(siteRow);
    if (this.configured.length > 1 && this.configured.some((site) => site.hostnames.length === 0)) {
      throw new Error("Runlight: with several sites, give each one its hostnames");
    }
    if (new Set(this.configured.map((site) => site.id)).size !== this.configured.length) {
      throw new Error("Runlight: two sites share an id");
    }
    this.geo = options.geo;
    this.trustProxy = options.trustProxy ?? true;
    this.now = options.now ?? Date.now;
    this.links = new Links(this);
    this.linkPath = `/${(options.linkPath ?? "/go").replace(/^\/+|\/+$/g, "")}`;
  }

  /** Creates tables and records the configured sites. Runs once. */
  init(): Promise<void> {
    this.ready ??= (async () => {
      await this.store.migrate();
      for (const site of this.configured) await this.store.upsertSite(site, this.now());
      this.overrides = await this.store.siteOverrides();
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

  /**
   * Changes a site's name or timezone from the dashboard. Stored apart from
   * the settings in code, which keep being written on every start.
   */
  async updateSite(id: string, patch: SiteOverrides): Promise<SiteRow> {
    await this.init();
    if (!this.configured.some((site) => site.id === id)) throw new RangeError("Unknown site");
    const next: SiteOverrides = { ...this.overrides.get(id) };
    if (patch.name !== undefined) {
      const name = String(patch.name).trim();
      if (!name || name.length > 80) throw new RangeError("A site name is 1 to 80 characters");
      next.name = name;
    }
    if (patch.timezone !== undefined) {
      if (!isTimezone(String(patch.timezone))) throw new RangeError(`Unknown timezone "${patch.timezone}"`);
      next.timezone = String(patch.timezone);
    }
    await this.store.setSiteOverrides(id, next);
    this.overrides.set(id, next);
    return this.site(id)!;
  }

  site(id: string | null | undefined): SiteRow | null {
    if (!id) return this.sites[0] ?? null;
    return this.sites.find((site) => site.id === id) ?? null;
  }

  /** The site a page belongs to, or null if it belongs to none. */
  siteFor(hostname: string, id?: string): SiteRow | null {
    const host = stripWww(hostname);
    if (id) {
      const site = this.site(id);
      return site && (site.hostnames.length === 0 || site.hostnames.includes(host)) ? site : null;
    }
    if (this.sites.length === 1) {
      const only = this.sites[0]!;
      return only.hostnames.length === 0 || only.hostnames.includes(host) ? only : null;
    }
    return this.sites.find((site) => site.hostnames.includes(host)) ?? null;
  }

  clientIp(request: Request, context: RequestContext = {}): string {
    if (this.trustProxy) {
      const h = request.headers;
      const forwarded = h.get("cf-connecting-ip") ?? h.get("x-real-ip") ?? h.get("x-forwarded-for")?.split(",")[0];
      if (forwarded?.trim()) return forwarded.trim();
    }
    return context.ip ?? "";
  }

  /** Today's salt and, if it still exists, yesterday's. Old salts are deleted on the way. */
  private async currentSalts(now: number): Promise<{ today: string; yesterday: string | null }> {
    const day = utcDay(now);
    if (this.salts?.day === day) return this.salts;
    const yesterdayDay = utcDay(now - 86_400_000);
    const today = await this.store.salt(day, randomSalt());
    const yesterday = await this.store.saltIfExists(yesterdayDay);
    await this.store.dropSaltsBefore(yesterdayDay);
    this.salts = { day, today, yesterday };
    return this.salts;
  }

  /** Handles one tracker request. Always resolves; bad input is dropped quietly. */
  async collect(request: Request, context: RequestContext = {}): Promise<void> {
    const length = Number(request.headers.get("content-length") ?? 0);
    if (length > MAX_BODY) return;
    const text = await request.text().catch(() => "");
    const payload = parsePayload(text);
    if (!payload) return;

    const ua = request.headers.get("user-agent") ?? "";
    if (aiAgent(ua) || isBot(ua)) return;

    const site = this.siteFor(payload.url.hostname, payload.site);
    if (!site) return;

    await this.init();
    const now = this.now();
    if (payload.kind === "engagement") return this.engagement(site, payload, now);

    const page = parsePage(payload.url);
    let session: { id: string; visitor: string } | null = null;
    if (payload.kind === "event" && payload.pageviewId) {
      const pageview = await this.store.pageview(site.id, payload.pageviewId);
      if (pageview) session = { id: pageview.session, visitor: pageview.visitor };
    }
    session ??= await this.sessionFor(site, request, context, page, payload.referrer, now, {
      screenWidth: payload.screenWidth,
      screen: payload.screenWidth && payload.screenHeight ? `${payload.screenWidth}x${payload.screenHeight}` : "",
      language: payload.language,
    });

    await this.store.touchSession(session.id, now, payload.kind, page.path);
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
    const salts = await this.currentSalts(now);
    const today = await visitorHash(salts.today, site.id, ip, ua);
    const candidates = [today];
    if (salts.yesterday) candidates.push(await visitorHash(salts.yesterday, site.id, ip, ua));
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
    const host = stripWww((request.headers.get("x-forwarded-host") ?? request.headers.get("host") ?? url.host).split(":")[0] ?? "");
    await this.init();
    if (!(await this.store.linkDomains()).some((d) => d.domain === host)) return null;
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
    if (!pageview) return;
    await this.store.addEngagement(pageview.session, payload.engagedMs);
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
  async observe(request: Request): Promise<void> {
    try {
      if (request.method !== "GET") return;
      const agent = aiAgent(request.headers.get("user-agent") ?? "");
      if (!agent) return;
      const url = new URL(request.url);
      // Pages, not their assets.
      const ext = /\.([a-z0-9]+)$/i.exec(url.pathname)?.[1]?.toLowerCase();
      if (ext && !["html", "htm", "md", "txt", "php"].includes(ext)) return;
      const host = request.headers.get("x-forwarded-host") ?? request.headers.get("host") ?? url.hostname;
      const site = this.siteFor(host.split(":")[0] ?? host);
      if (!site) return;
      await this.init();
      await this.store.insertEvent({
        site: site.id,
        ts: this.now(),
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
    } catch {
      // Analytics must never break the page it watches.
    }
  }

  /** Scheduled work: rotates salts. Idempotent; safe to call every minute. */
  async check(): Promise<{ ok: true }> {
    await this.init();
    this.salts = null;
    await this.currentSalts(this.now());
    return { ok: true };
  }
}
