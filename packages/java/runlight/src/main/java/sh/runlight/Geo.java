package sh.runlight;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import sh.runlight.http.Headers;

/**
 * Where a visitor is, from a hosting platform's headers or a database lookup.
 *
 * <p>A location is an object with country (ISO 3166-1 alpha-2 in upper case), region (ISO 3166-2
 * such as "US-CA"), and city. A lookup gives any of those keys, such as one made by {@link
 * #fileLookup} from an MMDB file.
 *
 * <p>Where the TypeScript would throw a TypeError on a value of the wrong type (a number for a
 * city), this throws one too, and the callers catch it where the TypeScript does.
 */
public final class Geo {
  private Geo() {}

  /** Looks a client IP up in a database of the app's choosing, such as an MMDB file. */
  @FunctionalInterface
  public interface Lookup {
    /** Any of country, region, and city, or null when the address is unknown. */
    Map<String, Object> lookup(String ip) throws Exception;
  }

  private static Map<String, Object> empty() {
    return Json.object("country", "", "region", "", "city", "");
  }

  private static String decode(String value) {
    if (value == null || value.isEmpty()) {
      return "";
    }
    String decoded = Js.decodeURIComponent(value);
    return Js.trim(decoded != null ? decoded : value);
  }

  private static final Pattern COUNTRY = Pattern.compile("^[A-Z]{2}\\z");
  private static final Pattern CODE = Pattern.compile("^([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}\\z");
  private static final Pattern PREFIXED = Pattern.compile("^[A-Z]{2}-");

  private static Map<String, Object> clean(Map<String, ?> location) {
    String country = Js.slice(Js.upper(text(location.get("country"))), 0, 2);
    if (!COUNTRY.matcher(country).matches() || country.equals("XX") || country.equals("T1")) {
      country = "";
    }
    // A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
    // that has no codes ("California") is kept readable, as "US-California".
    String raw = Js.trim(text(location.get("region")));
    String region = CODE.matcher(raw).matches() ? Js.upper(raw) : Js.slice(raw, 0, 80);
    if (!region.isEmpty() && !PREFIXED.matcher(region).find() && !country.isEmpty()) {
      region = country + "-" + region;
    }
    if (country.isEmpty()) {
      region = "";
    }
    String city = !country.isEmpty() ? Js.slice(text(location.get("city")), 0, 100) : "";
    return Json.object("country", country, "region", region, "city", city);
  }

  /**
   * A string, or "" for null, as {@code value ?? ""} gives; anything else has no string methods.
   */
  private static String text(Object value) {
    if (value == null || value == Json.UNDEFINED) {
      return "";
    }
    if (!(value instanceof String s)) {
      throw new ClassCastException("Not a string");
    }
    return s;
  }

  /** Location from the headers a hosting platform adds, if any. */
  public static Map<String, Object> locationFromHeaders(Headers headers) {
    String vercel = headers.get("x-vercel-ip-country");
    if (vercel != null && !vercel.isEmpty()) {
      return clean(
          Json.object(
              "country", vercel,
              "region", decode(headers.get("x-vercel-ip-country-region")),
              "city", decode(headers.get("x-vercel-ip-city"))));
    }
    String cloudflare = headers.get("cf-ipcountry");
    if (cloudflare != null && !cloudflare.isEmpty()) {
      return clean(
          Json.object(
              "country", cloudflare,
              "region", decode(headers.get("cf-region-code")),
              "city", decode(headers.get("cf-ipcity"))));
    }
    String netlify = headers.get("x-nf-geo");
    if (netlify != null && !netlify.isEmpty()) {
      try {
        Object geo = Json.parse(atob(netlify));
        if (geo == null) {
          // Reading a field of null is a TypeError.
          return null;
        }
        return clean(
            Json.object(
                "country", field(field(geo, "country"), "code"),
                "region", field(field(geo, "subdivision"), "code"),
                "city", field(geo, "city")));
      } catch (RuntimeException e) {
        return null;
      }
    }
    return null;
  }

  /** {@code value?.key}: a field of a JSON object, or null (undefined) for anything else. */
  private static Object field(Object value, String key) {
    return value instanceof Map<?, ?> map && map.containsKey(key) ? map.get(key) : null;
  }

