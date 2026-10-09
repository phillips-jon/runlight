package sh.runlight.importers;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Short.io. Links are listed per domain. Daily click counts come from the statistics API, paced to
 * its limit of 60 requests a minute, so a step holds only a few links.
 *
 * <p>https://developers.short.io/reference
 */
public final class Shortio implements Importer {
  private static final String API = "https://api.short.io";
  private static final String STATS = "https://statistics.short.io/statistics";
  private static final int PAGE = 8;

  /** The statistics API allows 60 requests a minute. */
  private static final long STATS_GAP_MS = 1050;

  private final Http http;
  private final LongSupplier now;

  /**
   * @param now milliseconds
   */
  public Shortio(Http http, LongSupplier now) {
    this.http = http;
    this.now = now;
  }

  @Override
  public Map<String, Object> step(Map<String, String> credentials, String cursor, Known known) {
    String key = Http.credential(credentials, "apiKey");
    if (key.isEmpty()) {
      throw new ImportError(
          "Enter a Short.io secret API key", "import_key", Json.object("service", "Short.io"));
    }
    Map<String, String> headers = Map.of("authorization", key);
    Map<String, Object> state;
    if (cursor != null && !cursor.isEmpty()) {
      state = Js.map(Json.parse(cursor));
    } else {
      List<Object> domains = new ArrayList<>();
      for (Object d : Js.list(http.getJson(API + "/api/domains?limit=300", headers))) {
        domains.add(Json.object("id", Js.get(d, "id"), "hostname", Js.get(d, "hostname")));
      }
      state = Json.object("domains", domains, "d", 0L, "token", null, "total", null);
    }
    Object domain = Js.get(state.get("domains"), Js.string(state.get("d")));
    if (!Js.truthy(domain)) {
      return Json.object("cursor", null, "total", null, "links", new ArrayList<>());
    }

    Object pageToken = Js.get(state, "token");
    String token =
        Js.truthy(pageToken) ? "&pageToken=" + Js.encodeURIComponent(Js.string(pageToken)) : "";
    Object page =
        http.getJson(
            API
                + "/api/links?domain_id="
                + Js.string(Js.get(domain, "id"))
                + "&limit="
                + PAGE
                + token,
            headers);

    List<Object> links = new ArrayList<>();
    for (Object l : Js.list(Js.get(page, "links"))) {
      String id = Js.string(Http.coalesce(Js.get(l, "idString"), Js.get(l, "id")));
      Object path = Js.get(l, "path");
      Object original = Js.get(l, "originalURL");
      if (known.known(id, path, original)) {
        links.add(
            Json.object(
                "link",
                Json.object(
                    "sourceId",
                    id,
                    "slug",
                    path,
                    "domain",
                    "",
                    "name",
                    "",
                    "url",
                    original,
                    "createdAt",
                    0L),
                "known",
                true));
        continue;
      }
      List<Object> daily = null;
      try {
        http.pause(STATS_GAP_MS);
        Map<String, String> statsHeaders = new LinkedHashMap<>(headers);
        statsHeaders.put("content-type", "application/json");
        Object body =
            http.getJson(
                STATS + "/link/" + Js.encodeURIComponent(id) + "/by_interval",
                statsHeaders,
                "POST",
                Json.stringify(
                    Json.object("period", "total", "clicksChartInterval", "day", "tz", "UTC")));
        Object raw = Js.get(body, "clickStatistics");
        List<Object> points;
        if (raw instanceof List<?>) {
          points = Js.list(raw);
        } else {
          Object data = Js.get(Js.get(Js.get(raw, "datasets"), "0"), "data");
          points = data == null || data == Json.UNDEFINED ? List.of() : Js.list(data);
        }
        daily = new ArrayList<>();
        for (Object p : points) {
          Object y = Js.get(p, "y");
          if (Js.toNumber(y) > 0) {
            Object x = Js.get(p, "x");
            double ms = x instanceof Number n ? n.doubleValue() : Http.parseDate(x);
            daily.add(Json.object("day", Js.slice(Http.isoString(ms), 0, 10), "clicks", y));
          }
        }
      } catch (HttpError error) {
        if (error.status() == 401) {
          throw error;
        }
      }
      double created = Http.parseDate(Js.get(l, "createdAt"));
      Object title = Js.get(l, "title");
      links.add(
          Http.defined(
              Json.object(
                  "link",
                  Json.object(
                      "sourceId",
                      id,
                      "slug",
                      path,
                      "domain",
                      Js.get(domain, "hostname"),
                      "name",
                      Js.truthy(title) ? title : "",
                      "url",
                      original,
                      "createdAt",
                      Js.truthy(created) ? Js.num(created) : (Object) now.getAsLong()),
                  "daily",
                  daily == null ? Json.UNDEFINED : daily)));
    }

    Object next = Js.get(page, "nextPageToken");
    Map<String, Object> more = null;
    if (Js.truthy(next)) {
      more = new LinkedHashMap<>(state);
      more.put("token", next);
    } else if (Js.toNumber(state.get("d")) + 1 < Js.list(state.get("domains")).size()) {
      more = new LinkedHashMap<>(state);
      more.put("d", Js.num(Js.toNumber(state.get("d")) + 1));
      more.put("token", null);
    }
    return Json.object(
        "cursor", more != null ? Json.stringify(more) : null, "total", null, "links", links);
  }
}
