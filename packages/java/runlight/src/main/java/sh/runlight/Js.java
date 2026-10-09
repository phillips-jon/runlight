package sh.runlight;

import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CharsetEncoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.AbstractMap;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The JavaScript string, number, and value rules the port has to keep exactly: trim() with
 * JavaScript's idea of white space, slice with negative indices, decodeURIComponent's strictness,
 * String(value), Number(value), Math.round, truthiness, property reads, and UTF-8 out with U+FFFD
 * for a lone surrogate.
 *
 * <p>Java strings are UTF-16 as JavaScript's are, so lengths, slices, and comparisons with {@code
 * <} count and cut exactly as the SDK does.
 */
public final class Js {
  private Js() {}

  /** The characters JavaScript's \s and trim() treat as white space, for a character class. */
  public static final String SPACE =
      "\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}";

  /** Any character JavaScript's {@code .} matches, for a Java pattern. */
  public static final String DOT = "[^\\n\\r\\x{2028}\\x{2029}]";

  /** String.prototype.trim. */
  public static String trim(String text) {
    int start = 0;
    int end = text.length();
    while (start < end && isSpace(text.charAt(start))) {
      start++;
    }
    while (end > start && isSpace(text.charAt(end - 1))) {
      end--;
    }
    return text.substring(start, end);
  }

  /** String.prototype.trimStart. */
  public static String trimStart(String text) {
    int start = 0;
    while (start < text.length() && isSpace(text.charAt(start))) {
      start++;
    }
    return text.substring(start);
  }

  /** String.prototype.trimEnd. */
  public static String trimEnd(String text) {
    int end = text.length();
    while (end > 0 && isSpace(text.charAt(end - 1))) {
      end--;
    }
    return text.substring(0, end);
  }

  /** Whether JavaScript's \s matches this character. */
  public static boolean isSpace(char c) {
    return c == '\t'
        || c == '\n'
        || c == 0x0B
        || c == '\f'
        || c == '\r'
        || c == ' '
        || c == 0xA0
        || c == 0x1680
        || (c >= 0x2000 && c <= 0x200A)
        || c == 0x2028
        || c == 0x2029
        || c == 0x202F
        || c == 0x205F
        || c == 0x3000
        || c == 0xFEFF;
  }

  public static String lower(String text) {
    return text.toLowerCase(Locale.ROOT);
  }

  public static String upper(String text) {
    return text.toUpperCase(Locale.ROOT);
  }

  /** String.prototype.slice(start). */
  public static String slice(String text, int start) {
    return slice(text, start, text.length());
  }

  /** String.prototype.slice(start, end), counting UTF-16 code units. */
  public static String slice(String text, int start, int end) {
    int count = text.length();
    int from = start < 0 ? Math.max(0, count + start) : Math.min(start, count);
    int to = end < 0 ? Math.max(0, count + end) : Math.min(end, count);
    return to <= from ? "" : text.substring(from, to);
  }

