import type { Runlight } from "../runlight.js";
import { ImportError, type Credentials, type Importer, type ImportStep } from "./types.js";
import { bitly } from "./bitly.js";
import { dub } from "./dub.js";
import { rebrandly } from "./rebrandly.js";
import { shortio } from "./shortio.js";
import { umami } from "./umami.js";
import { importedLinkId, writeLink } from "./write.js";

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
  const importer = IMPORTERS[source];
  if (!importer) throw new ImportError(`Runlight cannot import from ${source}`);
  await runlight.init();
  const known = async (sourceId: string) => Boolean(await runlight.store.linkById(await importedLinkId(source, sourceId)));
  const result = await importer.step({ credentials, cursor, known });
  const step: ImportStep = { cursor: result.cursor, done, total: result.total, links: 0, clicks: 0, skipped: 0, failed: [] };
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
    else step.failed.push({ slug: item.link.slug, reason: written.reason ?? "" });
  }
  // Links the source skipped (deleted ones) still count toward progress.
  if (!result.cursor && result.total !== null) step.done = Math.max(step.done, result.total);
  return step;
}

export { ImportError } from "./types.js";
