package sh.runlight;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The dashboard's translations, for text the server writes (email reports). Same keys, same
 * placeholders, so every language stays in one place.
 */
public final class Messages {
  private Messages() {}

  private static final Pattern PLACEHOLDER = Pattern.compile("\\{(\\w+)\\}");

  /** Each language's table as JSON text, from the shared assets. */
  private static volatile Map<String, Object> raw;

  private static final Map<String, Map<String, Object>> PARSED = new ConcurrentHashMap<>();

  private static Map<String, Object> raw() {
    Map<String, Object> found = raw;
    if (found == null) {
      found = Js.map(Json.parse(Version.asset("locales.json")));
      raw = found;
    }
    return found;
  }

  private static Map<String, Object> table(String lang) {
    return PARSED.computeIfAbsent(
        lang, key -> raw().get(key) instanceof String text ? Js.map(Json.parse(text)) : Map.of());
  }

  /** A string from a table, or null where it has none. */
  private static String entry(String lang, String key) {
    return table(lang).get(key) instanceof String s ? s : null;
  }

  public static List<String> languages() {
    List<String> out = new ArrayList<>();
    out.add("en");
    for (String code : raw().keySet()) {
      if (!code.equals("en")) {
        out.add(code);
      }
    }
    return out;
  }

  /**
   * The words for one language: t(key, vars) and tn(key, n, vars), with {@link #lang()} the
   * language used, English when the one asked for is not known.
   */
  public static final class Translator {
    private final String code;

    private Translator(String code) {
      this.code = code;
    }

    /** The language used. */
    public String lang() {
      return code;
    }

    public String t(String key) {
      return t(key, Map.of());
    }

    public String t(String key, Map<String, ?> vars) {
      String text = entry(code, key);
      if (text == null) {
        text = entry("en", key);
      }
      return fill(text == null ? key : text, vars);
    }

    public String tn(String key, Number n) {
      return tn(key, n, Map.of());
    }

    public String tn(String key, Number n, Map<String, ?> vars) {
      String form = plural(code, n);
      String own = entry(code, key + "_" + form);
      if (own == null) {
        own = entry(code, key + "_other");
      }
      return own != null && !own.isEmpty() ? fill(own, vars) : t(key + "_other", vars);
    }

    private static String fill(String text, Map<String, ?> vars) {
      Matcher m = PLACEHOLDER.matcher(text);
      StringBuilder out = new StringBuilder();
      while (m.find()) {
        String replacement =
            vars.containsKey(m.group(1)) ? Js.string(vars.get(m.group(1))) : m.group();
        m.appendReplacement(out, Matcher.quoteReplacement(replacement));
      }
      m.appendTail(out);
      return out.toString();
    }
  }

  /** The words for one language, English when it is not known. */
  public static Translator translator(String lang) {
    return new Translator(languages().contains(lang) ? lang : "en");
  }

  /**
   * Intl.PluralRules(lang).select(n) for the dashboard's languages, by CLDR's cardinal rules. As
   * there, the number is first written with at most three decimals (rounding half away from zero),
   * and its integer digits i and visible decimals v are read from that. Any other language answers
   * "other".
   *
   * <ul>
   *   <li>en, de: one when i = 1 and v = 0
   *   <li>es: one when n = 1; many when i is a non-zero multiple of a million and v = 0
   *   <li>fr, pt: one when i is 0 or 1; many as in es
   * </ul>
   */
  public static String plural(String lang, Number n) {
    double d = n.doubleValue();
    if (Double.isNaN(d) || Double.isInfinite(d)) {
      return "other";
    }
    String[] parts = decimal(n);
    String i = parts[0];
    int v = parts[1].length();
    boolean million = !i.equals("0") && i.length() >= 7 && i.endsWith("000000");
    switch (lang) {
      case "en", "de" -> {
        return i.equals("1") && v == 0 ? "one" : "other";
      }
      case "es" -> {
        if (i.equals("1") && v == 0) {
          return "one";
        }
        return million && v == 0 ? "many" : "other";
      }
      case "fr", "pt" -> {
        if (i.equals("0") || i.equals("1")) {
          return "one";
        }
        return million && v == 0 ? "many" : "other";
      }
      default -> {
        return "other";
      }
    }
  }

  /**
   * A number without its sign as its integer digits and up to three decimals without trailing
   * zeros, from the shortest decimal that reads back as the number, as ICU formats it.
   */
  private static String[] decimal(Number n) {
    String text;
    if (n instanceof Long || n instanceof Integer) {
      text = Long.toString(Math.abs(n.longValue()));
    } else {
      // Double.toString gives the shortest digits that read back (JDK 19 and newer).
      text = new BigDecimal(Double.toString(Math.abs(n.doubleValue()))).toPlainString();
    }
    int dot = text.indexOf('.');
    String whole = dot < 0 ? text : text.substring(0, dot);
    String fraction = dot < 0 ? "" : text.substring(dot + 1);
    if (fraction.length() > 3) {
      boolean up = fraction.charAt(3) >= '5';
      fraction = fraction.substring(0, 3);
      if (up) {
        // Add one at the third decimal, carrying into the whole part.
        String all = Intl.increment(whole + fraction);
        whole = all.substring(0, all.length() - 3);
        fraction = all.substring(all.length() - 3);
      }
    }
    // ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so
    // 1e21 has i = 0.
    whole = stripLeadingZeros(whole.length() > 18 ? whole.substring(whole.length() - 18) : whole);
    return new String[] {whole.isEmpty() ? "0" : whole, stripTrailingZeros(fraction)};
  }

  static String stripLeadingZeros(String digits) {
    int at = 0;
    while (at < digits.length() && digits.charAt(at) == '0') {
      at++;
    }
    return digits.substring(at);
  }

  static String stripTrailingZeros(String digits) {
    int end = digits.length();
    while (end > 0 && digits.charAt(end - 1) == '0') {
      end--;
    }
    return digits.substring(0, end);
  }
}
