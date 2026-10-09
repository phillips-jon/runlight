package sh.runlight.importers;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.Sources;
import sh.runlight.Time;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Url;
import sh.runlight.store.SqlStore;

/**
 * Visit history from Umami: pageviews and custom events with where each visit came from, its place,
 * and its device, written as imported visits so the dashboard's history does not start the day
 * Runlight was installed.
 *
 * <p>The dashboard drives it a few days at a time, oldest first, so it fits any host's time limit
 * and shows progress. It stops where Runlight's own visits begin, so nothing is counted twice, and
 * it remembers how far it got, so running it again carries on from there.
 *
 * <p>An ImportedHit, the shape every visit import writes, is a map: {@code ts}, {@code key} (groups
 * rows into visitors, as Umami's session id does), {@code kind} ("pageview" or "event"), and the
 * strings {@code hostname}, {@code path}, {@code query}, {@code referrer}, {@code title}, {@code
 * name}, {@code country}, {@code region}, {@code city}, {@code browser}, {@code os}, {@code
 * device}, {@code screen}, {@code language}.
 */
public final class Visits {
  private Visits() {}

  private static final long DAY = 86_400_000L;

  /** Each step reads at most this many days, or stops after this many events. */
  private static final long STEP_DAYS = 14;

  private static final int STEP_EVENTS = 5_000;

  /** A single day with more than this is refused rather than read without end. */
  private static final int MAX_DAY_EVENTS = 200_000;

  /** Umami's event types that are visits: a pageview, and a custom event. */
  private static final double PAGEVIEW = 1;

  private static final double CUSTOM_EVENT = 2;

  private static final Pattern WEBSITE = Pattern.compile("^[A-Za-z0-9-]{1,64}\\z");
  private static final Pattern COUNTRY = Pattern.compile("^[A-Z]{2}\\z");

  private static String progressKey(String site, String website) {
    return "import:umami-visits:" + site + ":" + website;
  }

  /**
   * The websites an Umami account can see, to pick which one becomes this site's history: each
   * {@code {id, name, domain}}.
   */
  public static List<Map<String, Object>> umamiWebsites(
      Map<String, String> credentials, Fetcher fetcher) {
    Http http = new Http(fetcher);
    Umami.SignIn signIn = Umami.umamiSignIn(http, credentials, null);
    Map<String, String> headers = Map.of("authorization", "Bearer " + Js.string(signIn.token()));
    List<Map<String, Object>> out = new ArrayList<>();
    for (int page = 1; page < 100; page++) {
      Object body =
          http.getJson(signIn.base() + "/api/websites?page=" + page + "&pageSize=100", headers);
      List<Object> data = Js.list(Js.get(body, "data"));
      for (Object w : data) {
        out.add(
            Json.object(
                "id", Js.get(w, "id"), "name", Js.get(w, "name"), "domain", Js.get(w, "domain")));
      }
      if (out.size() >= Js.toNumber(Js.get(body, "count")) || data.isEmpty()) {
        break;
      }
    }
    return out;
  }

  /** Every page of an Umami list for a time window. */
  private static List<Object> all(
      Http http, String base, String path, Map<String, String> headers, int limit) {
    List<Object> out = new ArrayList<>();
    for (int page = 1; ; page++) {
      Object body =
          http.getJson(base + "/api" + path + "&page=" + page + "&pageSize=1000", headers);
      List<Object> data = Js.list(Js.get(body, "data"));
      // One at a time: spreading a busy day's events as arguments would pass the call stack's
      // limit.
      out.addAll(data);
      if (out.size() >= Js.toNumber(Js.get(body, "count")) || data.isEmpty()) {
        return out;
      }
      if (out.size() > limit) {
        throw new ImportError(
            "One day has more than "
                + String.format(Locale.US, "%,d", limit)
                + " events, more than an import step can read",
            "import_day_full",
            Json.object("limit", Integer.toString(limit)));
      }
    }
  }

