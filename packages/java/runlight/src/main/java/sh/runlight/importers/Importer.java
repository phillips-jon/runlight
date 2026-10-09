package sh.runlight.importers;

import java.util.Map;

/**
 * One shortener. {@code step} does a bounded slice of work (a few links) and hands back a cursor,
 * so imports run in small requests that fit any host's time limit and can show progress.
 * Credentials come with every step and are never stored.
 *
 * <p>The shapes are TS's, as maps with the same keys:
 *
 * <ul>
 *   <li>ForeignLink: {@code sourceId} (the other service's id, so a re-run recognises the link),
 *       {@code slug}, {@code domain} (the short link's domain there; shortener-owned domains such
 *       as bit.ly and dub.sh are not kept), {@code name}, {@code url}, {@code createdAt} (ms).
 *   <li>ForeignClick: {@code ts} (ms), and whichever of {@code visit} (groups clicks into one
 *       visit), {@code referrer}, {@code path}, {@code query} (path and query of the short URL as
 *       clicked, for campaign tags), {@code country}, {@code region}, {@code city}, {@code
 *       browser}, {@code os}, {@code device}, {@code screen}, and {@code language} the service
 *       knows. A field it does not know is left out.
 *   <li>DailyClicks: {@code day} (YYYY-MM-DD, UTC) and {@code clicks}, for services that only keep
 *       counts.
 *   <li>ImportStep: {@code cursor}, {@code done}, {@code total}, {@code links}, {@code clicks},
 *       {@code skipped}, {@code failed}.
 * </ul>
 */
public interface Importer {
  /**
   * Whether a link from this source is already in Runlight, so its history need not be fetched
   * again: imported from this source before, or the same slug to the same destination brought in
   * some other way. The values are as the source sent them.
   */
  @FunctionalInterface
  interface Known {
    boolean known(Object sourceId, Object slug, Object url);
  }

  /**
   * One step: {@code cursor}, {@code total}, and {@code links}, each {@code {link, clicks?, daily?,
   * known?}}.
   */
  Map<String, Object> step(Map<String, String> credentials, String cursor, Known known);
}
