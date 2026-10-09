package sh.runlight;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.http.Url;

/**
 * What the tracker sends, after validation. Anything malformed is dropped.
 *
 * <p>A payload is an object with kind (pageview, event, or engagement), site, url (a {@link Url}),
 * referrer, title, screenWidth and screenHeight (a number or null), language, name, props (an
 * object of strings, or null), pageviewId, engagedMs, and scroll (a number or null).
 */
public final class Payload {
  private Payload() {}

  public static final int MAX_BODY = 8 * 1024;

  /** One engagement ping covers at most the 30 minutes a session can idle. */
  private static final long MAX_ENGAGED_MS = 30 * 60 * 1000;

  private static final int MAX_PROPS = 30;

  private static final Pattern ID = Pattern.compile("^[a-z0-9]+\\z", Pattern.CASE_INSENSITIVE);

  private static String str(Object value, int max) {
    return value instanceof String s ? Js.slice(s, 0, max) : "";
  }

  private static Long integer(Object value, long min, long max) {
    if (!Js.isFinite(value)) {
      return null;
    }
    double rounded = Js.round(((Number) value).doubleValue());
    return (long) Math.min(max, Math.max(min, rounded));
  }

  private static Map<String, Object> props(Object value) {
    if (!(value instanceof Map<?, ?> map)) {
      return null;
    }
    Map<String, Object> out = new LinkedHashMap<>();
    int count = 0;
    for (Map.Entry<String, Object> entry : Js.entries(map)) {
      if (count >= MAX_PROPS) {
        break;
      }
      String k = Js.slice(Js.trim(entry.getKey()), 0, 60);
      if (k.isEmpty()) {
        continue;
      }
      Object raw = entry.getValue();
      String text;
      if (raw instanceof String s) {
        text = Js.slice(s, 0, 500);
      } else if (raw instanceof Number && Js.isFinite(raw)) {
        text = Js.string(raw);
      } else if (raw instanceof Boolean) {
        text = Js.string(raw);
      } else {
        continue;
      }
      // Assigning a string to __proto__ changes nothing in JavaScript, though it counts.
      if (!k.equals("__proto__")) {
        out.put(k, text);
      }
      count++;
    }
    return count > 0 ? out : null;
  }

  /** The tracker's body read, or null when anything about it is malformed. */
  public static Map<String, Object> parsePayload(String text) {
    if (text.length() > MAX_BODY) {
      return null;
    }
    Json.Parsed parsed = Json.tryParse(text);
    if (!parsed.ok() || !(parsed.value() instanceof Map<?, ?>)) {
      return null;
    }
    Map<String, Object> body = Js.map(parsed.value());

    Object kind = body.get("k");
    if (!"pageview".equals(kind) && !"event".equals(kind) && !"engagement".equals(kind)) {
      return null;
    }

    Url url = Url.parse(str(body.get("u"), 2048));
    if (url == null) {
      return null;
    }
    if (!url.protocol.equals("http:") && !url.protocol.equals("https:")) {
      return null;
    }

    String name = Js.trim(str(body.get("n"), 120));
    if (kind.equals("event") && name.isEmpty()) {
      return null;
    }

    String pageviewId = str(body.get("i"), 32);
    if (!pageviewId.isEmpty() && !ID.matcher(pageviewId).matches()) {
      return null;
    }
    if (kind.equals("engagement") && pageviewId.isEmpty()) {
      return null;
    }

    Long engaged = kind.equals("engagement") ? integer(body.get("e"), 0, MAX_ENGAGED_MS) : null;
    return Json.object(
        "kind", kind,
        "site", str(body.get("s"), 64),
        "url", url,
        "referrer", str(body.get("r"), 2048),
        "title", str(body.get("t"), 500),
        "screenWidth", integer(body.get("w"), 0, 20000),
        "screenHeight", integer(body.get("h"), 0, 20000),
        "language", str(body.get("l"), 35),
        "name", name,
        "props", kind.equals("event") ? props(body.get("p")) : null,
        "pageviewId", pageviewId,
        "engagedMs", engaged == null ? 0L : engaged,
        "scroll", integer(body.get("d"), 0, 100));
  }
}