  /**
   * decodeURIComponent, or null where it would throw: a broken escape or bytes that are not UTF-8.
   */
  public static String decodeURIComponent(String text) {
    if (text.indexOf('%') < 0) {
      return text;
    }
    StringBuilder out = new StringBuilder(text.length());
    int i = 0;
    int length = text.length();
    while (i < length) {
      char c = text.charAt(i);
      if (c != '%') {
        out.append(c);
        i++;
        continue;
      }
      int b = hexByte(text, i);
      if (b < 0) {
        return null;
      }
      i += 3;
      if (b < 0x80) {
        out.append((char) b);
        continue;
      }
      int need;
      int low = 0x80;
      int high = 0xBF;
      if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
      } else if (b == 0xE0) {
        need = 2;
        low = 0xA0;
      } else if (b == 0xED) {
        need = 2;
        high = 0x9F;
      } else if (b >= 0xE1 && b <= 0xEF) {
        need = 2;
      } else if (b == 0xF0) {
        need = 3;
        low = 0x90;
      } else if (b >= 0xF1 && b <= 0xF3) {
        need = 3;
      } else if (b == 0xF4) {
        need = 3;
        high = 0x8F;
      } else {
        return null;
      }
      int code = b & (0xFF >> (need + 2));
      for (int k = 0; k < need; k++) {
        if (i >= length || text.charAt(i) != '%') {
          return null;
        }
        int next = hexByte(text, i);
        if (next < 0) {
          return null;
        }
        if (next < (k == 0 ? low : 0x80) || next > (k == 0 ? high : 0xBF)) {
          return null;
        }
        code = (code << 6) | (next & 0x3F);
        i += 3;
      }
      out.appendCodePoint(code);
    }
    return out.toString();
  }

  private static int hexByte(String text, int at) {
    if (at + 2 >= text.length()) {
      return -1;
    }
    int a = Character.digit(text.charAt(at + 1), 16);
    int b = Character.digit(text.charAt(at + 2), 16);
    if (a < 0 || b < 0 || text.charAt(at + 1) > 127 || text.charAt(at + 2) > 127) {
      return -1;
    }
    return a * 16 + b;
  }

  private static final String URI_UNRESERVED =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";

  /** encodeURIComponent(text); a lone surrogate is written as U+FFFD where JavaScript throws. */
  public static String encodeURIComponent(String text) {
    return encode(text, URI_UNRESERVED);
  }

  /** encodeURI(text). */
  public static String encodeURI(String text) {
    return encode(text, URI_UNRESERVED + ";,/?:@&=+$#");
  }

  private static String encode(String text, String keep) {
    StringBuilder out = new StringBuilder(text.length());
    for (byte b : utf8(text)) {
      int v = b & 0xFF;
      if (v < 128 && keep.indexOf(v) >= 0) {
        out.append((char) v);
      } else {
        out.append('%').append(Character.toUpperCase(Character.forDigit(v >> 4, 16)));
        out.append(Character.toUpperCase(Character.forDigit(v & 15, 16)));
      }
    }
    return out.toString();
  }

  /** Text as UTF-8, each lone surrogate written as U+FFFD, as JavaScript's TextEncoder does. */
  public static byte[] utf8(String text) {
    CharsetEncoder encoder =
        StandardCharsets.UTF_8
            .newEncoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
            .replaceWith(new byte[] {(byte) 0xEF, (byte) 0xBF, (byte) 0xBD});
    try {
      ByteBuffer buffer = encoder.encode(CharBuffer.wrap(text));
      byte[] out = new byte[buffer.remaining()];
      buffer.get(out);
      return out;
    } catch (CharacterCodingException e) {
      throw new IllegalStateException(e);
    }
  }

  /** String.prototype.toWellFormed: each lone surrogate as U+FFFD. */
  public static String wellFormed(String text) {
    int length = text.length();
    StringBuilder out = null;
    for (int i = 0; i < length; i++) {
      char c = text.charAt(i);
      boolean lone;
      if (Character.isHighSurrogate(c)) {
        lone = i + 1 >= length || !Character.isLowSurrogate(text.charAt(i + 1));
        if (!lone) {
          if (out != null) {
            out.append(c).append(text.charAt(i + 1));
          }
          i++;
          continue;
        }
      } else {
        lone = Character.isLowSurrogate(c);
      }
      if (lone && out == null) {
        out = new StringBuilder(length);
        out.append(text, 0, i);
      }
      if (out != null) {
        out.append(lone ? '�' : c);
      }
    }
    return out == null ? text : out.toString();
  }

  /** Bytes as text, as TextDecoder reads them: a byte order mark dropped, bad bytes as U+FFFD. */
  public static String decodeUtf8(byte[] bytes) {
    int start =
        bytes.length >= 3
                && (bytes[0] & 0xFF) == 0xEF
                && (bytes[1] & 0xFF) == 0xBB
                && (bytes[2] & 0xFF) == 0xBF
            ? 3
            : 0;
    return new String(bytes, start, bytes.length - start, StandardCharsets.UTF_8);
  }

  /** String(value) for the values the SDK passes it. */
  public static String string(Object value) {
    if (value == null) {
      return "null";
    }
    if (value == Json.UNDEFINED) {
      return "undefined";
    }
    if (value instanceof Boolean b) {
      return b ? "true" : "false";
    }
    if (value instanceof Double || value instanceof Float) {
      return Json.number(((Number) value).doubleValue());
    }
    if (value instanceof Number n) {
      return Json.jsonNumber(n);
    }
    if (value instanceof String s) {
      return s;
    }
    if (value instanceof List<?> list) {
      StringBuilder out = new StringBuilder();
      boolean first = true;
      for (Object item : list) {
        if (!first) {
          out.append(',');
        }
        first = false;
        if (item != null && item != Json.UNDEFINED) {
          out.append(string(item));
        }
      }
      return out.toString();
    }
    if (value instanceof Map<?, ?>) {
      return "[object Object]";
    }
    return value.toString();
  }

  /** Math.round: halves go up, toward positive infinity, so -2.5 becomes -2. */
  public static double round(double value) {
    if (Double.isNaN(value) || Double.isInfinite(value)) {
      return value;
    }
    double floor = Math.floor(value);
    return value - floor >= 0.5 ? floor + 1 : floor;
  }

  private static final Pattern DECIMAL =
      Pattern.compile("^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?\\z");
  private static final Pattern PREFIXED = Pattern.compile("^0([xXoObB])([0-9a-zA-Z]+)\\z");

  /** Number(value). */
  public static double toNumber(Object value) {
    if (value == null || Boolean.FALSE.equals(value)) {
      return 0;
    }
    if (Boolean.TRUE.equals(value)) {
      return 1;
    }
    if (value instanceof Number n) {
      return n.doubleValue();
    }
    if (value instanceof List<?>) {
      return toNumber(string(value));
    }
    if (!(value instanceof String s)) {
      return Double.NaN;
    }
    String text = trim(s);
    if (text.isEmpty()) {
      return 0;
    }
    var prefixed = PREFIXED.matcher(text);
    if (prefixed.matches()) {
      char kind = Character.toLowerCase(prefixed.group(1).charAt(0));
      int base = kind == 'x' ? 16 : kind == 'o' ? 8 : 2;
      double n = 0;
      for (char c : prefixed.group(2).toCharArray()) {
        int digit = Character.digit(c, base);
        if (digit < 0) {
          return Double.NaN;
        }
        n = n * base + digit;
      }
      return n;
    }
    if (text.equals("Infinity") || text.equals("+Infinity")) {
      return Double.POSITIVE_INFINITY;
    }
    if (text.equals("-Infinity")) {
      return Double.NEGATIVE_INFINITY;
    }
    if (!DECIMAL.matcher(text).matches()) {
      return Double.NaN;
    }
    return Double.parseDouble(text);
  }

  /**
   * A number in this port's form: a {@link Long} when it is whole and JavaScript holds it exactly,
   * else a {@link Double}. Anything else is returned as it is.
   */
  public static Object num(Object value) {
    if (value instanceof Long) {
      return value;
    }
    if (value instanceof Integer || value instanceof Short || value instanceof Byte) {
      return ((Number) value).longValue();
    }
    if (value instanceof Number n) {
      double d = n.doubleValue();
      if (d == Math.rint(d) && Math.abs(d) <= 9007199254740992.0 && !(d == 0 && 1 / d < 0)) {
        return (long) d;
      }
      return d;
    }
    return value;
  }

  /** A double in this port's number form. */
  public static Object num(double value) {
    return num((Object) value);
  }

  /** Whether typeof value is "number". */
  public static boolean isNumber(Object value) {
    return value instanceof Number;
  }

  /** Number.isFinite(value). */
  public static boolean isFinite(Object value) {
    return value instanceof Number n
        && !Double.isNaN(n.doubleValue())
        && !Double.isInfinite(n.doubleValue());
  }

  /** Number.isInteger(value). */
  public static boolean isInteger(Object value) {
    if (!isFinite(value)) {
      return false;
    }
    double d = ((Number) value).doubleValue();
    return d == Math.floor(d);
  }

  /** Whether JavaScript reads a value as true. */
  public static boolean truthy(Object value) {
    if (value == null || value == Json.UNDEFINED || Boolean.FALSE.equals(value)) {
      return false;
    }
    if (value instanceof String s) {
      return !s.isEmpty();
    }
    if (value instanceof Number n) {
      double d = n.doubleValue();
      return d != 0 && !Double.isNaN(d);
    }
    return true;
  }

  /** Whether typeof value is "object" and it is not null: an array or an object. */
  public static boolean isObject(Object value) {
    return value instanceof Map<?, ?> || value instanceof List<?>;
  }

  /** Whether the value is a plain object, not an array or null. */
  public static boolean isPlainObject(Object value) {
    return value instanceof Map<?, ?>;
  }

  /** value[key]: {@link Json#UNDEFINED} when there is no such property. */
  public static Object get(Object value, String key) {
    if (value instanceof Map<?, ?> map) {
      return map.containsKey(key) ? map.get(key) : Json.UNDEFINED;
    }
    if (value instanceof List<?> list) {
      if (key.equals("length")) {
        return (long) list.size();
      }
      int index = arrayIndex(key);
      return index >= 0 && index < list.size() ? list.get(index) : Json.UNDEFINED;
    }
    if (value instanceof String s && key.equals("length")) {
      return (long) s.length();
    }
    return Json.UNDEFINED;
  }

  /** The value as an object map, or null when it is not one. */
  @SuppressWarnings("unchecked")
  public static Map<String, Object> map(Object value) {
    return value instanceof Map<?, ?> m ? (Map<String, Object>) m : null;
  }

  /** The value as an array, or null when it is not one. */
  @SuppressWarnings("unchecked")
  public static List<Object> list(Object value) {
    return value instanceof List<?> l ? (List<Object>) l : null;
  }

  /** map[key] when it is a string, else null. */
  public static String str(Map<String, Object> map, String key) {
    return map != null && map.get(key) instanceof String s ? s : null;
  }

  /** typeof value === "string" ? value : fallback. */
  public static String strOr(Object value, String fallback) {
    return value instanceof String s ? s : fallback;
  }

  /** The value as a long, when it is a number. */
  public static long asLong(Object value) {
    if (value instanceof Number n) {
      return n.longValue();
    }
    double d = toNumber(value);
    return Double.isNaN(d) ? 0 : (long) d;
  }

  /** The value as a double, Number(value). */
  public static double asDouble(Object value) {
    return value instanceof Number n ? n.doubleValue() : toNumber(value);
  }

  /** Two values as JavaScript's === sees them, numbers compared by value. */
  public static boolean same(Object a, Object b) {
    if (a instanceof Number x && b instanceof Number y) {
      return x.doubleValue() == y.doubleValue();
    }
    return a == null ? b == null : a.equals(b);
  }

  /**
   * An object's entries in JavaScript's property order: array-index keys first in ascending order,
   * then the others as inserted.
   */
  public static List<Map.Entry<String, Object>> entries(Map<?, ?> map) {
    List<Map.Entry<String, Object>> indexed = null;
    List<Map.Entry<String, Object>> named = new ArrayList<>(map.size());
    for (Map.Entry<?, ?> entry : map.entrySet()) {
      Map.Entry<String, Object> e =
          new AbstractMap.SimpleImmutableEntry<>(String.valueOf(entry.getKey()), entry.getValue());
      if (arrayIndex(e.getKey()) >= 0) {
        if (indexed == null) {
          indexed = new ArrayList<>();
        }
        indexed.add(e);
      } else {
        named.add(e);
      }
    }
    if (indexed == null) {
      return named;
    }
    indexed.sort((a, b) -> Integer.compare(arrayIndex(a.getKey()), arrayIndex(b.getKey())));
    indexed.addAll(named);
    return indexed;
  }

  /** Object.keys(map), in JavaScript's order. */
  public static List<String> keys(Map<?, ?> map) {
    List<String> out = new ArrayList<>();
    for (Map.Entry<String, Object> e : entries(map)) {
      out.add(e.getKey());
    }
    return out;
  }

  /** The index a key names when it is a canonical array index, else -1. */
  public static int arrayIndex(String key) {
    int length = key.length();
    if (length == 0 || length > 10) {
      return -1;
    }
    if (length > 1 && key.charAt(0) == '0') {
      return -1;
    }
    long value = 0;
    for (int i = 0; i < length; i++) {
      char c = key.charAt(i);
      if (c < '0' || c > '9') {
        return -1;
      }
      value = value * 10 + (c - '0');
    }
    return value < 4294967295L && value <= Integer.MAX_VALUE ? (int) value : -1;
  }

  /** Orders two strings as JavaScript's {@code <} does, by UTF-16 code units. */
  public static int compare(String a, String b) {
    return Integer.signum(a.compareTo(b));
  }

  /** The values of a collection as strings, String(value) each. */
  public static List<String> strings(Collection<?> values) {
    List<String> out = new ArrayList<>(values.size());
    for (Object value : values) {
      out.add(string(value));
    }
    return out;
  }
}
