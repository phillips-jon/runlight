import { getJson } from "./http.js";
import { ImportError, type Importer } from "./types.js";

/** https://developers.rebrandly.com/docs */
const BASE = "https://api.rebrandly.com/v1";
const PAGE = 25;

interface RebrandlyLink {
  id: string;
  title?: string | null;
  slashtag: string;
  destination: string;
  domain?: { fullName?: string };
  createdAt: string;
}

/**
 * Rebrandly. Its API gives only total clicks, with no dates, so links come
 * across with their slugs and domains and start their history fresh.
 */
export const rebrandly: Importer = {
  async step({ credentials, cursor }) {
    const key = credentials.apiKey?.trim();
    if (!key) throw new ImportError("Enter a Rebrandly API key", "import_key", { service: "Rebrandly" });
    const headers: Record<string, string> = { apikey: key };
    if (credentials.workspace?.trim()) headers.workspace = credentials.workspace.trim();
    const last = cursor ? `&last=${encodeURIComponent(cursor)}` : "";
    const list = await getJson<RebrandlyLink[]>(`${BASE}/links?orderBy=createdAt&orderDir=desc&limit=${PAGE}${last}`, { headers });
    const links = list.map((l) => ({
      link: { sourceId: l.id, slug: l.slashtag, domain: l.domain?.fullName ?? "", name: l.title || "", url: l.destination, createdAt: Date.parse(l.createdAt) || Date.now() },
    }));
    const end = list[list.length - 1];
    return { cursor: list.length === PAGE && end ? end.id : null, total: null, links };
  },
};
