import { sha256 } from "../hash.js";
import type { Runlight } from "../runlight.js";
import { attribute, parsePage, stripWww } from "../sources.js";
import type { DailyClicks, ForeignClick, ForeignLink } from "./types.js";

/** Domains run by the shorteners themselves. Links there stay on Runlight's own path. */
const SHORTENER_DOMAINS = new Set(["bit.ly", "bitly.com", "j.mp", "dub.sh", "dub.co", "dub.link", "short.gy", "rebrand.ly", "rebrandly.com", "rb.gy"]);

export const hexId = async (value: string, length = 24) => (await sha256(value)).slice(0, length);

/** The Runlight id an imported link gets, from its source and its id there. */
export const importedLinkId = (source: string, sourceId: string) => hexId(`${source}:${sourceId}`);

// Browser and system names as other tools write them, in Runlight's spelling.
export const BROWSERS: Record<string, string> = {
  chrome: "Chrome", crios: "Chrome", "chromium-webview": "Android WebView", "chrome webview": "Android WebView", safari: "Safari", ios: "Safari", "ios-webview": "Safari",
  "mobile safari": "Safari", firefox: "Firefox", fxios: "Firefox", edge: "Edge", "edge-chromium": "Edge", "edge-ios": "Edge", "microsoft edge": "Edge",
  opera: "Opera", "opera-mini": "Opera", samsung: "Samsung Internet", "samsung internet": "Samsung Internet", yandexbrowser: "Yandex Browser",
  facebook: "Facebook", instagram: "Instagram", brave: "Brave", duckduckgo: "DuckDuckGo",
};
export const SYSTEMS: Record<string, string> = {
  "mac os": "macOS", "mac os x": "macOS", macos: "macOS", ios: "iOS", "android os": "Android", android: "Android",
  "windows 10": "Windows", "windows 11": "Windows", "windows 7": "Windows", windows: "Windows", linux: "Linux", "chrome os": "Chrome OS", "chromium os": "Chrome OS",
};
export const DEVICES: Record<string, string> = { desktop: "desktop", laptop: "desktop", mobile: "mobile", smartphone: "mobile", phone: "mobile", tablet: "tablet" };

export const title = (v: string) => (v ? v[0]!.toUpperCase() + v.slice(1) : "");

export interface WriteResult {
  status: "created" | "skipped" | "failed";
  clicks: number;
  reason?: string;
}

/**
 * Writes one link and its history in a single transaction: the link (and its
 * branded domain), then each click as a visit like a live one, or daily
 * counts as clicks without visitors. Ids come from the source's own ids, so
 * importing again skips what is already there.
 */
