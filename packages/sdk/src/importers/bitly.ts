import { HttpError, getJson } from "./http.js";
import { ImportError, type Importer } from "./types.js";

/** https://dev.bitly.com/api-reference */
const BASE = "https://api-ssl.bitly.com/v4";
const PAGE = 20;

interface Bitlink {
  id: string;
  link: string;
  long_url: string;
  title: string | null;
  created_at: string;
  is_deleted?: boolean;
  custom_bitlinks?: string[];
}

/** A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale". */
function split(value: string): { domain: string; slug: string } {
  const bare = value.replace(/^https?:\/\//, "");
  const at = bare.indexOf("/");
  return at < 0 ? { domain: bare, slug: "" } : { domain: bare.slice(0, at), slug: bare.slice(at + 1).replace(/\/$/, "") };
}

/**
 * Bitly. Links are listed per group (every group in the account), with
 * archived ones. Bitly only keeps daily click counts, and only as far back
 * as the account's plan allows. A custom back-half or branded domain wins
 * over the random bit.ly one.
 */
export const bitly: Importer = {
  async step({ credentials, cursor, known, now }) {
    const token = credentials.token?.trim() || credentials.apiKey?.trim();
    if (!token) throw new ImportError("Enter a Bitly access token", "import_key", { service: "Bitly" });
    const headers = { authorization: `Bearer ${token}` };
    const state = cursor
      ? (JSON.parse(cursor) as { groups: string[]; g: number; after: string | null })
      : { groups: (await getJson<{ groups: Array<{ guid: string }> }>(`${BASE}/groups`, { headers })).groups.map((g) => g.guid), g: 0, after: null };
    const group = state.groups[state.g];
    if (!group) return { cursor: null, total: null, links: [] };

    const after = state.after ? `&search_after=${encodeURIComponent(state.after)}` : "";
    const page = await getJson<{ links: Bitlink[]; pagination?: { search_after?: string } }>(
      `${BASE}/groups/${group}/bitlinks?size=${PAGE}&archived=both${after}`,
      { headers },
    );

    const links = [];
    for (const b of page.links) {
      if (b.is_deleted) continue;
      if (await known(b.id, split(b.custom_bitlinks?.[0] ?? b.id).slug, b.long_url)) {
        links.push({ link: { sourceId: b.id, slug: "", domain: "", name: "", url: b.long_url, createdAt: 0 }, known: true });
        continue;
      }
      const short = split(b.custom_bitlinks?.[0] ?? b.id);
      let daily;
      try {
        const clicks = await getJson<{ link_clicks: Array<{ clicks: number; date: string }> }>(
          `${BASE}/bitlinks/${encodeURIComponent(b.id)}/clicks?unit=day&units=-1`,
          { headers },
        );
        daily = clicks.link_clicks.filter((c) => c.clicks > 0).map((c) => ({ day: c.date.slice(0, 10), clicks: c.clicks }));
      } catch (error) {
        // Plans without analytics refuse this; the link still comes across.
        if (!(error instanceof HttpError) || error.status === 401) throw error;
      }
      links.push({
        link: { sourceId: b.id, slug: short.slug, domain: short.domain, name: b.title || "", url: b.long_url, createdAt: Date.parse(b.created_at) || now },
        daily,
      });
    }

    const next = page.pagination?.search_after && page.links.length === PAGE ? page.pagination.search_after : null;
    const more = next ? { ...state, after: next } : state.g + 1 < state.groups.length ? { ...state, g: state.g + 1, after: null } : null;
    return { cursor: more ? JSON.stringify(more) : null, total: null, links };
  },
};
