import { HttpError, getJson } from "./http.js";
import { ImportError, type DailyClicks, type ForeignClick, type Importer } from "./types.js";

/** https://dub.co/docs/api-reference */
const BASE = "https://api.dub.co";
const PAGE = 10;

interface DubLink {
  id: string;
  domain: string;
  key: string;
  url: string;
  title: string | null;
  createdAt: string;
}

interface DubEvent {
  timestamp: string;
  click?: { id?: string; country?: string; city?: string; region?: string; device?: string; browser?: string; os?: string; referer?: string; refererUrl?: string };
}

/** What the account's plan lets us read: every click (Business), daily counts (Pro), or neither (Free). */
type History = "events" | "daily" | "none" | null;

/**
 * Dub. Links come from GET /links (cursor pages of up to 100, archived
 * included). Click history is per click from /events where the plan allows,
 * else daily counts from /analytics, else none; the first link decides.
 */
export const dub: Importer = {
  async step({ credentials, cursor, known }) {
    const key = credentials.apiKey?.trim();
    if (!key) throw new ImportError("Enter a Dub API key", "import_key", { service: "Dub" });
    const headers = { authorization: `Bearer ${key}` };
    const state = cursor ? (JSON.parse(cursor) as { after: string | null; history: History }) : { after: null, history: null as History };
    const after = state.after ? `&startingAfter=${encodeURIComponent(state.after)}` : "";
    const list = await getJson<DubLink[]>(`${BASE}/links?pageSize=${PAGE}&showArchived=true${after}`, { headers });

    const links = [];
    for (const l of list) {
      if (await known(l.id, l.key, l.url)) {
        links.push({ link: { sourceId: l.id, slug: l.key, domain: "", name: "", url: l.url, createdAt: 0 }, known: true });
        continue;
      }
      let clicks: ForeignClick[] | undefined;
      let daily: DailyClicks[] | undefined;
      if (state.history === null || state.history === "events") {
        try {
          clicks = [];
          for (let page = 1; ; page++) {
            const events = await getJson<DubEvent[]>(
              `${BASE}/events?event=clicks&linkId=${encodeURIComponent(l.id)}&interval=all&sortOrder=asc&limit=1000&page=${page}`,
              { headers },
            );
            for (const e of events) {
              clicks.push({
                ts: Date.parse(e.timestamp),
                visit: e.click?.id,
                referrer: e.click?.refererUrl || (e.click?.referer && e.click.referer !== "(direct)" ? `https://${e.click.referer}/` : ""),
                country: e.click?.country,
                region: e.click?.region,
                city: e.click?.city,
                device: e.click?.device?.toLowerCase(),
                browser: e.click?.browser,
                os: e.click?.os,
              });
            }
            if (events.length < 1000) break;
          }
          state.history = "events";
        } catch (error) {
          if (!(error instanceof HttpError) || error.status === 401) throw error;
          clicks = undefined;
          state.history = "daily";
        }
      }
      if (state.history === "daily") {
        try {
          const series = await getJson<Array<{ start: string; clicks: number }>>(
            `${BASE}/analytics?event=clicks&groupBy=timeseries&interval=all&linkId=${encodeURIComponent(l.id)}`,
            { headers },
          );
          daily = series.filter((p) => p.clicks > 0).map((p) => ({ day: p.start.slice(0, 10), clicks: p.clicks }));
        } catch (error) {
          if (!(error instanceof HttpError) || error.status === 401) throw error;
          state.history = "none";
        }
      }
      links.push({
        link: { sourceId: l.id, slug: l.key, domain: l.domain, name: l.title || "", url: l.url, createdAt: Date.parse(l.createdAt) || Date.now() },
        clicks,
        daily,
      });
    }
    const last = list[list.length - 1];
    return { cursor: list.length === PAGE && last ? JSON.stringify({ after: last.id, history: state.history }) : null, total: null, links };
  },
};
