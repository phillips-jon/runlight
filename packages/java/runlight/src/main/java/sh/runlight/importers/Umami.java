package sh.runlight.importers;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * Umami v3 (and forks with custom link domains). Signs in with an API key, or with a username and
 * password (stock self-hosted Umami has no API keys). In Umami a link's clicks are events stored
 * under the link's id, with the visitor's session holding place and device.
 */
public final class Umami implements Importer {
  private static final int PAGE = 5;

  private static final Pattern ADDRESS = Pattern.compile("^https?://[^/]+");

  private final Http http;
  private final LongSupplier now;

  /**
   * @param now milliseconds
   */
  public Umami(Http http, LongSupplier now) {
    this.http = http;
    this.now = now;
  }

  /** The Umami's address and the token to send it. */
  public record SignIn(String base, Object token) {}

  /**
   * Signs in to an Umami: an API key, or a username and password (stock self-hosted Umami has no
   * API keys). A token from an earlier step is reused.
   *
   * @param token a token from an earlier step, or null
   */
  public static SignIn umamiSignIn(Http http, Map<String, String> credentials, Object token) {
    String base = Http.credential(credentials, "url").replaceFirst("/+\\z", "");
    if (!ADDRESS.matcher(base).find()) {
      throw new ImportError(
          "Enter your Umami address, like https://stats.example.com", "import_umami_address");
    }
    String key = Http.credential(credentials, "apiKey");
    if (!key.isEmpty() || Js.truthy(token)) {
      return new SignIn(base, !key.isEmpty() ? key : token);
    }
    String username = credentials.get("username");
    String password = credentials.get("password");
    if (username == null || username.isEmpty() || password == null || password.isEmpty()) {
      throw new ImportError("Enter an API key, or a username and password", "import_umami_login");
    }
    Object login =
        http.getJson(
            base + "/api/auth/login",
            Map.of("content-type", "application/json"),
            "POST",
            Json.stringify(Json.object("username", username, "password", password)));
    // A sign-in that answers without a token was refused, whatever its status.
    if (!(Js.get(login, "token") instanceof String signedIn) || signedIn.isEmpty()) {
      throw new ImportError("The key or sign-in was refused", "import_refused");
    }
    return new SignIn(base, signedIn);
  }

  /** Every page of an Umami list for a time window. */
  private List<Object> all(String base, String path, Map<String, String> headers) {
    List<Object> out = new ArrayList<>();
    for (int page = 1; ; page++) {
      Object body =
          http.getJson(base + "/api" + path + "&page=" + page + "&pageSize=1000", headers);
      List<Object> data = Js.list(Js.get(body, "data"));
      out.addAll(data);
      if (out.size() >= Js.toNumber(Js.get(body, "count")) || data.isEmpty()) {
        return out;
      }
    }
  }

  @Override
  public Map<String, Object> step(Map<String, String> credentials, String cursor, Known known) {
    // A key comes with every step; only a sign-in token, which expires, rides in the cursor.
    Object saved =
        cursor != null && !cursor.isEmpty() ? Json.parse(cursor) : Json.object("page", 1L);
    String key = Http.credential(credentials, "apiKey");
    SignIn signIn = umamiSignIn(http, credentials, Js.get(saved, "token"));
    String base = signIn.base();
    Object page = Js.get(saved, "page");
    Object token = signIn.token();
    Map<String, String> headers = Map.of("authorization", "Bearer " + Js.string(token));
    Object list =
        http.getJson(base + "/api/links?page=" + Js.string(page) + "&pageSize=" + PAGE, headers);
    List<Object> data = Js.list(Js.get(list, "data"));

    List<Object> links = new ArrayList<>();
    for (Object l : data) {
      if (Js.truthy(Js.get(l, "deletedAt"))) {
        continue;
      }
      Object id = Js.get(l, "id");
      if (known.known(id, Js.get(l, "slug"), Js.get(l, "url"))) {
        links.add(
            Json.object(
                "link",
                Json.object(
                    "sourceId",
                    id,
                    "slug",
                    Js.get(l, "slug"),
                    "domain",
                    "",
                    "name",
                    Js.get(l, "name"),
                    "url",
                    Js.get(l, "url"),
                    "createdAt",
                    0L),
                "known",
                true));
        continue;
      }
      double parsed = Http.parseDate(Js.get(l, "createdAt"));
      double created = Js.truthy(parsed) ? parsed : now.getAsLong();
      String range =
          "startAt="
              + Js.string(Js.num(created - 86_400_000))
              + "&endAt="
              + Js.string(Js.num((double) now.getAsLong() + 60_000));
      // TS asks for both at once; here one follows the other.
      List<Object> events = all(base, "/websites/" + Js.string(id) + "/events?" + range, headers);
      List<Object> sessions =
          all(base, "/websites/" + Js.string(id) + "/sessions?" + range, headers);
      Map<String, Object> info = new HashMap<>();
      for (Object s : sessions) {
        info.put(Js.string(Js.get(s, "id")), s);
      }
      List<Object> clicks = new ArrayList<>();
      for (Object e : events) {
        Object s = info.getOrDefault(Js.string(Js.get(e, "sessionId")), Json.UNDEFINED);
        Object domain = Js.get(e, "referrerDomain");
        Object path = Js.get(e, "referrerPath");
        clicks.add(
            Http.defined(
                Json.object(
                    "ts", Js.num(Http.parseDate(Js.get(e, "createdAt"))),
                    "visit", Js.get(e, "sessionId"),
                    "referrer",
                        Js.truthy(domain)
                            ? "https://"
                                + Js.string(domain)
                                + (Js.truthy(path) ? Js.string(path) : "/")
                            : "",
                    "path", Js.get(e, "urlPath"),
                    "query", Js.get(e, "urlQuery"),
                    "country", Js.get(e, "country"),
                    "region", Js.get(s, "region"),
                    "city", Js.get(e, "city"),
                    "browser", Js.get(e, "browser"),
                    "os", Js.get(e, "os"),
                    "device", Js.get(e, "device"),
                    "screen", Js.get(s, "screen"),
                    "language", Js.get(s, "language"))));
      }
      links.add(
          Json.object(
              "link",
              Json.object(
                  "sourceId", id,
                  "slug", Js.get(l, "slug"),
                  "domain", Http.coalesce(Js.get(Js.get(l, "customDomain"), "domain"), ""),
                  "name", Js.get(l, "name"),
                  "url", Js.get(l, "url"),
                  "createdAt", Js.num(created)),
              "clicks",
              clicks));
    }
    // Without a count there is no total, and a full page may have more after it.
    Object count =
        Js.get(list, "count") instanceof Number n && Double.isFinite(n.doubleValue()) ? n : null;
    boolean more =
        count == null
            ? data.size() == PAGE
            : Js.toNumber(page) * PAGE < ((Number) count).doubleValue() && !data.isEmpty();
    Object nextPage = Js.num(Js.toNumber(page) + 1);
    Map<String, Object> next =
        !key.isEmpty()
            ? Json.object("page", nextPage)
            : Json.object("page", nextPage, "token", token);
    return Json.object(
        "cursor", more ? Json.stringify(next) : null, "total", count, "links", links);
  }
}
