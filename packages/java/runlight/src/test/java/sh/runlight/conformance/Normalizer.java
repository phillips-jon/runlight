package sh.runlight.conformance;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;

/**
 * The masking http-conformance.ts applies to answers, ported line by line: ids and other random
 * values become placeholders, so answers compare across runs and implementations.
 *
 * <p>The regexes are JavaScript's, written here to read the same way: \z for JavaScript's $ without
 * the m flag, and JavaScript's \s spelled out, since it matches Unicode spaces Java's \s does not.
 */
public final class Normalizer {
  private Normalizer() {}

  /** Headers every implementation must send the same, where it sends them. */
  public static final List<String> HEADERS =
      List.of(
          "content-type",
          "cache-control",
          "location",
          "set-cookie",
          "www-authenticate",
          "allow",
          "content-disposition",
          "content-security-policy",
          "x-frame-options",
          "referrer-policy",
          "x-content-type-options",
          "x-robots-tag",
          "access-control-allow-origin",
          "access-control-allow-methods",
          "access-control-allow-headers",
          "access-control-max-age");

  // The version and the implementation differ between ports and releases, so they are
  // placeholders too.
  private static final List<String> RANDOM =
      List.of("token", "secret", "hint", "version", "library", "language", "ticket", "recovery");

  private static final Pattern SECRET_IN_QUERY =
      Pattern.compile("([?&](?:code|ticket|secret|code_challenge)=)[^&#" + Js.SPACE + "\"'<>]+");
  private static final Pattern HEX =
      Pattern.compile("(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])");
  private static final Pattern KEY =
      Pattern.compile("(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])");
  private static final Pattern WHOLE_KEY = Pattern.compile("^rlo?_[A-Za-z0-9]+\\z");
  private static final Pattern WHOLE_ID = Pattern.compile("^[a-f0-9]{24}\\z");
  private static final Pattern COOKIE = Pattern.compile("^([^=;]+)=([^;]*)");

  /**
   * Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and
   * signatures.
   */
  public static String scrub(String text) {
    text = SECRET_IN_QUERY.matcher(text).replaceAll("$1<value>");
    text = HEX.matcher(text).replaceAll("<hex>");
    return KEY.matcher(text).replaceAll("<key>");
  }

  public static Object normalize(Object value) {
    return normalize(value, "");
  }

  /** Ids and other random values become "&lt;key&gt;", so answers compare across runs. */
  public static Object normalize(Object value, String key) {
    if (value instanceof List<?> list) {
      List<Object> out = new ArrayList<>();
      for (Object item : list) {
        out.add(normalize(item, key));
      }
      return out;
    }
    if (value instanceof Map<?, ?> map) {
      Map<String, Object> out = new java.util.LinkedHashMap<>();
      for (Map.Entry<?, ?> e : map.entrySet()) {
        out.put(String.valueOf(e.getKey()), normalize(e.getValue(), String.valueOf(e.getKey())));
      }
      return out;
    }
    if (value instanceof String s) {
      if (RANDOM.contains(key) || WHOLE_KEY.matcher(s).find() || WHOLE_ID.matcher(s).find()) {
        return "<" + (!key.isEmpty() ? key : "value") + ">";
      }
      return scrub(s);
    }
    return value;
  }

  /** A Set-Cookie header with its value as &lt;value&gt;, unless it clears the cookie. */
  public static String cookieShape(String header) {
    Matcher m = COOKIE.matcher(header);
    if (!m.find()) {
      return header;
    }
    return m.group(1) + "=" + (m.group(2).isEmpty() ? "" : "<value>") + header.substring(m.end());
  }

  /**
   * Answers as one text to compare: object keys sorted, since JavaScript's deepEqual ignores their
   * order, and written as JSON.stringify writes them.
   */
  public static String canonical(Object value) {
    return Json.stringify(sorted(value), 2);
  }

  private static Object sorted(Object value) {
    if (value instanceof List<?> list) {
      List<Object> out = new ArrayList<>();
      for (Object item : list) {
        out.add(sorted(item));
      }
      return out;
    }
    if (value instanceof Map<?, ?> map) {
      // An ordinary map, so keys that look like array indices keep the sorted order too.
      Map<String, Object> keys = new TreeMap<>();
      for (Map.Entry<?, ?> e : map.entrySet()) {
        keys.put(String.valueOf(e.getKey()), sorted(e.getValue()));
      }
      return new java.util.LinkedHashMap<>(keys);
    }
    return value;
  }
}
