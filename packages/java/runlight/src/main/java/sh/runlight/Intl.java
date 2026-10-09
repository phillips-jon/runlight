package sh.runlight;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The pieces of JavaScript's Intl the email reports use, for the dashboard's languages (en, de, es,
 * fr, and pt): Intl.NumberFormat for counts, percents, one decimal place, and money,
 * Intl.DateTimeFormat for a month and year or a short day, and Intl.DisplayNames for a region's
 * name. The JDK's own CLDR data is older than Node's and names some regions and currencies in other
 * words, so region names, currency symbols, and currency fraction digits come from intl.json, which
 * scripts/java-intl.mts writes from Node's own ICU.
 *
 * <p>Numbers round as ICU does, half away from zero on the number's shortest decimal form, so 2.05
 * to one place is 2.1, though the double just under it is what is stored.
 */
public final class Intl {
  private Intl() {}

  private static final Map<String, String> GROUP =
      Map.of("en", ",", "de", ".", "es", ".", "fr", " ", "pt", ".");
  private static final Map<String, String> DECIMAL =
      Map.of("en", ".", "de", ",", "es", ",", "fr", ",", "pt", ",");
  private static final Map<String, String> PERCENT =
      Map.of("en", "%", "de", " %", "es", " %", "fr", " %", "pt", "%");

  private static final Map<String, List<String>> MONTHS =
      Map.of(
          "en",
          List.of(
              "January",
              "February",
              "March",
              "April",
              "May",
              "June",
              "July",
              "August",
              "September",
              "October",
              "November",
              "December"),
          "de",
          List.of(
              "Januar",
              "Februar",
              "März",
              "April",
              "Mai",
              "Juni",
              "Juli",
              "August",
              "September",
              "Oktober",
              "November",
              "Dezember"),
          "es",
          List.of(
              "enero",
              "febrero",
              "marzo",
              "abril",
              "mayo",
              "junio",
              "julio",
              "agosto",
              "septiembre",
              "octubre",
              "noviembre",
              "diciembre"),
          "fr",
          List.of(
              "janvier",
              "février",
              "mars",
              "avril",
              "mai",
              "juin",
              "juillet",
              "août",
              "septembre",
              "octobre",
              "novembre",
              "décembre"),
          "pt",
          List.of(
              "janeiro",
              "fevereiro",
              "março",
              "abril",
              "maio",
              "junho",
              "julho",
              "agosto",
              "setembro",
              "outubro",
              "novembro",
              "dezembro"));

  private static final Map<String, List<String>> SHORT_MONTHS =
      Map.of(
          "en",
          List.of(
              "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"),
          "de",
          List.of(
              "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.",
              "Nov.", "Dez."),
          "es",
          List.of(
              "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"),
          "fr",
          List.of(
              "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.",
              "nov.", "déc."),
          "pt",
          List.of(
              "jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.",
              "nov.", "dez."));

  /**
   * { month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with
   * the year.
   */
  private static final Map<String, List<String>> DATE_PATTERNS =
      Map.of(
          "en", List.of("{M} {y}", "{m} {d}", "{m} {d}, {y}"),
          "de", List.of("{M} {y}", "{d}. {m}", "{d}. {m} {y}"),
          "es", List.of("{M} de {y}", "{d} {m}", "{d} {m} {y}"),
          "fr", List.of("{M} {y}", "{d} {m}", "{d} {m} {y}"),
          "pt", List.of("{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"));

  private static final Pattern CODE = Pattern.compile("^[A-Za-z]{3}\\z");
  private static final Pattern REGION = Pattern.compile("^([A-Z]{2}|[0-9]{3})\\z");

  private static volatile Map<String, Object> data;

