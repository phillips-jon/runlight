// Copies short links, their custom domains, and every click from an Umami
// instance (v3, or the fork with custom domains) into a Runlight database.
// Reads Umami through its API and never writes to it.
//
//   UMAMI_URL=https://stats.example.com UMAMI_API_KEY=... \
//     node --import tsx scripts/import-umami-links.mts ./data/runlight.db
//
// Safe to run again: links already imported are skipped. Clicks are tied to
// the visitor's session in Umami, so each keeps its referrer, campaign tags,
// country, region, city, browser, OS, and device. Imported sessions are
// marked, so reports can tell where Runlight's own history began.
import { createHash } from "node:crypto";
import { runlight } from "../packages/sdk/src/index.ts";
import { attribute, parsePage, stripWww } from "../packages/sdk/src/sources.ts";
import { sqlite } from "../packages/sdk/src/stores/sqlite.ts";

const base = (process.env.UMAMI_URL ?? "").replace(/\/+$/, "");
const key = process.env.UMAMI_API_KEY ?? "";
const file = process.argv[2];
if (!base || !key || !file) {
  console.error("Usage: UMAMI_URL=... UMAMI_API_KEY=... node --import tsx scripts/import-umami-links.mts <runlight.db>");
  process.exit(2);
}

interface UmamiLink {
  id: string;
  name: string;
  url: string;
  slug: string;
  createdAt: string;
  deletedAt: string | null;
  customDomain: { domain: string } | null;
}

interface UmamiEvent {
  sessionId: string;
  createdAt: string;
  hostname: string;
  urlPath: string;
  urlQuery: string;
  referrerDomain: string;
  referrerPath: string;
  country: string;
  city: string;
  device: string;
  os: string;
  browser: string;
}

interface UmamiSession {
  id: string;
  screen: string;
  language: string;
  region: string;
}

async function get<T>(path: string): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    const response = await fetch(`${base}/api${path}`, { headers: { authorization: `Bearer ${key}`, accept: "application/json" } });
    if (response.ok) return (await response.json()) as T;
    if (attempt >= 4 || (response.status < 500 && response.status !== 429)) throw new Error(`${path.split("?")[0]} answered ${response.status}`);
    await new Promise((r) => setTimeout(r, 500 * attempt));
  }
}

async function all<T>(path: string, pageSize = 500): Promise<T[]> {
  const out: T[] = [];
  for (let page = 1; ; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const body = await get<{ data: T[]; count: number }>(`${path}${sep}page=${page}&pageSize=${pageSize}`);
    out.push(...body.data);
    if (out.length >= body.count || body.data.length === 0) return out;
  }
}

/** Runlight ids are hex; Umami's are UUIDs. The same Umami id always maps to the same Runlight id. */
const hexId = (value: string, length = 24) => createHash("sha256").update(value).digest("hex").slice(0, length);

// Umami names browsers and systems in its own spelling; Runlight uses these.
const BROWSERS: Record<string, string> = {
  chrome: "Chrome", crios: "Chrome", "chromium-webview": "Android WebView", safari: "Safari", ios: "Safari", "ios-webview": "Safari",
  firefox: "Firefox", fxios: "Firefox", edge: "Edge", "edge-chromium": "Edge", "edge-ios": "Edge", opera: "Opera", "opera-mini": "Opera",
  samsung: "Samsung Internet", yandexbrowser: "Yandex Browser", facebook: "Facebook", instagram: "Instagram", brave: "Brave", duckduckgo: "DuckDuckGo",
};
const SYSTEMS: Record<string, string> = {
  "Mac OS": "macOS", "iOS": "iOS", "Android OS": "Android", "Windows 10": "Windows", "Windows 11": "Windows", "Windows 7": "Windows", "Linux": "Linux", "Chrome OS": "Chrome OS",
};
const DEVICES: Record<string, string> = { desktop: "desktop", laptop: "desktop", mobile: "mobile", tablet: "tablet" };

const rl = runlight({ store: sqlite({ path: file }) });
await rl.init();
const store = rl.store;
const site = rl.sites[0]!.id;
const now = Date.now();

const links = (await all<UmamiLink>("/links", 100)).filter((l) => !l.deletedAt);
console.log(`Umami has ${links.length} links.`);

const domains = [...new Set(links.map((l) => l.customDomain?.domain).filter((d): d is string => Boolean(d)))];
for (const domain of domains) await store.addLinkDomain(stripWww(domain), site, now);
if (domains.length) console.log(`Link domains: ${domains.join(", ")}`);

let imported = 0;
let skipped = 0;
let clicks = 0;
const failures: string[] = [];

