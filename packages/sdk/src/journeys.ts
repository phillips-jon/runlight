/**
 * Journeys: the paths visits take through a site, page by page. Each visit's
 * pages are read in order, a page seen twice in a row (a refresh) counts once,
 * and the path is cut to a number of steps, from a start page and to an end
 * page when those are chosen. The answer lines the paths up in columns, one
 * per step, with the flows between them, as Umami's journeys do.
 */
export interface JourneyOptions {
  steps: number;
  start?: string;
  end?: string;
  /** Only paths that show this page at this step (0-based), to follow one page. */
  through?: { step: number; value: string };
}

export interface JourneyColumn {
  /** The pages seen at this step, most visits first, with the rest as "" (other pages). */
  items: Array<{ value: string; visits: number }>;
  /** Visits that reached this step. */
  visits: number;
  /** Visits that went no further than this step. */
  left: number;
}

export interface Journeys {
  visits: number;
  columns: JourneyColumn[];
  /** Visits moving from a page at one step to a page at the next. "" is any other page. */
  links: Array<{ step: number; from: string; to: string; visits: number }>;
  /** The commonest whole paths. */
  paths: Array<{ pages: string[]; visits: number }>;
}

/** How many pages of a visit to read: enough to find a start page and still have the steps after it. */
export const PAGES_PER_VISIT = 40;
const TOP = 8;

export function journeys(rows: Array<{ session: string; path: string }>, options: JourneyOptions): Journeys {
  const steps = Math.min(Math.max(Math.floor(options.steps) || 5, 2), 8);
  // Group each visit's pages, dropping refreshes.
  const visits = new Map<string, string[]>();
  for (const row of rows) {
    const pages = visits.get(row.session) ?? [];
    if (pages[pages.length - 1] !== row.path) pages.push(row.path);
    visits.set(row.session, pages);
  }
  const sequences: string[][] = [];
  // Visits that went on past the last step shown, so they never count as having gone no further.
  const cut = new Set<string[]>();
  for (let pages of visits.values()) {
    if (options.start) {
      const at = pages.indexOf(options.start);
      if (at < 0) continue;
      pages = pages.slice(at);
    }
    if (options.end) {
      const at = pages.indexOf(options.end);
      if (at < 0) continue;
      pages = pages.slice(0, at + 1);
    }
    const more = pages.length > steps;
    pages = pages.slice(0, steps);
    if (options.through && pages[options.through.step] !== options.through.value) continue;
    sequences.push(pages);
    if (more) cut.add(pages);
  }

  const columns: JourneyColumn[] = [];
  const kept: Array<Set<string>> = [];
  for (let i = 0; i < steps; i++) {
    const counts = new Map<string, number>();
    let reached = 0;
    let left = 0;
    for (const s of sequences) {
      if (s.length <= i) continue;
      reached++;
      if (s.length === i + 1 && !cut.has(s)) left++;
      counts.set(s[i]!, (counts.get(s[i]!) ?? 0) + 1);
    }
    const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
    const top = sorted.slice(0, TOP);
    const rest = sorted.slice(TOP).reduce((n, [, v]) => n + v, 0);
    kept.push(new Set(top.map(([v]) => v)));
    if (!reached) break;
    columns.push({ items: [...top.map(([value, visits]) => ({ value, visits })), ...(rest ? [{ value: "", visits: rest }] : [])], visits: reached, left });
  }

  const linkCounts = new Map<string, { step: number; from: string; to: string; visits: number }>();
  for (const s of sequences) {
    for (let i = 0; i + 1 < s.length && i + 1 < columns.length; i++) {
      const from = kept[i]!.has(s[i]!) ? s[i]! : "";
      const to = kept[i + 1]!.has(s[i + 1]!) ? s[i + 1]! : "";
      const key = `${i}\u0000${from}\u0000${to}`;
      const link = linkCounts.get(key) ?? { step: i, from, to, visits: 0 };
      link.visits++;
      linkCounts.set(key, link);
    }
  }

  const pathCounts = new Map<string, { pages: string[]; visits: number }>();
  for (const s of sequences) {
    const key = s.join("\u0000");
    const path = pathCounts.get(key) ?? { pages: s, visits: 0 };
    path.visits++;
    pathCounts.set(key, path);
  }

  return {
    visits: sequences.length,
    columns,
    links: [...linkCounts.values()].sort((a, b) => a.step - b.step || b.visits - a.visits),
    paths: [...pathCounts.entries()].sort(([a, x], [b, y]) => y.visits - x.visits || (a < b ? -1 : 1)).map(([, p]) => p).slice(0, 20),
  };
}
