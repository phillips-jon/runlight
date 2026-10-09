package sh.runlight.http;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Header names are matched without regard to case, as the Fetch API's Headers are. get() joins
 * repeated values with ", "; Set-Cookie is kept apart, since its values may hold commas, and read
 * back with getSetCookie().
 */
public final class Headers {
  private final Map<String, List<String>> values = new LinkedHashMap<>();

  public Headers() {}

  /** A copy of other headers. */
  public Headers(Headers other) {
    for (Map.Entry<String, List<String>> entry : other.values.entrySet()) {
      values.put(entry.getKey(), new ArrayList<>(entry.getValue()));
    }
  }

  /** Headers from name and value pairs: {@code Headers.of("content-type", "text/plain")}. */
  public static Headers of(String... pairs) {
    Headers headers = new Headers();
    for (int i = 0; i + 1 < pairs.length; i += 2) {
      headers.append(pairs[i], pairs[i + 1]);
    }
    return headers;
  }

  /** Headers from a map of names to values. */
  public static Headers of(Map<String, String> map) {
    Headers headers = new Headers();
    for (Map.Entry<String, String> entry : map.entrySet()) {
      headers.append(entry.getKey(), entry.getValue());
    }
    return headers;
  }

  public String get(String name) {
    List<String> list = values.get(name.toLowerCase(Locale.ROOT));
    return list == null ? null : String.join(", ", list);
  }

  public boolean has(String name) {
    return values.containsKey(name.toLowerCase(Locale.ROOT));
  }

  public Headers set(String name, String value) {
    List<String> list = new ArrayList<>();
    list.add(clean(value));
    values.put(name.toLowerCase(Locale.ROOT), list);
    return this;
  }

  public Headers append(String name, String value) {
    values.computeIfAbsent(name.toLowerCase(Locale.ROOT), k -> new ArrayList<>()).add(clean(value));
    return this;
  }

  public void delete(String name) {
    values.remove(name.toLowerCase(Locale.ROOT));
  }

  public List<String> getSetCookie() {
    List<String> list = values.get("set-cookie");
    return list == null ? List.of() : List.copyOf(list);
  }

  /** Every lowercase name with its values, in the order first set. */
  public Map<String, List<String>> all() {
    return values;
  }

  /** Name and joined value pairs in name order, as iterating Fetch Headers gives them. */
  public List<Map.Entry<String, String>> entries() {
    List<String> names = new ArrayList<>(values.keySet());
    names.sort(null);
    List<Map.Entry<String, String>> out = new ArrayList<>();
    for (String name : names) {
      if (name.equals("set-cookie")) {
        for (String value : values.get(name)) {
          out.add(Map.entry(name, value));
        }
      } else {
        out.add(Map.entry(name, String.join(", ", values.get(name))));
      }
    }
    return out;
  }

  /**
   * Header values never carry a line break, so nothing a caller passes can add a header of its own.
   */
  private static String clean(String value) {
    return value.replace("\r", "").replace("\n", "").replace("\0", "").strip();
  }

  @Override
  public String toString() {
    return "Headers" + values.keySet();
  }
}
