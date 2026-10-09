package sh.runlight.importers;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Rebrandly. Its API gives only total clicks, with no dates, so links come across with their slugs
 * and domains and start their history fresh.
 *
 * <p>https://developers.rebrandly.com/docs
 */
public final class Rebrandly implements Importer {
  private static final String BASE = "https://api.rebrandly.com/v1";
  private static final int PAGE = 25;

  private final Http http;
  private final LongSupplier now;

  /**
   * @param now milliseconds
   */
  public Rebrandly(Http http, LongSupplier now) {
    this.http = http;
    this.now = now;
  }

  @Override
  public Map<String, Object> step(Map<String, String> credentials, String cursor, Known known) {
    String key = Http.credential(credentials, "apiKey");
    if (key.isEmpty()) {
      throw new ImportError(
          "Enter a Rebrandly API key", "import_key", Json.object("service", "Rebrandly"));
    }
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("apikey", key);
    String workspace = Http.credential(credentials, "workspace");
    if (!workspace.isEmpty()) {
      headers.put("workspace", workspace);
    }
    String last =
        cursor != null && !cursor.isEmpty() ? "&last=" + Js.encodeURIComponent(cursor) : "";
    List<Object> list =
        Js.list(
            http.getJson(
                BASE + "/links?orderBy=createdAt&orderDir=desc&limit=" + PAGE + last, headers));
    List<Object> links = new ArrayList<>();
    for (Object l : list) {
      double created = Http.parseDate(Js.get(l, "createdAt"));
      Object title = Js.get(l, "title");
      links.add(
          Json.object(
              "link",
              Json.object(
                  "sourceId", Js.get(l, "id"),
                  "slug", Js.get(l, "slashtag"),
                  "domain", Http.coalesce(Js.get(Js.get(l, "domain"), "fullName"), ""),
                  "name", Js.truthy(title) ? title : "",
                  "url", Js.get(l, "destination"),
                  "createdAt", Js.truthy(created) ? Js.num(created) : (Object) now.getAsLong())));
    }
    Object end = list.isEmpty() ? null : list.get(list.size() - 1);
    return Json.object(
        "cursor",
        list.size() == PAGE && Js.truthy(end) ? Js.string(Js.get(end, "id")) : null,
        "total",
        null,
        "links",
        links);
  }
}