async function importLink(link: UmamiLink) {
  const id = hexId(link.id);
  if (await store.linkById(id)) {
    skipped++;
    return;
  }
  const taken = await store.linkBySlug(link.slug);
  if (taken) {
    failures.push(`${link.slug}: the slug is already used by "${taken.name}" in Runlight`);
    return;
  }
  const created = Date.parse(link.createdAt) || now;
  const end = now + 60_000;
  const [events, sessions] = await Promise.all([
    all<UmamiEvent>(`/websites/${link.id}/events?startAt=${created - 86_400_000}&endAt=${end}`),
    all<UmamiSession>(`/websites/${link.id}/sessions?startAt=${created - 86_400_000}&endAt=${end}`),
  ]);
  const sessionInfo = new Map(sessions.map((s) => [s.id, s]));
  await serially(() => writeLink(link, id, created, events, sessionInfo));
}

/** Downloads run side by side; writes to the one database connection take turns. */
let writes: Promise<unknown> = Promise.resolve();
function serially<T>(fn: () => Promise<T>): Promise<T> {
  const next = writes.then(fn, fn);
  writes = next.catch(() => {});
  return next;
}

async function writeLink(link: UmamiLink, id: string, created: number, events: UmamiEvent[], sessionInfo: Map<string, UmamiSession>) {
  await store.db.run("BEGIN");
  try {
    await store.insertLink({
      id,
      site,
      domain: link.customDomain?.domain ? stripWww(link.customDomain.domain) : "",
      slug: link.slug,
      name: (link.name || link.slug).slice(0, 100),
      url: link.url,
      createdAt: created,
      updatedAt: created,
    });
    const made = new Set<string>();
    for (const e of events) {
      const ts = Date.parse(e.createdAt);
      if (!Number.isFinite(ts)) continue;
      const session = hexId(`${link.id}:${e.sessionId}`);
      const visitor = hexId(e.sessionId, 16);
      if (!made.has(session)) {
        made.add(session);
        const info = sessionInfo.get(e.sessionId);
        const host = e.hostname || link.customDomain?.domain || "";
        const page = parsePage(new URL(`https://${host || "link.invalid"}${e.urlPath || "/"}${e.urlQuery ? `?${e.urlQuery}` : ""}`));
        const referrer = e.referrerDomain ? `https://${e.referrerDomain}${e.referrerPath || "/"}` : "";
        const country = (e.country || "").toUpperCase();
        await store.insertSession({
          id: session,
          site,
          visitor,
          startedAt: ts,
          hostname: page.hostname,
          ...attribute(page, referrer, []),
          utmSource: page.utm.source,
          utmMedium: page.utm.medium,
          utmCampaign: page.utm.campaign,
          utmTerm: page.utm.term,
          utmContent: page.utm.content,
          country,
          region: info?.region ? (info.region.includes("-") ? info.region : `${country}-${info.region}`).toUpperCase() : "",
          city: e.city || "",
          browser: BROWSERS[e.browser] ?? (e.browser ? e.browser[0]!.toUpperCase() + e.browser.slice(1) : ""),
          browserVersion: "",
          os: SYSTEMS[e.os] ?? e.os ?? "",
          osVersion: "",
          device: DEVICES[e.device] ?? e.device ?? "",
          screen: info?.screen ?? "",
          language: info?.language ?? "",
        });
        await store.db.run("UPDATE rl_sessions SET imported = 1 WHERE id = ?", [session]);
      }
      await store.touchSession(session, ts, "click", e.urlPath || "/");
      await store.insertEvent({
        site,
        ts,
        kind: "click",
        visitor,
        session,
        pageview: "",
        path: (e.urlPath || "/").slice(0, 1000),
        hostname: e.hostname || "",
        title: "",
        name: link.slug,
        props: null,
        engagedMs: 0,
        scroll: null,
        link: id,
      });
      clicks++;
    }
    await store.db.run("COMMIT");
    imported++;
  } catch (error) {
    await store.db.run("ROLLBACK");
    failures.push(`${link.slug}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

// A few at a time, to be kind to the Umami server.
const queue = [...links];
await Promise.all(
  Array.from({ length: 3 }, async () => {
    for (let link = queue.shift(); link; link = queue.shift()) {
      try {
        await importLink(link);
      } catch (error) {
        failures.push(`${link.slug}: ${error instanceof Error ? error.message : String(error)}`);
      }
      const done = imported + skipped + failures.length;
      if (done % 50 === 0) console.log(`  ${done} of ${links.length}`);
    }
  }),
);

console.log(`Imported ${imported} links with ${clicks} clicks. Skipped ${skipped} already imported.`);
if (failures.length) {
  console.log(`${failures.length} could not be imported:`);
  for (const f of failures) console.log(`  ${f}`);
}
