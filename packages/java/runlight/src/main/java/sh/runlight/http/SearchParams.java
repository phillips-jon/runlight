package sh.runlight.http;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import sh.runlight.Js;

/**
 * Query parameters as JavaScript's URLSearchParams reads and writes them: pairs kept in order,
 * {@code +} read as a space, and written back in the application/x-www-form-urlencoded form.
 */
public final class SearchParams {
  private List<String[]> pairs = new ArrayList<>();

  public SearchParams() {}

  /** Parses a query string, with or without its leading {@code ?}. */
  public SearchParams(String init) {
    if (init.startsWith("?")) {
      init = init.substring(1);
    }
    if (init.isEmpty()) {
      return;
    }
    for (String part : init.split("&", -1)) {
      if (part.isEmpty()) {
        continue;
      }
      int at = part.indexOf('=');
      String name = at < 0 ? part : part.substring(0, at);
      String value = at < 0 ? "" : part.substring(at + 1);
      pairs.add(new String[] {decode(name), decode(value)});
    }
  }

  /** Pairs from a map, in its order. */
  public SearchParams(Map<String, String> init) {
    for (Map.Entry<String, String> entry : init.entrySet()) {
      pairs.add(new String[] {entry.getKey(), entry.getValue()});
    }
  }

  public String get(String name) {
    for (String[] pair : pairs) {
      if (pair[0].equals(name)) {
        return pair[1];
      }
    }
    return null;
  }

  public List<String> getAll(String name) {
    List<String> out = new ArrayList<>();
    for (String[] pair : pairs) {
      if (pair[0].equals(name)) {
        out.add(pair[1]);
      }
    }
    return out;
  }

  public boolean has(String name) {
    return get(name) != null;
  }

  public void set(String name, String value) {
    boolean found = false;
    List<String[]> next = new ArrayList<>();
    for (String[] pair : pairs) {
      if (!pair[0].equals(name)) {
        next.add(pair);
      } else if (!found) {
        next.add(new String[] {name, value});
        found = true;
      }
    }
    if (!found) {
      next.add(new String[] {name, value});
    }
    pairs = next;
  }

  public void append(String name, String value) {
    pairs.add(new String[] {name, value});
  }

  public void delete(String name) {
    pairs.removeIf(pair -> pair[0].equals(name));
  }

  public List<String> keys() {
    List<String> out = new ArrayList<>();
    for (String[] pair : pairs) {
      out.add(pair[0]);
    }
    return out;
  }

  /** The pairs, in order. */
  public List<Map.Entry<String, String>> entries() {
    List<Map.Entry<String, String>> out = new ArrayList<>();
    for (String[] pair : pairs) {
      out.add(Map.entry(pair[0], pair[1]));
    }
    return out;
  }

  public int size() {
    return pairs.size();
  }

  @Override
  public String toString() {
    StringBuilder out = new StringBuilder();
    for (String[] pair : pairs) {
      if (out.length() > 0) {
        out.append('&');
      }
      out.append(encode(pair[0])).append('=').append(encode(pair[1]));
    }
    return out.toString();
  }

  /** Percent-decoding with {@code +} as a space; bytes that are not UTF-8 become U+FFFD. */
  static String decode(String text) {
    if (text.indexOf('%') < 0 && text.indexOf('+') < 0) {
      return text;
    }
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    byte[] source = Js.utf8(text);
    for (int i = 0; i < source.length; i++) {
      byte b = source[i];
      if (b == '+') {
        bytes.write(' ');
      } else if (b == '%'
          && i + 2 < source.length
          && hex(source[i + 1]) >= 0
          && hex(source[i + 2]) >= 0) {
        bytes.write(hex(source[i + 1]) * 16 + hex(source[i + 2]));
        i += 2;
      } else {
        bytes.write(b);
      }
    }
    return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
  }

  private static int hex(byte b) {
    if (b >= '0' && b <= '9') {
      return b - '0';
    }
    if (b >= 'a' && b <= 'f') {
      return b - 'a' + 10;
    }
    if (b >= 'A' && b <= 'F') {
      return b - 'A' + 10;
    }
    return -1;
  }

  /** The form encoding: letters, digits, and *-._ as they are, spaces as +, the rest escaped. */
  public static String encode(String text) {
    StringBuilder out = new StringBuilder(text.length());
    for (byte b : Js.utf8(text)) {
      int v = b & 0xFF;
      if ((v >= 'A' && v <= 'Z')
          || (v >= 'a' && v <= 'z')
          || (v >= '0' && v <= '9')
          || v == '*'
          || v == '-'
          || v == '.'
          || v == '_') {
        out.append((char) v);
      } else if (v == ' ') {
        out.append('+');
      } else {
        out.append(String.format("%%%02X", v));
      }
    }
    return out.toString();
  }
}
