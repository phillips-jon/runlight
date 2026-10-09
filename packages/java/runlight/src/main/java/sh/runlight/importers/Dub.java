package sh.runlight.importers;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Dub. Links come from GET /links (cursor pages of up to 100, archived included). Click history is
 * per click from /events where the plan allows, else daily counts from /analytics, else none; the
 * first link decides. What the account's plan lets us read rides in the cursor as {@code history}:
 * "events" (Business), "daily" (Pro), "none" (Free), or null before the first link.
 *
 * <p>https://dub.co/docs/api-reference
 */
public final class Dub implements Importer {
  private static final String BASE = "https://api.dub.co";
  private static final int PAGE = 10;

  private final Http http;
  private final LongSupplier now;

  /**
   * @param now milliseconds
   */
  public Dub(Http http, LongSupplier now) {
    this.http = http;
    this.now = now;
  }

  @Override
  public Map<String, Object> step(Map<String, String> credentials, String cursor, Known known) {
    String key = Http.credential(credentials, "apiKey");
    if (key.isEmpty()) {
      throw new ImportError("Enter a Dub API key", "import_key", Json.object("service", "Dub"));
    }
    Map<String, String> headers = Map.of("authorization", "Bearer " + key);
    Object state =
        cursor != null && !cursor.isEmpty()
            ? Json.parse(cursor)
            : Json.object("after", null, "history", null);
    Object history = Js.get(state, "history");
    Object afterValue = Js.get(state, "after");
    String after =
        Js.truthy(afterValue)
            ? "&startingAfter=" + Js.encodeURIComponent(Js.string(afterValue))
            : "";
    List<Object> list =
        Js.list(
            http.getJson(BASE + "/links?pageSize=" + PAGE + "&showArchived=true" + after, headers));

    List<Object> links = new ArrayList<>();
    for (Object l : list) {
      Object id = Js.get(l, "id");
      if (known.known(id, Js.get(l, "key"), Js.get(l, "url"))) {
        links.add(
            Json.object(
                "link",
                Json.object(
                    "sourceId",
                    id,
                    "slug",
                    Js.get(l, "key"),
                    "domain",
                    "",
                    "name",
                    "",
                    "url",
                    Js.get(l, "url"),
                    "createdAt",
                    0L),
                "known",
                true));
        continue;
      }
      List<Object> clicks = null;
      List<Object> daily = null;
      if (history == null || "events".equals(history)) {
        try {
          clicks = new ArrayList<>();
          for (int page = 1; ; page++) {
            List<Object> events =
                Js.list(
                    http.getJson(
                        BASE
                            + "/events?event=clicks&linkId="
                            + Js.encodeURIComponent(Js.string(id))
                            + "&interval=all&sortOrder=asc&limit=1000&page="
                            + page,
                        headers));
            for (Object e : events) {
              Object click = Js.get(e, "click");
              Object referer = Js.get(click, "referer");
              Object refererUrl = Js.get(click, "refererUrl");
              Object device = Js.get(click, "device");
              clicks.add(
                  Http.defined(
                      Json.object(
                          "ts", Js.num(Http.parseDate(Js.get(e, "timestamp"))),
                          "visit", Js.get(click, "id"),
                          "referrer",
                              Js.truthy(refererUrl)
                                  ? refererUrl
                                  : Js.truthy(referer) && !"(direct)".equals(referer)
                                      ? "https://" + Js.string(referer) + "/"
                                      : "",
                          "country", Js.get(click, "country"),
                          "region", Js.get(click, "region"),
                          "city", Js.get(click, "city"),
                          "device", device instanceof String d ? Js.lower(d) : Json.UNDEFINED,
                          "browser", Js.get(click, "browser"),
                          "os", Js.get(click, "os"))));
            }
            if (events.size() < 1000) {
              break;
            }
          }
          history = "events";
        } catch (HttpError error) {
          if (error.status() == 401) {
            throw error;
          }
          clicks = null;
          history = "daily";
        }
      }
      if ("daily".equals(history)) {
        try {
          List<Object> series =
              Js.list(
                  http.getJson(
                      BASE
                          + "/analytics?event=clicks&groupBy=timeseries&interval=all&linkId="
                          + Js.encodeURIComponent(Js.string(id)),
                      headers));
          daily = new ArrayList<>();
          for (Object p : series) {
            if (Js.toNumber(Js.get(p, "clicks")) > 0) {
              daily.add(
                  Json.object(
                      "day",
                      Js.slice(Js.string(Js.get(p, "start")), 0, 10),
                      "clicks",
                      Js.get(p, "clicks")));
            }
          }
        } catch (HttpError error) {
          if (error.status() == 401) {
            throw error;
          }
          history = "none";
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
                      Js.get(l, "key"),
                      "domain",
                      Js.get(l, "domain"),
                      "name",
                      Js.truthy(title) ? title : "",
                      "url",
                      Js.get(l, "url"),
                      "createdAt",
                      Js.truthy(created) ? Js.num(created) : (Object) now.getAsLong()),
                  "clicks",
                  clicks == null ? Json.UNDEFINED : clicks,
                  "daily",
                  daily == null ? Json.UNDEFINED : daily)));
    }
    Object last = list.isEmpty() ? null : list.get(list.size() - 1);
    return Json.object(
        "cursor",
        list.size() == PAGE && Js.truthy(last)
            ? Json.stringify(Json.object("after", Js.get(last, "id"), "history", history))
            : null,
        "total",
        null,
        "links",
        links);
  }
}
