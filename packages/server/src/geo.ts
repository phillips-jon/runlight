/**
 * Location for servers with no platform headers (Cloudflare, Vercel, and
 * Netlify send their own, and those always win). Uses DB-IP's free
 * databases (CC BY 4.0, https://db-ip.com), downloaded on first start and
 * refreshed each month, or any MMDB file the owner points at.
 */
import { createWriteStream, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync } from "node:fs";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createGunzip } from "node:zlib";
import { Reader, type CityResponse } from "mmdb-lib";
import type { GeoLookup, Location } from "@runlight/sdk";

export type GeoMode = "city" | "country" | "off";

/** DB-IP's records follow MaxMind's city layout, with names but no subdivision codes. */
type Record = CityResponse;

/** "2026-10", the month DB-IP names each release after. */
const month = (ts: number) => new Date(ts).toISOString().slice(0, 7);

/** A city as people say it: DB-IP adds districts in brackets, as in "Toronto (Old Toronto)". */
const cityName = (name: string) => name.replace(/\s*\([^)]*\)\s*$/, "").trim();

export function lookupFrom(reader: Reader<Record>): GeoLookup {
  return (ip: string): Partial<Location> | null => {
    let found: Record | null = null;
    try {
      found = reader.get(ip);
    } catch {
      return null;
    }
    if (!found?.country?.iso_code) return null;
    const sub = found.subdivisions?.[0];
    return {
      country: found.country.iso_code,
      region: sub?.iso_code ?? sub?.names?.en ?? "",
      city: cityName(found.city?.names?.en ?? ""),
    };
  };
}

/**
 * Keeps a DB-IP database current in `dir` and answers lookups from it. Lookups
 * return nothing until the first download finishes, so startup never waits.
 */
export class Geo {
  private reader: Reader<Record> | null = null;
  private loaded = "";
  private fetching: Promise<void> | null = null;
  readonly lookup: GeoLookup = (ip) => (this.reader ? lookupFrom(this.reader)(ip) : null);

  constructor(
    private readonly dir: string,
    private readonly mode: Exclude<GeoMode, "off">,
    private readonly log: (line: string) => void = console.log,
    private readonly download: typeof fetch = fetch,
  ) {
    mkdirSync(dir, { recursive: true });
  }

  private file(release: string) {
    return path.join(this.dir, `dbip-${this.mode}-lite-${release}.mmdb`);
  }

  /** Opens the newest file on disk, then fetches this month's if it is missing. Safe to call often. */
  async refresh(now = Date.now()): Promise<void> {
    const current = month(now);
    if (this.loaded === current) return;
    const newest = readdirSync(this.dir)
      .filter((f) => f.startsWith(`dbip-${this.mode}-lite-`) && f.endsWith(".mmdb"))
      .sort()
      .pop();
    if (newest && newest !== path.basename(this.file(this.loaded || "none"))) this.open(path.join(this.dir, newest));
    if (existsSync(this.file(current))) return;
    this.fetching ??= this.fetch(current, now).finally(() => (this.fetching = null));
    return this.fetching;
  }

  private open(file: string) {
    this.reader = new Reader<Record>(readFileSync(file));
    this.loaded = path.basename(file).slice(-12, -5);
  }

  private async fetch(release: string, now: number): Promise<void> {
    // A new month's file appears a day or so after the month starts; until then, last month's is current.
    const tries = [release, month(Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth() - 1, 15))];
    for (const name of tries) {
      if (existsSync(this.file(name))) {
        if (this.loaded !== name) this.open(this.file(name));
        return;
      }
      const url = `https://download.db-ip.com/free/dbip-${this.mode}-lite-${name}.mmdb.gz`;
      try {
        const answer = await this.download(url, { signal: AbortSignal.timeout(10 * 60_000) });
        if (!answer.ok || !answer.body) continue;
        const partial = `${this.file(name)}.partial`;
        await pipeline(Readable.fromWeb(answer.body as never), createGunzip(), createWriteStream(partial));
        new Reader(readFileSync(partial));
        renameSync(partial, this.file(name));
        this.open(this.file(name));
        // Older releases go once the new one opens.
        for (const old of readdirSync(this.dir)) if (old.startsWith(`dbip-${this.mode}-lite-`) && old !== path.basename(this.file(name))) rmSync(path.join(this.dir, old), { force: true });
        this.log(`Runlight: location data from DB-IP (${name}) is ready.`);
        return;
      } catch (error) {
        this.log(`Runlight: could not download location data from ${url}: ${(error as Error).message}`);
        rmSync(`${this.file(name)}.partial`, { force: true });
      }
    }
  }
}

/** A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City. */
export function fileLookup(file: string): GeoLookup {
  return lookupFrom(new Reader<Record>(readFileSync(file)));
}