  private static final Pattern ATOB_SPACE = Pattern.compile("[\\t\\n\\f\\r ]");
  private static final Pattern ATOB_PAD = Pattern.compile("={1,2}\\z");
  private static final Pattern ATOB_BAD = Pattern.compile("[^A-Za-z0-9+/]");

  /** atob(): forgiving base64 to a binary string, each byte one character. */
  public static String atob(String text) {
    text = ATOB_SPACE.matcher(text).replaceAll("");
    if (text.length() % 4 == 0) {
      text = ATOB_PAD.matcher(text).replaceFirst("");
    }
    if (text.length() % 4 == 1 || ATOB_BAD.matcher(text).find()) {
      throw new IllegalArgumentException("The string to be decoded is not correctly encoded.");
    }
    int padded = (text.length() + 3) / 4 * 4;
    StringBuilder full = new StringBuilder(text);
    while (full.length() < padded) {
      full.append('=');
    }
    byte[] bytes;
    try {
      bytes = Base64.getDecoder().decode(full.toString());
    } catch (IllegalArgumentException e) {
      // A last character with bits past the data, which atob ignores and Java refuses.
      bytes = Base64.getMimeDecoder().decode(full.toString());
    }
    return new String(bytes, StandardCharsets.ISO_8859_1);
  }

  /** Where a request comes from: platform headers first, then the lookup. */
  public static Map<String, Object> locate(Headers headers, String ip, Lookup lookup) {
    Map<String, Object> fromHeaders = locationFromHeaders(headers);
    if (fromHeaders != null && !"".equals(fromHeaders.get("country"))) {
      return fromHeaders;
    }
    if (lookup != null && !ip.isEmpty()) {
      try {
        Map<String, Object> found = lookup.lookup(ip);
        if (found != null) {
          return clean(found);
        }
      } catch (Exception e) {
        // A broken lookup must never lose the event.
      }
    }
    return empty();
  }

  /** Anything that answers records for addresses, as {@link Mmdb} does. */
  @FunctionalInterface
  public interface Reader {
    Object get(String ip) throws Exception;
  }

  /**
   * A lookup answering from an MMDB reader. DB-IP's records follow MaxMind's city layout, with
   * names but no subdivision codes; a city loses the district DB-IP adds in brackets, as in
   * "Toronto (Old Toronto)". This is the TypeScript server's lookupFrom.
   */
  public static Lookup lookupFrom(Reader reader) {
    return ip -> {
      Object found;
      try {
        found = reader.get(ip);
      } catch (Exception e) {
        return null;
      }
      Object country = at(found, "country", "iso_code");
      if (!Js.truthy(country)) {
        return null;
      }
      Object sub = at(found, "subdivisions", 0);
      Object city = at(found, "city", "names", "en");
      if (city == null) {
        city = "";
      }
      Object region = at(sub, "iso_code");
      if (region == null) {
        region = at(sub, "names", "en");
      }
      return Json.object(
          "country", country,
          "region", region == null ? "" : region,
          "city", city instanceof String s ? cityName(s) : city);
    };
  }

  /** A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City. */
  public static Lookup fileLookup(Path file) {
    Mmdb reader = Mmdb.open(file);
    return lookupFrom(reader::get);
  }

  private static final Pattern DISTRICT =
      Pattern.compile("[" + Js.SPACE + "]*\\([^)]*\\)[" + Js.SPACE + "]*\\z");

  /** A city as people say it, without a trailing bracketed district. */
  public static String cityName(String name) {
    return Js.trim(DISTRICT.matcher(name).replaceFirst(""));
  }

  /** {@code value?.a?.b}, through maps and lists decoded from a database record. */
  private static Object at(Object value, Object... path) {
    for (Object key : path) {
      if (key instanceof Integer index) {
        List<Object> list = Js.list(value);
        if (list == null || index >= list.size()) {
          return null;
        }
        value = list.get(index);
      } else {
        Map<String, Object> map = Js.map(value);
        if (map == null || !map.containsKey(key)) {
          return null;
        }
        value = map.get(key);
      }
    }
    return value;
  }
}