  /**
   * One step: read the next few days from Umami and write them as imported visits.
   *
   * @return {@code cursor}, {@code done} and {@code total} (days, for the progress bar), {@code
   *     pageviews}, {@code events}, and {@code visits}
   */
  public static Map<String, Object> importUmamiVisits(
      Host runlight,
      String siteId,
      Map<String, String> credentials,
      String website,
      String cursor) {
    runlight.init();
    Map<String, Object> site = runlight.site(siteId);
    if (site == null) {
      throw new ImportError("Unknown site", "unknown_site");
    }
    if (!WEBSITE.matcher(website).find()) {
      throw new ImportError("Pick the Umami website to import", "import_website");
    }
    Http http = new Http(runlight.fetcher());

    Map<String, Object> saved =
        cursor != null && !cursor.isEmpty() ? Js.map(Json.parse(cursor)) : null;
    Umami.SignIn signIn =
        Umami.umamiSignIn(http, credentials, saved == null ? null : Js.get(saved, "token"));
    String base = signIn.base();
    Object token = signIn.token();
    Map<String, String> headers = Map.of("authorization", "Bearer " + Js.string(token));
    Map<String, Object> state;
    if (saved != null && website.equals(saved.get("website"))) {
      state = saved;
    } else {
      Object info = http.getJson(base + "/api/websites/" + website, headers);
      double created = Http.parseDate(Js.get(info, "createdAt"));
      if (!Js.truthy(created)) {
        created = runlight.now();
      }
      // Carry on where an earlier run stopped, and end where Runlight's own visits begin.
      String progress = runlight.store().setting(progressKey(siteId, website));
      double resumed = Js.toNumber(progress == null ? 0L : progress);
      // Never older than the site keeps, or the next scheduled check would delete it again.
      Long cutoffValue = runlight.retentionCutoff(siteId);
      double cutoff = cutoffValue == null ? 0 : cutoffValue;
      long start =
          (long)
              Math.max(
                  Math.max(Math.floor(created / DAY) * DAY, resumed),
                  Math.ceil(cutoff / DAY) * DAY);
      Object own = runlight.store().firstOwnVisit(siteId);
      state =
          Json.object(
              "website", website,
              "day", start,
              "start", start,
              "end", own != null ? Js.asLong(own) : runlight.now());
    }
    boolean usesKey = !Http.credential(credentials, "apiKey").isEmpty();

    // Read whole days until the step has enough.
    List<Object> events = new ArrayList<>();
    long from = Js.asLong(state.get("day"));
    long to = from;
    long end = Js.asLong(state.get("end"));
    long first = Js.asLong(state.get("start"));
    while (to < end && to - from < STEP_DAYS * DAY && events.size() < STEP_EVENTS) {
      long next = Math.min(to + DAY, end);
      events.addAll(
          all(
              http,
              base,
              "/websites/" + website + "/events?startAt=" + to + "&endAt=" + (next - 1),
              headers,
              MAX_DAY_EVENTS));
      to = next;
    }
    List<Object> sessions =
        !events.isEmpty()
            ? all(
                http,
                base,
                "/websites/" + website + "/sessions?startAt=" + from + "&endAt=" + (to - 1),
                headers,
                MAX_DAY_EVENTS * (int) STEP_DAYS)
            : List.of();
    Map<String, Object> info = new HashMap<>();
    for (Object s : sessions) {
      info.put(Js.string(Js.get(s, "id")), s);
    }

    String ns = "umami-visits:" + website;
    List<Map<String, Object>> visits = new ArrayList<>();
    for (Object e : events) {
      Object type = Js.get(e, "eventType");
      boolean pageview = type instanceof Number n && n.doubleValue() == PAGEVIEW;
      boolean custom =
          type instanceof Number n
              && n.doubleValue() == CUSTOM_EVENT
              && Js.truthy(Js.get(e, "eventName"));
      if (!pageview && !custom) {
        continue;
      }
      double ts = Http.parseDate(Js.get(e, "createdAt"));
      if (Double.isNaN(ts) || Double.isInfinite(ts) || ts >= end) {
        continue;
      }
      visits.add(Json.object("ts", (long) ts, "event", e));
    }
    visits.sort((a, b) -> Long.compare((Long) a.get("ts"), (Long) b.get("ts")));
    List<Map<String, Object>> hits = new ArrayList<>();
    for (Map<String, Object> v : visits) {
      Object e = v.get("event");
      hits.add(
          Json.object(
              "ns",
              ns,
              "hit",
              fromUmami(e, (Long) v.get("ts"), info.get(Js.string(Js.get(e, "sessionId"))))));
    }
    long stepEnd = to;
    Map<String, Object> counts =
        writeStep(
            runlight,
            siteId,
            from,
            to,
            hits,
            store -> store.setSetting(progressKey(siteId, website), Long.toString(stepEnd)));

    long totalDays = Math.max(1, (long) Math.ceil((double) (end - first) / DAY));
    long doneDays = Math.min(totalDays, (long) Math.ceil((double) (to - first) / DAY));
    boolean more = to < end;
    Map<String, Object> next = new LinkedHashMap<>(state);
    next.put("day", to);
    if (!usesKey) {
      next.put("token", token);
    }
    Map<String, Object> out =
        Json.object(
            "cursor", more ? Json.stringify(next) : null, "done", doneDays, "total", totalDays);
    out.putAll(counts);
    return out;
  }

