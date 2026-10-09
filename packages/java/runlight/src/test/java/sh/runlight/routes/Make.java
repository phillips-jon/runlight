package sh.runlight.routes;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import sh.runlight.Env;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Runlight;
import sh.runlight.conformance.Player;
import sh.runlight.http.Headers;
import sh.runlight.http.Request;
import sh.runlight.http.Response;
import sh.runlight.store.Stores;

/**
 * What the route tests share: a Runlight on an in-memory SQLite, and requests written as the
 * TypeScript tests write them.
 */
public final class Make {
  private Make() {}

  /** A Runlight with these options and an in-memory SQLite unless a store is given. */
  public static Runlight runlight(Runlight.Options options) {
    if (options.store == null) {
      options.store(Stores.sqlite(":memory:"));
    }
    return new Runlight(options);
  }

  /** Date.UTC with months counted from 1. */
  public static long utc(int y, int m, int d, int h) {
    return sh.runlight.Time.utc(y, m - 1, d, h, 0, 0);
  }

  public static Runlight runlight() {
    return runlight(new Runlight.Options());
  }

  /** One site, as a map, for Options.site or Options.sites. */
  public static Map<String, Object> site(String id, String... hostnames) {
    return Json.object("id", id, "hostnames", List.of((Object[]) hostnames));
  }

  /** Clears the environment the SDK reads defaults from, as the tests' setUp does. */
  public static void clearEnv() {
    for (String name : Player.ENV) {
      Env.override(name, null);
    }
  }

  public static Request req(String path) {
    return req(path, "GET", Map.of(), null);
  }

  public static Request req(String path, String method, Map<String, String> headers) {
    return req(path, method, headers, null);
  }

  /** A request to https://example.com, a string body typed as JavaScript's Request types it. */
  public static Request req(String path, String method, Map<String, String> headers, String body) {
    Map<String, String> all = new LinkedHashMap<>(headers);
    if (body != null && !all.containsKey("content-type")) {
      all.put("content-type", Player.TEXT_BODY_TYPE);
    }
    return new Request(
        "https://example.com" + path, method, Headers.of(all), body == null ? "" : body);
  }

  public static Request owner(String path) {
    return owner(path, "GET", null, "secret");
  }

  public static Request owner(String path, String method, Object body) {
    return owner(path, method, body, "secret");
  }

  /** A JSON request with a bearer token, as the tests' owner sends it. */
  public static Request owner(String path, String method, Object body, String token) {
    Map<String, String> headers = new LinkedHashMap<>();
    headers.put("authorization", "Bearer " + token);
    if (body != null) {
      headers.put("content-type", "application/json");
    }
    return req(path, method, headers, body == null ? null : Json.stringify(body));
  }

  /** The answer's body as JSON. */
  public static Map<String, Object> body(Response response) {
    return Js.map(Json.parse(response.text()));
  }

  /** A field of a JSON value, by a dotted path such as "result.content.0.text". */
  public static Object dig(Object value, String path) {
    Object at = value;
    for (String key : path.split("\\.")) {
      if (at instanceof List<?> list) {
        at = list.get(Integer.parseInt(key));
      } else {
        at = Js.get(at, key);
      }
    }
    return at;
  }

  /** One field of each map in a list. */
  public static List<Object> column(Object rows, String key) {
    List<Object> out = new java.util.ArrayList<>();
    for (Object row : Js.list(rows)) {
      out.add(Js.get(row, key));
    }
    return out;
  }
}
