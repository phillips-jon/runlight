import { HttpError, getJson, pause } from "./http.js";
import { ImportError, type DailyClicks, type Importer } from "./types.js";

/** https://developers.short.io/reference */
const API = "https://api.short.io";
const STATS = "https://statistics.short.io/statistics";
const PAGE = 8;
/** The statistics API allows 60 requests a minute. */
const STATS_GAP_MS = 1050;

interface ShortLink {
  idString?: string;
  id: string | number;
  path: string;
  originalURL: string;
  title?: string | null;
  createdAt: string;
}

type Point = { x: string | number; y: number };

/**
 * Short.io. Links are listed per domain. Daily click counts come from the
 * statistics API, paced to its limit of 60 requests a minute, so a step
 * holds only a few links.
 */
export const shortio: Importer = {
  async step({ credentials, cursor, known }) {
    const key = credentials.apiKey?.trim();
    if (!key) throw new ImportError("Enter a Short.io secret API key");
    const headers = { authorization: key };
    const state = cursor
      ? (JSON.parse(cursor) as { domains: Array<{ id: number; hostname: string }>; d: number; token: string | null; total: number | null })
      : {
          domains: (await getJson<Array<{ id: number; hostname: string }>>(`${API}/api/domains?limit=300`, { headers })).map((d) => ({ id: d.id, hostname: d.hostname })),
          d: 0,
          token: null,
          total: null,
        };
    const domain = state.domains[state.d];
    if (!domain) return { cursor: null, total: null, links: [] };

    const token = state.token ? `&pageToken=${encodeURIComponent(state.token)}` : "";
    const page = await getJson<{ count?: number; links: ShortLink[]; nextPageToken?: string | null }>(
      `${API}/api/links?domain_id=${domain.id}&limit=${PAGE}${token}`,
      { headers },
    );

    const links = [];
    for (const l of page.links) {
      const id = String(l.idString ?? l.id);
      if (await known(id, l.path, l.originalURL)) {
        links.push({ link: { sourceId: id, slug: l.path, domain: "", name: "", url: l.originalURL, createdAt: 0 }, known: true });
        continue;
      }
      let daily: DailyClicks[] | undefined;
      try {
        await pause(STATS_GAP_MS);
        const body = await getJson<{ clickStatistics?: Point[] | { datasets?: Array<{ data?: Point[] }> } }>(`${STATS}/link/${encodeURIComponent(id)}/by_interval`, {
          method: "POST",
          headers: { ...headers, "content-type": "application/json" },
          body: JSON.stringify({ period: "total", clicksChartInterval: "day", tz: "UTC" }),
        });
        const raw = body.clickStatistics;
        const points: Point[] = Array.isArray(raw) ? raw : (raw?.datasets?.[0]?.data ?? []);
        daily = points
          .filter((p) => p.y > 0)
          .map((p) => ({ day: new Date(typeof p.x === "number" ? p.x : Date.parse(p.x)).toISOString().slice(0, 10), clicks: p.y }));
      } catch (error) {
        if (!(error instanceof HttpError) || error.status === 401) throw error;
      }
      links.push({
        link: { sourceId: id, slug: l.path, domain: domain.hostname, name: l.title || "", url: l.originalURL, createdAt: Date.parse(l.createdAt) || Date.now() },
        daily,
      });
    }

    const more = page.nextPageToken ? { ...state, token: page.nextPageToken } : state.d + 1 < state.domains.length ? { ...state, d: state.d + 1, token: null } : null;
    return { cursor: more ? JSON.stringify(more) : null, total: null, links };
  },
};
