package sh.runlight.importers;

import java.util.List;
import java.util.Map;
import sh.runlight.Json;
import sh.runlight.Time;
import sh.runlight.http.Fetcher;
import sh.runlight.store.SqlStore;
import sh.runlight.store.Stores;

/**
 * What the imports need of a Runlight, played by a store and a site of the test's choosing, with a
 * clock the test moves, as helpers.ts's setup() is for these tests.
 */
final class TestHost implements Host {
  static final long DAY = 86_400_000L;

  final SqlStore store;
  final Fetcher fetcher;
  final Map<String, Object> site;
  long now;
  Long cutoff;
  int forgotten;
  private boolean ready;

  TestHost(SqlStore store, Fetcher fetcher, long now, List<String> hostnames, String timezone) {
    this.store = store;
    this.fetcher = fetcher;
    this.now = now;
    this.site =
        Json.object(
            "id", "default", "name", "Example", "hostnames", hostnames, "timezone", timezone);
  }

  TestHost(Fetcher fetcher, long now) {
    this(Stores.sqlite(":memory:"), fetcher, now, List.of(), "UTC");
  }

  @Override
  public void init() {
    if (!ready) {
      store.migrate();
      store.upsertSite(site, now);
      ready = true;
    }
  }

  @Override
  public SqlStore store() {
    return store;
  }

  @Override
  public long now() {
    return now;
  }

  @Override
  public Fetcher fetcher() {
    return fetcher;
  }

  @Override
  public Map<String, Object> site(String id) {
    return site.get("id").equals(id) ? site : null;
  }

  @Override
  public Long retentionCutoff(String siteId) {
    return cutoff;
  }

  @Override
  public void forgetLinkDomains() {
    forgotten++;
  }

  /** A query over local dates of the site, as the dashboard's from and to make one. */
  Map<String, Object> query(String from, String to) {
    String tz = (String) site.get("timezone");
    return Json.object(
        "site",
        "default",
        "from",
        Time.startOf(from, tz),
        "to",
        Time.startOf(Time.addDays(to, 1), tz),
        "filters",
        Json.array());
  }

  List<Object> values(Map<String, Object> query, String dimension, String field) {
    List<Object> out = new java.util.ArrayList<>();
    for (Map<String, Object> r : store.breakdown(query, dimension, 10, 0)) {
      out.add(r.get(field));
    }
    return out;
  }

  List<Object> values(Map<String, Object> query, String dimension) {
    return values(query, dimension, "value");
  }
}
