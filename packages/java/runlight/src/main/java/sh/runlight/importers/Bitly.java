package sh.runlight.importers;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Bitly. Links are listed per group (every group in the account), with archived ones. Bitly only
 * keeps daily click counts, and only as far back as the account's plan allows. A custom back-half
 * or branded domain wins over the random bit.ly one.
 *
 * <p>https://dev.bitly.com/api-reference
 */
public final class Bitly implements Importer {
  private static final String BASE = "https://api-ssl.bitly.com/v4";
  private static final int PAGE = 20;

  private final Http http;
  private final LongSupplier now;

  /**
   * @param now milliseconds
   */
  public Bitly(Http http, LongSupplier now) {
    this.http = http;
    this.now = now;
  }

  /** A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale". */
  private static String[] split(String value) {
    String bare = value.replaceFirst("^https?://", "");
    int at = bare.indexOf('/');
    if (at < 0) {
      return new String[] {bare, ""};
    }
    String slug = bare.substring(at + 1);
    return new String[] {
      bare.substring(0, at), slug.endsWith("/") ? slug.substring(0, slug.length() - 1) : slug
    };
  }

  @Override
  public Map<String, Object> step(Map<String, String> credentials, String cursor, Known known) {
    String token = Http.credential(credentials, "token");
    if (token.isEmpty()) {
      token = Http.credential(credentials, "apiKey");
    }
    if (token.isEmpty()) {
      throw new ImportError(
          "Enter a Bitly access token", "import_key", Json.object("service", "Bitly"));
    }
    Map<String, String> headers = Map.of("authorization", "Bearer " + token);
    Map<String, Object> state;
    if (cursor != null && !cursor.isEmpty()) {
      state = Js.map(Json.parse(cursor));
    } else {
      List<Object> guids = new ArrayList<>();
      for (Object g : Js.list(Js.get(http.getJson(BASE + "/groups", headers), "groups"))) {
        guids.add(Js.get(g, "guid"));
      }
      state = Json.object("groups", guids, "g", 0L, "after", null);
    }
    Object group = Js.get(state.get("groups"), Js.string(state.get("g")));
    if (!Js.truthy(group)) {
      return Json.object("cursor", null, "total", null, "links", new ArrayList<>());
    }

    Object afterValue = Js.get(state, "after");
    String after =
        Js.truthy(afterValue)
            ? "&search_after=" + Js.encodeURIComponent(Js.string(afterValue))
            : "";
    Object page =
        http.getJson(
            BASE
                + "/groups/"
                + Js.string(group)
                + "/bitlinks?size="
                + PAGE
                + "&archived=both"
                + after,
            headers);

    List<Object> pageLinks = Js.list(Js.get(page, "links"));
    List<Object> links = new ArrayList<>();
    for (Object b : pageLinks) {
      if (Js.truthy(Js.get(b, "is_deleted"))) {
        continue;
      }
      Object id = Js.get(b, "id");
      String[] shortUrl =
          split(Js.string(Http.coalesce(Js.get(Js.get(b, "custom_bitlinks"), "0"), id)));
      Object longUrl = Js.get(b, "long_url");
      if (known.known(id, shortUrl[1], longUrl)) {
        links.add(
            Json.object(
                "link",
                Json.object(
                    "sourceId",
                    id,
                    "slug",
                    "",
                    "domain",
                    "",
                    "name",
                    "",
                    "url",
                    longUrl,
                    "createdAt",
                    0L),
                "known",
                true));
        continue;
      }
      List<Object> daily = null;
      try {
        Object clicks =
            http.getJson(
                BASE
                    + "/bitlinks/"
                    + Js.encodeURIComponent(Js.string(id))
                    + "/clicks?unit=day&units=-1",
                headers);
        daily = new ArrayList<>();
        for (Object c : Js.list(Js.get(clicks, "link_clicks"))) {
          if (Js.toNumber(Js.get(c, "clicks")) > 0) {
            daily.add(
                Json.object(
                    "day",
                    Js.slice(Js.string(Js.get(c, "date")), 0, 10),
                    "clicks",
                    Js.get(c, "clicks")));
          }
        }
      } catch (HttpError error) {
        // Plans without analytics refuse this; the link still comes across.
        if (error.status() == 401) {
          throw error;
        }
      }
      double created = Http.parseDate(Js.get(b, "created_at"));
      Object title = Js.get(b, "title");
      links.add(
          Http.defined(
              Json.object(
                  "link",
                  Json.object(
                      "sourceId",
                      id,
                      "slug",
                      shortUrl[1],
                      "domain",
                      shortUrl[0],
                      "name",
                      Js.truthy(title) ? title : "",
                      "url",
                      longUrl,
                      "createdAt",
                      Js.truthy(created) ? Js.num(created) : (Object) now.getAsLong()),
                  "daily",
                  daily == null ? Json.UNDEFINED : daily)));
    }

    Object searchAfter = Js.get(Js.get(page, "pagination"), "search_after");
    Object next = Js.truthy(searchAfter) && pageLinks.size() == PAGE ? searchAfter : null;
    Map<String, Object> more = null;
    if (next != null) {
      more = new LinkedHashMap<>(state);
      more.put("after", next);
    } else if (Js.toNumber(state.get("g")) + 1 < Js.list(state.get("groups")).size()) {
      more = new LinkedHashMap<>(state);
      more.put("g", Js.num(Js.toNumber(state.get("g")) + 1));
      more.put("after", null);
    }
    return Json.object(
        "cursor", more != null ? Json.stringify(more) : null, "total", null, "links", links);
  }
}
