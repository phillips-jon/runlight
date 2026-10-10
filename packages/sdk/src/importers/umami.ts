import { getJson } from "./http.js";
import { ImportError, type ForeignClick, type Importer } from "./types.js";

interface UmamiLink {
  id: string;
  name: string;
  url: string;
  slug: string;
  createdAt: string;
  deletedAt: string | null;
  customDomain?: { domain: string } | null;
}

interface UmamiEvent {
  sessionId: string;
  createdAt: string;
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

const PAGE = 5;

/**
 * Signs in to an Umami: an API key, or a username and password (stock
 * self-hosted Umami has no API keys). A token from an earlier step is reused.
 */
export async function umamiSignIn(credentials: Record<string, string>, token?: string): Promise<{ base: string; token: string }> {
  const base = (credentials.url ?? "").trim().replace(/\/+$/, "");
  if (!/^https:\/\/[^/]+/.test(base)) throw new ImportError("Enter your Umami address, like https://stats.example.com", "import_umami_address");
  const key = credentials.apiKey?.trim() ?? "";
  if (key || token) return { base, token: key || token! };
  if (!credentials.username || !credentials.password) throw new ImportError("Enter an API key, or a username and password", "import_umami_login");
  const login = await getJson<{ token?: unknown }>(`${base}/api/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: credentials.username, password: credentials.password }),
  });
  // A sign-in that answers without a token was refused, whatever its status.
  if (typeof login?.token !== "string" || !login.token) throw new ImportError("The key or sign-in was refused", "import_refused");
  return { base, token: login.token };
}

/**
 * Umami v3 (and forks with custom link domains). Signs in with an API key,
 * or with a username and password (stock self-hosted Umami has no API keys).
 * In Umami a link's clicks are events stored under the link's id, with the
 * visitor's session holding place and device.
 */
export const umami: Importer = {
  async step({ credentials, cursor, known, now }) {
    // A key comes with every step; only a sign-in token, which expires, rides in the cursor.
    const saved = cursor ? (JSON.parse(cursor) as { page: number; token?: string }) : { page: 1 };
    const key = credentials.apiKey?.trim() ?? "";
    const { base, token } = await umamiSignIn(credentials, saved.token);
    const state = { page: saved.page, token };
    const headers = { authorization: `Bearer ${state.token}` };
    const list = await getJson<{ data: UmamiLink[]; count?: unknown }>(`${base}/api/links?page=${state.page}&pageSize=${PAGE}`, { headers });

    const all = async <T>(path: string): Promise<T[]> => {
      const out: T[] = [];
      for (let page = 1; ; page++) {
        const body = await getJson<{ data: T[]; count: number }>(`${base}/api${path}&page=${page}&pageSize=1000`, { headers });
        out.push(...body.data);
        if (out.length >= body.count || body.data.length === 0) return out;
      }
    };

    const links = [];
    for (const l of list.data) {
      if (l.deletedAt) continue;
      if (await known(l.id, l.slug, l.url)) {
        links.push({ link: { sourceId: l.id, slug: l.slug, domain: "", name: l.name, url: l.url, createdAt: 0 }, known: true });
        continue;
      }
      const created = Date.parse(l.createdAt) || now;
      const range = `startAt=${created - 86_400_000}&endAt=${now + 60_000}`;
      const [events, sessions] = await Promise.all([
        all<UmamiEvent>(`/websites/${l.id}/events?${range}`),
        all<UmamiSession>(`/websites/${l.id}/sessions?${range}`),
      ]);
      const info = new Map(sessions.map((s) => [s.id, s]));
      const clicks: ForeignClick[] = events.map((e) => {
        const s = info.get(e.sessionId);
        return {
          ts: Date.parse(e.createdAt),
          visit: e.sessionId,
          referrer: e.referrerDomain ? `https://${e.referrerDomain}${e.referrerPath || "/"}` : "",
          path: e.urlPath,
          query: e.urlQuery,
          country: e.country,
          region: s?.region,
          city: e.city,
          browser: e.browser,
          os: e.os,
          device: e.device,
          screen: s?.screen,
          language: s?.language,
        };
      });
      links.push({
        link: { sourceId: l.id, slug: l.slug, domain: l.customDomain?.domain ?? "", name: l.name, url: l.url, createdAt: created },
        clicks,
      });
    }
    // Without a count there is no total, and a full page may have more after it.
    const count = typeof list.count === "number" && Number.isFinite(list.count) ? list.count : null;
    const more = count === null ? list.data.length === PAGE : state.page * PAGE < count && list.data.length > 0;
    return { cursor: more ? JSON.stringify(key ? { page: state.page + 1 } : { page: state.page + 1, token: state.token }) : null, total: count, links };
  },
};
