/** A link as another shortener describes it, before it becomes a Runlight link. */
export interface ForeignLink {
  /** The other service's id, so a re-run recognises the link. */
  sourceId: string;
  slug: string;
  /** The short link's domain there. Shortener-owned domains (bit.ly, dub.sh) are not kept. */
  domain: string;
  name: string;
  url: string;
  createdAt: number;
}

/** One click with whatever the other service knows about it. */
export interface ForeignClick {
  ts: number;
  /** Groups clicks into one visit, when the service has visits. */
  visit?: string;
  referrer?: string;
  /** Path and query of the short URL as clicked, for campaign tags. */
  path?: string;
  query?: string;
  country?: string;
  region?: string;
  city?: string;
  browser?: string;
  os?: string;
  device?: string;
  screen?: string;
  language?: string;
}

/** Clicks per day, for services that only keep counts. */
export interface DailyClicks {
  /** YYYY-MM-DD, UTC. */
  day: string;
  clicks: number;
}

/** What one step of an import did. The page keeps calling until `cursor` is null. */
export interface ImportStep {
  cursor: string | null;
  /** Links handled so far and in all, for the progress bar. Total is null when the service does not say. */
  done: number;
  total: number | null;
  links: number;
  clicks: number;
  skipped: number;
  failed: Array<{ slug: string; reason: string; code?: string; params?: Record<string, string> }>;
}

export type Credentials = Record<string, string>;

/**
 * One shortener. `step` does a bounded slice of work (a few links) and hands
 * back a cursor, so imports run in small requests that fit any host's time
 * limit and can show progress. Credentials come with every step and are
 * never stored.
 */
export interface Importer {
  step(input: {
    credentials: Credentials;
    cursor: string | null;
    /**
     * Whether a link from this source is already in Runlight, so its history
     * need not be fetched again: imported from this source before, or the
     * same slug to the same destination brought in some other way.
     */
    known: (sourceId: string, slug?: string, url?: string) => Promise<boolean>;
  }): Promise<{
    cursor: string | null;
    total: number | null;
    links: Array<{ link: ForeignLink; clicks?: ForeignClick[]; daily?: DailyClicks[]; known?: boolean }>;
  }>;
}

/** Why an import stopped, as a code the dashboard says in its own words. */
export class ImportError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly params: Record<string, string> = {},
  ) {
    super(message);
  }
}
