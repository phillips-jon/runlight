package sh.runlight.importers;

import java.util.Map;
import sh.runlight.http.Fetcher;
import sh.runlight.store.SqlStore;

/**
 * What the imports read from the Runlight they write into: its store, clock, and fetcher, its
 * sites, and how long each keeps its visits. sh.runlight.Runlight provides each under the same
 * name, so it can implement this as it is.
 */
public interface Host {
  /** Makes sure the store is ready, as runlight.init() does. */
  void init();

  SqlStore store();

  /** Runlight's clock, in milliseconds. */
  long now();

  /** Every outgoing request goes through this. */
  Fetcher fetcher();

  /** A site as Runlight serves it ({@code id}, {@code hostnames}, {@code timezone}), or null. */
  Map<String, Object> site(String id);

  /** The oldest time a site keeps, or null when it keeps everything. */
  Long retentionCutoff(String siteId);

  /** Forgets the cached link domains, after an import adds one. */
  void forgetLinkDomains();
}
