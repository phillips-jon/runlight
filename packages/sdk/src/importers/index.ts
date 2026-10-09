import type { Runlight } from "../runlight.js";
import { ImportError, type Credentials, type Importer, type ImportStep } from "./types.js";
import { bitly } from "./bitly.js";
import { dub } from "./dub.js";
import { rebrandly } from "./rebrandly.js";
import { shortio } from "./shortio.js";
import { umami } from "./umami.js";
import { importedLinkId, sameUrl, writeLink } from "./write.js";

export const IMPORTERS: Record<string, Importer> = { umami, dub, bitly, shortio, rebrandly };

/**
 * One step of an import: fetch the next few links from the source, write
 * each with its history, and report progress. The cursor carries where to
 * pick up, so the page calls this until the cursor comes back null.
 */
export async function importStep(
  runlight: Runlight,
  site: string,
  source: string,
  credentials: Credentials,
  cursor: string | null,
  done: number,
): Promise<ImportStep> {
  // Own keys only: a source named "constructor" is not an importer.
  const importer = Object.hasOwn(IMPORTERS, source) ? IMPORTERS[source] : undefined;
  if (!importer) throw new ImportError(`Runlight cannot import from ${source}`, "import_source", { source });
  await runlight.init();
  const known = async (sourceId: string, slug?: string, url?: string) => {
    if (await runlight.store.linkById(await importedLinkId(source, sourceId))) return true;
    if (!slug || !url) return false;
    const taken = await runlight.store.linkBySlug(slug);
    return Boolean(taken && sameUrl(taken.url, url));
  };
  const result = await importer.step({ credentials, cursor, known, now: runlight.now() });
  // A total that is not a number is as good as none.
  const total = typeof result.total === "number" && Number.isFinite(result.total) ? result.total : null;
  const step: ImportStep = { cursor: result.cursor, done, total, links: 0, clicks: 0, skipped: 0, failed: [] };
  for (const item of result.links) {
    if (item.known) {
      step.done++;
      step.skipped++;
      continue;
    }
    const written = await writeLink(runlight, site, source, item.link, item);
    step.done++;
    if (written.status === "created") {
      step.links++;
      step.clicks += written.clicks;
    } else if (written.status === "skipped") step.skipped++;
    else step.failed.push({ slug: item.link.slug, reason: written.reason ?? "", ...(written.code ? { code: written.code, params: written.params ?? {} } : {}) });
  }
  // Links the source skipped (deleted ones) still count toward progress.
  if (!result.cursor && total !== null) step.done = Math.max(step.done, total);
  return step;
}

export { ImportError } from "./types.js";