export async function writeLink(
  runlight: Runlight,
  site: string,
  source: string,
  foreign: ForeignLink,
  history: { clicks?: ForeignClick[]; daily?: DailyClicks[] },
): Promise<WriteResult> {
  const id = await importedLinkId(source, foreign.sourceId);
  if (await runlight.store.linkById(id)) return { status: "skipped", clicks: 0 };
  const taken = await runlight.store.linkBySlug(foreign.slug);
  // The same slug to the same place is this link, brought in earlier some other way.
  if (taken && taken.url.replace(/\/$/, "") === foreign.url.replace(/\/$/, "")) return { status: "skipped", clicks: 0 };
  if (taken) return { status: "failed", clicks: 0, reason: `/${foreign.slug} is already used by "${taken.name}"` };
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/.test(foreign.slug)) return { status: "failed", clicks: 0, reason: `/${foreign.slug} has characters Runlight slugs cannot use` };

  let domain = stripWww(foreign.domain || "");
  if (SHORTENER_DOMAINS.has(domain)) domain = "";
  const now = runlight.now();
  let clicks = 0;
  // Nothing in the transaction is one link's own problem (those are checked above),
  // so a failure in it is the database's, and it stops the import rather than marking the link.
  await runlight.store.transaction(async (store) => {
    // On a database without transactions (D1), a failed earlier try can have left
    // some of this link's clicks behind. Clear them, then write the link row last,
    // so a link only counts as imported once all of its history is in.
    await store.db.run(`DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')`, [id]);
    await store.db.run(`DELETE FROM rl_events WHERE link = ?`, [id]);

    const made = new Set<string>();
    for (const c of history.clicks ?? []) {
      if (!Number.isFinite(c.ts)) continue;
      const visitKey = c.visit ?? `${c.ts}:${clicks}`;
      const session = await hexId(`${source}:${foreign.sourceId}:${visitKey}`);
      // A visitor id lasts one day at most, as every other visitor id does.
      const visitor = await hexId(`${source}:${visitKey}:${new Date(c.ts).toISOString().slice(0, 10)}`, 16);
      if (!made.has(session)) {
        made.add(session);
        await store.db.run(`DELETE FROM rl_sessions WHERE id = ?`, [session]);
        const host = domain || "link.invalid";
        let page;
        try {
          page = parsePage(new URL(`https://${host}${c.path || `/${foreign.slug}`}${c.query ? `?${c.query.replace(/^\?/, "")}` : ""}`));
        } catch {
          page = parsePage(new URL(`https://${host}/${foreign.slug}`));
        }
        const country = (c.country || "").toUpperCase().slice(0, 2);
        const region = c.region ? (c.region.includes("-") ? c.region : `${country}-${c.region}`).toUpperCase().slice(0, 10) : "";
        await store.insertSession({
          id: session,
          site,
          visitor,
          startedAt: c.ts,
          hostname: page.hostname,
          ...attribute(page, c.referrer ?? "", []),
          utmSource: page.utm.source,
          utmMedium: page.utm.medium,
          utmCampaign: page.utm.campaign,
          utmTerm: page.utm.term,
          utmContent: page.utm.content,
          country: /^[A-Z]{2}$/.test(country) ? country : "",
          region: country ? region : "",
          city: (c.city || "").slice(0, 100),
          browser: BROWSERS[(c.browser || "").toLowerCase()] ?? title(c.browser || ""),
          browserVersion: "",
          os: SYSTEMS[(c.os || "").toLowerCase()] ?? c.os ?? "",
          osVersion: "",
          device: DEVICES[(c.device || "").toLowerCase()] ?? "",
          screen: c.screen ?? "",
          language: c.language ?? "",
        });
        await store.db.run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session]);
      }
      await store.touchSession(session, c.ts, "click", c.path || `/${foreign.slug}`);
      await store.insertEvent({
        site, ts: c.ts, kind: "click", visitor, session, pageview: "", path: (c.path || `/${foreign.slug}`).slice(0, 1000),
        hostname: domain, title: "", name: foreign.slug, props: null, engagedMs: 0, scroll: null, link: id,
      });
      clicks++;
    }

    // Counts without detail: clicks spread through each day, with no visitor or visit.
    for (const d of history.daily ?? []) {
      const start = Date.parse(`${d.day}T00:00:00Z`);
      if (!Number.isFinite(start) || d.clicks <= 0) continue;
      const n = Math.min(d.clicks, 1_000_000);
      for (let i = 0; i < n; i++) {
        await store.insertEvent({
          site, ts: start + Math.floor(((i + 0.5) / n) * 86_400_000), kind: "click", visitor: "", session: "", pageview: "",
          path: `/${foreign.slug}`, hostname: domain, title: "", name: foreign.slug, props: { imported: "daily" }, engagedMs: 0, scroll: null, link: id,
        });
        clicks++;
      }
    }
    if (domain) await store.addLinkDomain(domain, site, now);
    await store.insertLink({
      id,
      site,
      domain,
      slug: foreign.slug,
      name: (foreign.name || foreign.slug).slice(0, 100),
      url: foreign.url,
      createdAt: foreign.createdAt || now,
      updatedAt: foreign.createdAt || now,
    });
  });
  if (domain) runlight.forgetLinkDomains();
  return { status: "created", clicks };
}
