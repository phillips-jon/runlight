package sh.runlight;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Report queries: which dimensions exist, where each lives, and how filters are read from a URL.
 * Shared by every store.
 *
 * <p>A filter is an object with dimension, op (is, not, or contains), and value. A query is an
 * object with site, from (inclusive, epoch milliseconds), to (exclusive), and filters.
 */
public final class Query {
  private Query() {}

  /** Dimensions recorded per event, with their column. */
  public static final Map<String, String> EVENT_DIMENSIONS =
      ordered("page", "path", "hostname", "hostname", "event", "name");

  /** Dimensions recorded once per session, from its first request, with their column. */
  public static final Map<String, String> SESSION_DIMENSIONS =
      ordered(
          "entry", "entry_path",
          "exit", "exit_path",
          "referrer", "referrer_host",
          "source", "source",
          "channel", "channel",
          "utm_source", "utm_source",
          "utm_medium", "utm_medium",
          "utm_campaign", "utm_campaign",
          "utm_term", "utm_term",
          "utm_content", "utm_content",
          "country", "country",
          "region", "region",
          "city", "city",
          "browser", "browser",
          "browser_version", "browser_version",
          "os", "os",
          "os_version", "os_version",
          "device", "device",
          "screen", "screen",
          "language", "language");

  /** AI agent fetches are their own rows, outside visits. */
  public static final List<String> FETCH_DIMENSIONS = List.of("ai_agent", "ai_page");

  public static final List<String> DIMENSIONS;

  static {
    List<String> all = new ArrayList<>(EVENT_DIMENSIONS.keySet());
    all.addAll(SESSION_DIMENSIONS.keySet());
    all.addAll(FETCH_DIMENSIONS);
    DIMENSIONS = Collections.unmodifiableList(all);
  }

  /**
   * The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values.
   */
  public static final int MAX_FILTERS = 6;

  private static Map<String, String> ordered(String... pairs) {
    Map<String, String> map = new LinkedHashMap<>();
    for (int i = 0; i < pairs.length; i += 2) {
      map.put(pairs[i], pairs[i + 1]);
    }
    return Collections.unmodifiableMap(map);
  }

  public static boolean isDimension(String value) {
    return DIMENSIONS.contains(value);
  }

  public static boolean isSessionDimension(String value) {
    return SESSION_DIMENSIONS.containsKey(value);
  }

  public static boolean isEventDimension(String value) {
    return EVENT_DIMENSIONS.containsKey(value);
  }

  /** {@code dimension:op:value}, where the value may itself contain colons; null when malformed. */
  public static Map<String, Object> parseFilter(String text) {
    int first = text.indexOf(':');
    int second = first < 0 ? -1 : text.indexOf(':', first + 1);
    if (second < 0) {
      return null;
    }
    String dimension = text.substring(0, first);
    String op = text.substring(first + 1, second);
    String value = text.substring(second + 1);
    if (!isSessionDimension(dimension) && !isEventDimension(dimension)) {
      return null;
    }
    if (!op.equals("is") && !op.equals("not") && !op.equals("contains")) {
      return null;
    }
    return Json.object("dimension", dimension, "op", op, "value", Js.slice(value, 0, 500));
  }
}