  /** What a step does once its rows are written, in the same transaction. */
  @FunctionalInterface
  private interface Done {
    void run(SqlStore store);
  }

  /**
   * Writes one step of imported visits, sorted oldest first, all within [from, to). Whatever an
   * earlier import left in those times is cleared first, so a step can always run again, and a
   * visit carried in from the step before is counted again from its rows. {@code done} runs in the
   * same transaction, to remember how far it got.
   */
  private static Map<String, Object> writeStep(
      Host runlight, String siteId, long from, long to, List<Map<String, Object>> hits, Done done) {
    Map<String, Object> site = runlight.site(siteId);
    if (site == null) {
      throw new ImportError("Unknown site", "unknown_site");
    }
    long[] counts = {0, 0, 0};
    runlight
        .store()
        .transaction(
            store -> {
              // Days this step writes into are added up again later, with the imported visits in
              // them.
              store.clearRollups(siteId, Map.of("from", from, "to", to));
              // A failed earlier try at these days (on D1, which has no transactions) can
              // have left part of them behind. Clear it, so every step can safely run again.
              String imported = "SELECT id FROM rl_sessions WHERE site = ? AND imported = 1";
              store
                  .db()
                  .run(
                      "DELETE FROM rl_events WHERE site = ? AND ts >= ? AND ts < ? AND kind IN ('pageview', 'event') AND session IN ("
                          + imported
                          + ")",
                      List.of(siteId, from, to, siteId));
              // Visits of these days that kept no rows go too. Their rows would come within
              // EVENT_TAIL_MS of the step, so the time bounds let the (site, ts) index find them,
              // with no scan of every event.
              store
                  .db()
                  .run(
                      "DELETE FROM rl_sessions WHERE site = ? AND imported = 1 AND started_at >= ? AND started_at < ?\n"
                          + "         AND id NOT IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                      List.of(siteId, from, to, siteId, from, to + SqlStore.EVENT_TAIL_MS));
              for (Map<String, Object> entry : hits) {
                Map<String, Object> hit = Js.map(entry.get("hit"));
                if (writeEvent(store, site, (String) entry.get("ns"), hit)) {
                  counts[2]++;
                }
                if ("pageview".equals(hit.get("kind"))) {
                  counts[0]++;
                } else {
                  counts[1]++;
                }
              }
              // A visit that began in an earlier step and went on into this one is counted
              // again from its rows, so a repeated step cannot leave it with doubled totals.
              // The day it began may already be built, so that day is built again too.
              List<Map<String, Object>> carried =
                  store
                      .db()
                      .all(
                          "SELECT s.id AS id, s.started_at AS started_at FROM rl_sessions s\n"
                              + "       WHERE s.site = ? AND s.imported = 1 AND s.started_at < ? AND s.started_at >= ?\n"
                              + "         AND s.id IN (SELECT e.session FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ?)",
                          List.of(siteId, from, from - SqlStore.EVENT_TAIL_MS, siteId, from, to));
              if (!carried.isEmpty()) {
                long earliest = Long.MAX_VALUE;
                for (Map<String, Object> c : carried) {
                  earliest = Math.min(earliest, Js.asLong(c.get("started_at")));
                }
                store.clearRollups(siteId, Map.of("from", earliest, "to", from));
                // Their rows lie between the earliest start and this step's end, which the
                // (site, ts) index reads in one pass. Ninety ids a statement, within Cloudflare
                // D1's 100 values.
                List<Map<String, Object>> rows = new ArrayList<>();
                for (int i = 0; i < carried.size(); i += 90) {
                  List<Object> params = new ArrayList<>(List.of(siteId, earliest, to));
                  List<Map<String, Object>> chunk =
                      carried.subList(i, Math.min(i + 90, carried.size()));
                  for (Map<String, Object> c : chunk) {
                    params.add(Js.string(c.get("id")));
                  }
                  rows.addAll(
                      store
                          .db()
                          .all(
                              "SELECT e.session AS session, e.kind AS kind, e.ts AS ts, e.path AS path FROM rl_events e\n"
                                  + "             WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind IN ('pageview', 'event') AND e.session IN ("
                                  + String.join(", ", Collections.nCopies(chunk.size(), "?"))
                                  + ")\n"
                                  + "             ORDER BY e.ts, e.id",
                              params));
                }
                Map<String, long[]> totals = new LinkedHashMap<>();
                Map<String, String> exits = new HashMap<>();
                for (Map<String, Object> r : rows) {
                  String session = Js.string(r.get("session"));
                  long[] t = totals.computeIfAbsent(session, k -> new long[] {0, 0, 0});
                  if ("pageview".equals(r.get("kind"))) {
                    t[0]++;
                    exits.put(session, Js.string(r.get("path")));
                  } else {
                    t[1]++;
                  }
                  t[2] = Math.max(t[2], Js.asLong(r.get("ts")));
                }
                for (Map.Entry<String, long[]> e : totals.entrySet()) {
                  long[] t = e.getValue();
                  List<Object> params = new ArrayList<>();
                  params.add(t[0]);
                  params.add(t[1]);
                  params.add(t[2]);
                  params.add(exits.get(e.getKey()));
                  params.add(e.getKey());
                  store
                      .db()
                      .run(
                          "UPDATE rl_sessions SET pageviews = ?, events = ?, last_at = ?, exit_path = COALESCE(?, exit_path) WHERE id = ?",
                          params);
                }
              }
              if (done != null) {
                done.run(store);
              }
              return null;
            });
    return Json.object("pageviews", counts[0], "events", counts[1], "visits", counts[2]);
  }

  /** {@code value ?? ""}, as text. */
  private static String text(Object value) {
    return value == null || value == Json.UNDEFINED ? "" : Js.string(value);
  }

  private static String referrerOf(Object domain, Object path, Object query) {
    if (!Js.truthy(domain)) {
      return "";
    }
    return "https://"
        + Js.string(domain)
        + (Js.truthy(path) ? Js.string(path) : "/")
        + (Js.truthy(query) ? "?" + Js.string(query).replaceFirst("^\\?", "") : "");
  }

  private static Map<String, Object> fromUmami(Object e, long ts, Object session) {
    Object subdivision = Js.get(session, "subdivision1");
    Object region = Js.get(session, "region");
    return Json.object(
        "ts", ts,
        "key", Js.string(Js.get(e, "sessionId")),
        "kind", Js.toNumber(Js.get(e, "eventType")) == PAGEVIEW ? "pageview" : "event",
        "hostname", text(Js.get(e, "hostname")),
        "path", text(Js.get(e, "urlPath")),
        "query", text(Js.get(e, "urlQuery")),
        "referrer",
            referrerOf(
                Js.get(e, "referrerDomain"), Js.get(e, "referrerPath"), Js.get(e, "referrerQuery")),
        "title", text(Js.get(e, "pageTitle")),
        "name", text(Js.get(e, "eventName")),
        "country", text(Js.get(e, "country")),
        "region",
            Js.truthy(subdivision)
                ? Js.string(subdivision)
                : Js.truthy(region) ? Js.string(region) : "",
        "city", text(Js.get(e, "city")),
        "browser", text(Js.get(e, "browser")),
        "os", text(Js.get(e, "os")),
        "device", text(Js.get(e, "device")),
        "screen", text(Js.get(session, "screen")),
        "language", text(Js.get(session, "language")));
  }

  /**
   * Writes one imported pageview or event as part of a Runlight visit. Visitors are hashed per day
   * from the hit's key, as live visitors are hashed per day, and a hit within thirty minutes of the
   * visitor's last one joins that visit. Ids come from {@code ns} and the key, so importing the
   * same rows again makes the same ids. Returns whether it started a new visit.
   */
  private static boolean writeEvent(
      SqlStore store, Map<String, Object> site, String ns, Map<String, Object> e) {
    long ts = Js.asLong(e.get("ts"));
    String key = (String) e.get("key");
    String siteId = (String) site.get("id");
    List<Object> hostnames = Js.list(site.get("hostnames"));
    // The site's own day, as live visitors are counted, so days add up the same way in rollups.
    String day = Time.localDate(ts, (String) site.get("timezone"));
    String visitor = Write.hexId(ns + ":" + key + ":" + day, 16);
    // A visit that runs past midnight keeps the id it started with, as a live one does.
    String yesterday = Write.hexId(ns + ":" + key + ":" + Time.addDays(day, -1), 16);
    String hostname = (String) e.get("hostname");
    Object firstHost = hostnames == null || hostnames.isEmpty() ? null : hostnames.get(0);
    String host =
        Js.lower(
            !hostname.isEmpty()
                ? hostname
                : Js.truthy(firstHost) ? Js.string(firstHost) : "imported.invalid");
    String path = (String) e.get("path");
    String query = (String) e.get("query");
    Url url =
        Url.parse(
            "https://"
                + host
                + (!path.isEmpty() ? path : "/")
                + (!query.isEmpty() ? "?" + query.replaceFirst("^\\?", "") : ""));
    Map<String, Object> page =
        Sources.parsePage(url != null ? url : new Url("https://" + host + "/"));
    Map<String, Object> open =
        store.openSession(siteId, List.of(visitor, yesterday), ts - Runlight.SESSION_IDLE_MS);
    String id = open == null ? null : (String) open.get("id");
    if (id == null) {
      id = Write.hexId(ns + ":" + key + ":" + ts);
      store.db().run("DELETE FROM rl_sessions WHERE id = ?", List.of(id));
      String country = Js.slice(Js.upper((String) e.get("country")), 0, 2);
      String rawRegion = (String) e.get("region");
      String region =
          !rawRegion.isEmpty()
              ? Js.slice(
                  Js.upper(rawRegion.contains("-") ? rawRegion : country + "-" + rawRegion), 0, 10)
              : "";
      boolean known = COUNTRY.matcher(country).find();
      Map<String, Object> utm = Js.map(page.get("utm"));
      List<String> internal = new ArrayList<>();
      if (hostnames != null) {
        for (Object h : hostnames) {
          internal.add(Js.string(h));
        }
      }
      Map<String, Object> row =
          Json.object(
              "id", id,
              "site", siteId,
              "visitor", visitor,
              "startedAt", ts,
              "hostname", page.get("hostname"));
      row.putAll(Sources.attribute(page, (String) e.get("referrer"), internal));
      row.put("utmSource", utm.get("source"));
      row.put("utmMedium", utm.get("medium"));
      row.put("utmCampaign", utm.get("campaign"));
      row.put("utmTerm", utm.get("term"));
      row.put("utmContent", utm.get("content"));
      row.put("country", known ? country : "");
      row.put("region", known ? region : "");
      row.put("city", Js.slice((String) e.get("city"), 0, 100));
      row.put("browser", Write.browser((String) e.get("browser")));
      row.put("browserVersion", "");
      row.put("os", Write.system((String) e.get("os")));
      row.put("osVersion", "");
      row.put("device", Write.device((String) e.get("device")));
      row.put("screen", Js.slice((String) e.get("screen"), 0, 20));
      row.put("language", Js.slice((String) e.get("language"), 0, 35));
      store.insertSession(row);
      // No engaged time is known, so duration falls back to first-to-last pageview.
      store
          .db()
          .run("UPDATE rl_sessions SET imported = 1, engaged_ms = NULL WHERE id = ?", List.of(id));
    }
    String kind = (String) e.get("kind");
    store.touchSession(id, ts, kind, (String) page.get("path"));
    store.insertEvent(
        Json.object(
            "site",
            siteId,
            "ts",
            ts,
            "kind",
            kind,
            // The visit's own visitor, which for one running past midnight is the id of the day it
            // started.
            "visitor",
            open != null ? open.get("visitor") : visitor,
            "session",
            id,
            "pageview",
            "",
            "path",
            page.get("path"),
            "hostname",
            page.get("hostname"),
            "title",
            kind.equals("pageview") ? Js.slice((String) e.get("title"), 0, 300) : "",
            "name",
            kind.equals("event") ? Js.slice((String) e.get("name"), 0, 120) : "",
            "props",
            null,
            "engagedMs",
            0L,
            "scroll",
            null,
            "link",
            ""));
    return open == null;
  }

  /**
   * One batch of a CSV file, sorted oldest first by the dashboard. As with Umami, only rows from
   * before Runlight's own first visit, and within what the site keeps, are written. A batch can run
   * again: its time span is cleared first, so batches must not share a moment, which the dashboard
   * sees to.
   *
   * @param rows the rows as the request sent them: a list of objects
   * @return {@code pageviews}, {@code events}, {@code visits}, and {@code skipped}
   */
  public static Map<String, Object> importCsvVisits(Host runlight, String siteId, Object rows) {
    runlight.init();
    if (runlight.site(siteId) == null) {
      throw new ImportError("Unknown site", "unknown_site");
    }
    if (!(rows instanceof List<?> list) || list.size() > CsvVisits.CSV_BATCH) {
      throw new ImportError(
          "Send at most " + CsvVisits.CSV_BATCH + " rows at a time",
          "import_csv_batch",
          Json.object("max", Integer.toString(CsvVisits.CSV_BATCH)));
    }
    List<Map<String, String>> clean = new ArrayList<>();
    for (Object r : list) {
      Map<String, Object> fields = new LinkedHashMap<>();
      if (r instanceof Map<?, ?> m) {
        for (Map.Entry<String, Object> e : Js.entries(m)) {
          fields.put(e.getKey(), e.getValue());
        }
      } else if (r instanceof List<?> l) {
        for (int i = 0; i < l.size(); i++) {
          fields.put(Integer.toString(i), l.get(i));
        }
      }
      Map<String, String> row = new LinkedHashMap<>();
      for (Map.Entry<String, Object> e : fields.entrySet()) {
        row.put(Js.lower(Js.trim(e.getKey())), text(e.getValue()));
      }
      clean.add(row);
    }
    String format = CsvVisits.csvFormat(clean.isEmpty() ? List.of() : Js.keys(clean.get(0)));
    if (format == null) {
      throw new ImportError(
          "This CSV is not an Umami export or Runlight's visit format", "import_csv_format");
    }
    Long cutoffValue = runlight.retentionCutoff(siteId);
    double cutoff = cutoffValue == null ? 0 : cutoffValue;
    Object own = runlight.store().firstOwnVisit(siteId);
    double end =
        Math.min(own == null ? Double.POSITIVE_INFINITY : Js.asDouble(own), runlight.now());
    List<Map<String, Object>> hits = new ArrayList<>();
    for (Map<String, String> row : clean) {
      Map<String, Object> h = CsvVisits.csvHit(row, format);
      if (h != null) {
        double ts = Js.asDouble(Js.map(h.get("hit")).get("ts"));
        if (ts >= cutoff && ts < end) {
          hits.add(h);
        }
      }
    }
    hits.sort((a, b) -> Long.compare(hitTs(a), hitTs(b)));
    long skipped = (long) clean.size() - hits.size();
    if (hits.isEmpty()) {
      return Json.object("pageviews", 0L, "events", 0L, "visits", 0L, "skipped", skipped);
    }
    Map<String, Object> counts =
        writeStep(
            runlight, siteId, hitTs(hits.get(0)), hitTs(hits.get(hits.size() - 1)) + 1, hits, null);
    counts.put("skipped", skipped);
    return counts;
  }

  private static long hitTs(Map<String, Object> h) {
    return Js.asLong(Js.map(h.get("hit")).get("ts"));
  }
}
