package sh.runlight.conformance;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.http.BodyTooLong;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.http.SearchParams;

/**
 * The servers a scenario stands in for, as the fake fetch in http-conformance.ts plays them: a
 * request goes to the first upstream whose url its URL starts with (and whose method matches, when
 * one is given); a request none matches fails as a network error does. Every request is recorded,
 * matched or not.
 */
public final class UpstreamFetcher implements Fetcher {
  /** One request a step made: what the answers record of it, and its body as sent. */
  public record Sent(Map<String, Object> seen, String text) {}

  private final List<Map<String, Object>> upstream;
  private final List<Sent> fetched = new ArrayList<>();

  @SuppressWarnings("unchecked")
  public UpstreamFetcher(Object upstream) {
    this.upstream = upstream instanceof List<?> list ? (List<Map<String, Object>>) list : List.of();
  }

  /** The servers stood in for are on the public internet, wherever their names point. */
  @Override
  public List<String> lookup(String name) {
    return List.of("93.184.215.14");
  }

  @Override
  public synchronized Response fetch(String url, FetchInit init) {
    String method = Js.upper(init.method);
    Map<String, Object> given = new LinkedHashMap<>();
    for (Map.Entry<String, String> e : init.headers.entries()) {
      given.put(e.getKey(), e.getValue());
    }
    String text = init.bodyText() == null ? "" : init.bodyText();
    Map<String, Object> seen = new LinkedHashMap<>();
    seen.put("method", method);
    seen.put("url", url);
    if (!given.isEmpty()) {
      seen.put("headers", given);
    }
    if (!text.isEmpty()) {
      Object type = given.get("content-type");
      seen.put("body", sentBody(text, type == null ? "" : (String) type));
    }
    fetched.add(new Sent(seen, text));

    Map<String, Object> match = null;
    for (Map<String, Object> u : upstream) {
      Object wanted = u.get("method");
      if (url.startsWith((String) u.get("url")) && (!Js.truthy(wanted) || method.equals(wanted))) {
        match = u;
        break;
      }
    }
    if (match == null) {
      throw new FetchError("fetch failed");
    }
    boolean hasBody = match.containsKey("body");
    Object given1 = match.get("body");
    String body = !hasBody ? "" : given1 instanceof String s ? s : Json.stringify(given1);
    Headers headers = new Headers();
    // typeof null is "object" too, so a null body is sent as JSON.
    if (hasBody
        && !(given1 instanceof String)
        && !(given1 instanceof Number)
        && !(given1 instanceof Boolean)) {
      headers.set("content-type", "application/json");
    }
    if (match.get("headers") instanceof Map<?, ?> extra) {
      for (Map.Entry<?, ?> e : extra.entrySet()) {
        headers.set(String.valueOf(e.getKey()), Js.string(e.getValue()));
      }
    }
    // The cap a real Fetcher keeps, so code that reads only the start of a page sees what it would.
    byte[] bytes = Js.utf8(body);
    if (init.maxBytes != null && bytes.length > init.maxBytes) {
      if (!init.truncate) {
        throw new BodyTooLong("Body over " + init.maxBytes + " bytes");
      }
      bytes = Arrays.copyOf(bytes, (int) (long) init.maxBytes);
    }
    Object status = match.get("status");
    return new Response(bytes, status == null ? 200 : (int) Js.asLong(status), headers);
  }

  /** The requests made since the last take, and forgets them. */
  public synchronized List<Sent> take() {
    List<Sent> out = new ArrayList<>(fetched);
    fetched.clear();
    return out;
  }

  /** A body another server was sent, as JSON or form fields when it is one of those, else text. */
  public static Object sentBody(String text, String type) {
    if (type.startsWith("application/x-www-form-urlencoded")) {
      Map<String, Object> fields = new LinkedHashMap<>();
      for (Map.Entry<String, String> e : new SearchParams(text).entries()) {
        fields.put(e.getKey(), e.getValue());
      }
      return fields;
    }
    Json.Parsed parsed = Json.tryParse(text);
    return parsed.ok() ? parsed.value() : text;
  }
}