  private static Map<String, Object> data() {
    Map<String, Object> found = data;
    if (found == null) {
      try (InputStream in = Intl.class.getResourceAsStream("intl.json")) {
        if (in == null) {
          throw new IllegalStateException(
              "Runlight: intl.json is missing; run scripts/java-intl.mts.");
        }
        found = Js.map(Json.parse(new String(in.readAllBytes(), StandardCharsets.UTF_8)));
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
      data = found;
    }
    return found;
  }

  private static Map<String, Object> section(String name, String lang) {
    return Js.map(Js.map(data().get(name)).get(lang));
  }

  private static String lang(String lang) {
    return GROUP.containsKey(lang) ? lang : "en";
  }

  /** new Intl.NumberFormat(lang).format(n). */
  public static String number(String lang, Number n) {
    return number(lang, n, 0, 3);
  }

  /** new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n). */
  public static String number(String lang, Number n, int minFraction, int maxFraction) {
    String code = lang(lang);
    double d = n.doubleValue();
    if (Double.isNaN(d)) {
      return "NaN";
    }
    if (Double.isInfinite(d)) {
      return (d < 0 ? "-" : "") + "∞";
    }
    Rounded r = rounded(n, minFraction, maxFraction);
    String whole = r.whole;
    // Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
    if (!(code.equals("es") && whole.length() < 5)) {
      whole = group(whole, GROUP.get(code));
    }
    return (r.negative ? "-" : "")
        + whole
        + (r.fraction.isEmpty() ? "" : DECIMAL.get(code) + r.fraction);
  }

  /** new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n). */
  public static String percent(String lang, Number n) {
    String code = lang(lang);
    if (!Js.isFinite(n)) {
      return number(code, n) + PERCENT.get(code);
    }
    return number(code, times100(n), 0, 0) + PERCENT.get(code);
  }

  /**
   * new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n),
   * or {@code `${n} ${currency}`} where Intl throws (a currency code that is not three letters).
   */
  public static String currency(String lang, Number n, String currency, int maxFraction) {
    String code = lang(lang);
    if (!CODE.matcher(currency).find()) {
      return Js.string(n) + " " + currency;
    }
    String upper = Js.upper(currency);
    String before;
    String after;
    if (section("currencies", code).get(upper) instanceof List<?> own) {
      before = (String) own.get(0);
      after = (String) own.get(1);
    } else {
      List<Object> unknown = Js.list(Js.map(data().get("unknown")).get(code));
      before = ((String) unknown.get(0)).replace("{c}", upper);
      after = ((String) unknown.get(1)).replace("{c}", upper);
    }
    Object digits = Js.map(data().get("digits")).get(upper);
    int minFraction = Math.min(digits == null ? 2 : (int) Js.asLong(digits), maxFraction);
    double d = n.doubleValue();
    String amount = number(code, Js.isFinite(n) ? abs(n) : n, minFraction, maxFraction);
    boolean negative = d < 0 || (d == 0 && 1 / d < 0);
    if (amount.startsWith("-")) {
      amount = amount.substring(1);
    }
    return (negative ? "-" : "") + before + amount + after;
  }

  /** A date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it. */
  public static String monthYear(String lang, String date) {
    return date(lang, date, 0);
  }

  /**
   * A date as { month: "short", day: "numeric" } writes it, with {@code year: "numeric"} too when
   * asked.
   */
  public static String shortDay(String lang, String date, boolean withYear) {
    return date(lang, date, withYear ? 2 : 1);
  }

  private static String date(String lang, String date, int pattern) {
    String code = lang(lang);
    String[] parts = date.split("-", -1);
    int y = Integer.parseInt(parts[0]);
    int m = Integer.parseInt(parts[1]);
    int d = Integer.parseInt(parts[2]);
    return DATE_PATTERNS
        .get(code)
        .get(pattern)
        .replace("{M}", MONTHS.get(code).get(m - 1))
        .replace("{m}", SHORT_MONTHS.get(code).get(m - 1))
        .replace("{d}", Integer.toString(d))
        .replace("{y}", Integer.toString(y));
  }

  /**
   * new Intl.DisplayNames(lang, { type: "region" }).of(code), or the code where that throws. Only
   * an upper case code is looked up; Intl gives any other back as it came.
   */
  public static String region(String lang, String code) {
    if (!REGION.matcher(code).find()) {
      return code;
    }
    return section("regions", lang(lang)).get(code) instanceof String name ? name : code;
  }

  private static Number abs(Number n) {
    if (n instanceof Long l) {
      return Math.abs(l);
    }
    return Math.abs(n.doubleValue());
  }

  private static String group(String digits, String separator) {
    StringBuilder out = new StringBuilder();
    int first = digits.length() % 3 == 0 ? 3 : digits.length() % 3;
    out.append(digits, 0, first);
    for (int i = first; i < digits.length(); i += 3) {
      out.append(separator).append(digits, i, i + 3);
    }
    return out.toString();
  }

  /**
   * n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not
   * 13.500000000000002.
   */
  private static Number times100(Number n) {
    if (n instanceof Long || n instanceof Integer) {
      return n.longValue() * 100;
    }
    Decimal dec = decimal(n.doubleValue());
    return Double.parseDouble((dec.negative ? "-" : "") + plain(dec.digits, dec.point + 2));
  }

  private record Rounded(boolean negative, String whole, String fraction) {}

  /**
   * The number's sign, whole digits, and fraction digits, rounded half away from zero to at most
   * {@code max} places and padded to at least {@code min}.
   */
  private static Rounded rounded(Number n, int min, int max) {
    if (n instanceof Long || n instanceof Integer) {
      long v = n.longValue();
      String whole = v < 0 ? Long.toString(v).substring(1) : Long.toString(v);
      return new Rounded(v < 0, whole, "0".repeat(min));
    }
    Decimal dec = decimal(n.doubleValue());
    String digits = dec.digits;
    // Digits as a whole number of units of 10^-max.
    int keep = dec.point + max;
    String units;
    if (keep < 0) {
      units = "0";
    } else if (digits.length() > keep) {
      units = keep == 0 ? "0" : digits.substring(0, keep);
      if (digits.charAt(keep) >= '5') {
        units = increment(units);
      }
    } else {
      units = digits + "0".repeat(keep - digits.length());
    }
    if (units.length() < max + 1) {
      units = "0".repeat(max + 1 - units.length()) + units;
    }
    String whole = Messages.stripLeadingZeros(units.substring(0, units.length() - max));
    String fraction =
        Messages.stripTrailingZeros(max > 0 ? units.substring(units.length() - max) : "");
    if (fraction.length() < min) {
      fraction = fraction + "0".repeat(min - fraction.length());
    }
    return new Rounded(dec.negative, whole.isEmpty() ? "0" : whole, fraction);
  }

  /** Decimal digits plus one. */
  static String increment(String digits) {
    char[] chars = digits.toCharArray();
    int i = chars.length - 1;
    while (i >= 0 && chars[i] == '9') {
      chars[i] = '0';
      i--;
    }
    if (i < 0) {
      return "1" + new String(chars);
    }
    chars[i]++;
    return new String(chars);
  }

  private record Decimal(boolean negative, String digits, int point) {}

  /**
   * The shortest decimal form of a double: its sign, its significant digits, and where the point
   * goes (the number of digits before it, which may be zero or negative).
   */
  private static Decimal decimal(double n) {
    boolean negative = n < 0 || (n == 0 && 1 / n < 0);
    // Double.toString gives the shortest digits that read back (JDK 19 and newer).
    BigDecimal value = new BigDecimal(Double.toString(Math.abs(n))).stripTrailingZeros();
    if (value.signum() == 0) {
      return new Decimal(negative, "0", 1);
    }
    String digits = value.unscaledValue().toString();
    return new Decimal(negative, digits, digits.length() - value.scale());
  }

  /** Digits with the point after {@code point} of them, written out in full. */
  private static String plain(String digits, int point) {
    if (point <= 0) {
      return "0." + "0".repeat(-point) + digits;
    }
    if (point >= digits.length()) {
      return digits + "0".repeat(point - digits.length());
    }
    return digits.substring(0, point) + "." + digits.substring(point);
  }
}
