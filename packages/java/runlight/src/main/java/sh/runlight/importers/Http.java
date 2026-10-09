package sh.runlight.importers;

import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.DoubleConsumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import sh.runlight.Js;
import sh.runlight.Json;
import sh.runlight.Time;
import sh.runlight.http.FetchError;
import sh.runlight.http.FetchInit;
import sh.runlight.http.Fetcher;
import sh.runlight.http.Headers;
import sh.runlight.http.Response;
import sh.runlight.http.Url;

/**
 * JSON over HTTPS with a timeout and a few retries on rate limits and server errors, plus the few
 * pieces of JavaScript the importers lean on (Date.parse, toISOString, optional fields). An
 * importer takes one, so tests can pass a fake Fetcher and a sleep that does not wait.
 */
public final class Http {
  private final Fetcher fetcher;
  private final DoubleConsumer sleep;

  /** An Http that waits for real between retries. */
  public Http(Fetcher fetcher) {
    this(fetcher, Http::sleep);
  }

  /**
   * @param sleep waits this many milliseconds
   */
  public Http(Fetcher fetcher, DoubleConsumer sleep) {
    this.fetcher = fetcher;
    this.sleep = sleep;
  }

  private static void sleep(double ms) {
    if (ms > 0) {
      try {
        Thread.sleep((long) ms);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
  }

  public void pause(double ms) {
    sleep.accept(ms);
  }

  /** A GET of JSON with these headers. */
  public Object getJson(String url, Map<String, String> headers) {
    return getJson(url, headers, null, null);
  }

  /**
   * Fetches JSON, parsed to maps and lists.
   *
   * @param method null for GET
   * @param body null for none
   */
  public Object getJson(String url, Map<String, String> headers, String method, String body) {
    for (int attempt = 1; ; attempt++) {
      Headers sent = Headers.of("accept", "application/json");
      for (Map.Entry<String, String> h : headers.entrySet()) {
        sent.set(h.getKey(), h.getValue());
      }
      FetchInit init = new FetchInit().headers(sent).timeoutMs(20_000);
      if (method != null) {
        init.method(method);
      }
      if (body != null) {
        init.body(body);
      }
      Response response;
      try {
        response = fetcher.fetch(url, init);
      } catch (FetchError e) {
        if (attempt < 3) {
          continue;
        }
        String host = new Url(url).host();
        throw new ImportError("Could not reach " + host, "unreachable", Json.object("host", host));
      }
      if (response.ok()) {
        return response.json();
      }
      int status = response.status();
      if (status == 401) {
        throw new HttpError("The key or sign-in was refused", 401, "import_refused");
      }
      if ((status == 429 || status >= 500) && attempt < 4) {
        String retry = response.headers().get("retry-after");
        // Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
        double wait = Js.toNumber(retry) * 1000;
        if (!(wait > 0)) {
          wait = 800.0 * attempt;
        }
        pause(Math.min(wait, 10_000));
        continue;
      }
      String host = new Url(url).host();
      throw new HttpError(
          host + " answered " + status,
          status,
          "import_status",
          Json.object("host", host, "status", Integer.toString(status)));
    }
  }

  /** `credentials[key]?.trim() ?? ""`: a credential, trimmed, or "" when it is missing. */
  public static String credential(Map<String, String> credentials, String key) {
    String value = credentials.get(key);
    return value == null ? "" : Js.trim(value);
  }

  /** `a ?? b`: b when a is null or missing. */
  public static Object coalesce(Object value, Object fallback) {
    return value == null || value == Json.UNDEFINED ? fallback : value;
  }

  /**
   * An object as JSON.stringify would keep it, and as a later `field ?? x` reads it: the fields
   * holding undefined left out.
   */
  public static Map<String, Object> defined(Map<String, Object> fields) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (Map.Entry<String, Object> e : fields.entrySet()) {
      if (e.getValue() != Json.UNDEFINED) {
        out.put(e.getKey(), e.getValue());
      }
    }
    return out;
  }

  private static final Pattern ISO =
      Pattern.compile(
          "^([+-]\\d{6}|\\d{4})(?:-(\\d{2})(?:-(\\d{2}))?)?(?:T(\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d{1,9}))?)?(Z|[+-]\\d{2}:\\d{2})?)?\\z",
          Pattern.CASE_INSENSITIVE);

  /** The forms V8's fallback parser takes that services send: a space for the T, +hhmm zones. */
  private static final Pattern LEGACY =
      Pattern.compile(
          "^(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[T ](\\d{1,2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d+))?)?)?["
              + Js.SPACE
              + "]*(Z|UTC|GMT|[+-]\\d{2}:?\\d{2})?\\z",
          Pattern.CASE_INSENSITIVE);

  private static final Pattern DIGIT = Pattern.compile("\\d");

  /**
   * Date.parse: milliseconds, or NaN for text that is not a date. The ISO forms are read as
   * JavaScript reads them (a date alone is UTC, a date and time without an offset is local time);
   * of the other forms, those services send are read as V8's fallback parser reads them.
   */
  public static double parseDate(Object value) {
    if (!(value instanceof String s)) {
      return Double.NaN;
    }
    String text = Js.trim(s);
    Matcher m = ISO.matcher(text);
    if (m.matches()) {
      long year = Long.parseLong(m.group(1).startsWith("+") ? m.group(1).substring(1) : m.group(1));
      int month = m.group(2) != null ? Integer.parseInt(m.group(2)) : 1;
      int day = m.group(3) != null ? Integer.parseInt(m.group(3)) : 1;
      boolean timed = m.group(4) != null;
      int hour = timed ? Integer.parseInt(m.group(4)) : 0;
      int minute = timed ? Integer.parseInt(m.group(5)) : 0;
      int second = m.group(6) != null ? Integer.parseInt(m.group(6)) : 0;
      int ms = m.group(7) != null ? Integer.parseInt((m.group(7) + "00").substring(0, 3)) : 0;
      if (m.group(1).equals("-000000")
          || month < 1
          || month > 12
          || day < 1
          || day > daysIn(year, month)
          || hour > 24
          || minute > 59
          || second > 59
          || (hour == 24 && (minute != 0 || second != 0 || ms != 0))) {
        return Double.NaN;
      }
      String zone = m.group(8) == null ? "" : m.group(8);
      long utc = utcMs(year, month, day, hour, minute, second, ms);
      if (zone.equalsIgnoreCase("Z") || (!timed && zone.isEmpty())) {
        return clip(utc);
      }
      if (!zone.isEmpty()) {
        return clip(utc - offsetMs(zone));
      }
      return clip(local(utc));
    }
    if (text.isEmpty() || !DIGIT.matcher(text).find()) {
      return Double.NaN;
    }
    Matcher legacy = LEGACY.matcher(text);
    if (legacy.matches()) {
      long year = Long.parseLong(legacy.group(1));
      int month = Integer.parseInt(legacy.group(2));
      int day = Integer.parseInt(legacy.group(3));
      boolean timed = legacy.group(4) != null;
      int hour = timed ? Integer.parseInt(legacy.group(4)) : 0;
      int minute = timed ? Integer.parseInt(legacy.group(5)) : 0;
      int second = legacy.group(6) != null ? Integer.parseInt(legacy.group(6)) : 0;
      int ms =
          legacy.group(7) != null ? Integer.parseInt((legacy.group(7) + "00").substring(0, 3)) : 0;
      if (month < 1
          || month > 12
          || day < 1
          || day > daysIn(year, month)
          || hour > 24
          || minute > 59
          || second > 59) {
        return Double.NaN;
      }
      long utc = utcMs(year, month, day, hour, minute, second, ms);
      String zone = legacy.group(8) == null ? "" : Js.upper(legacy.group(8));
      if (zone.isEmpty()) {
        return clip(local(utc));
      }
      if (zone.equals("Z") || zone.equals("UTC") || zone.equals("GMT")) {
        return clip(utc);
      }
      return clip(utc - offsetMs(zone));
    }
    try {
      return clip(
          ZonedDateTime.parse(text, DateTimeFormatter.RFC_1123_DATE_TIME)
              .toInstant()
              .toEpochMilli());
    } catch (DateTimeParseException e) {
      return Double.NaN;
    }
  }

  /**
   * `new Date(ms).toISOString()`; an IllegalArgumentException where JavaScript throws a RangeError.
   */
  public static String isoString(double ms) {
    if (Double.isNaN(ms) || Double.isInfinite(ms) || Math.abs(ms) > 8.64e15) {
      throw new IllegalArgumentException("Invalid time value");
    }
    // TimeClip truncates toward zero.
    return Time.isoString((long) ms);
  }

  /** TimeClip: past a hundred million days either way is no date. */
  private static double clip(long ms) {
    return Math.abs(ms) > 8_640_000_000_000_000L ? Double.NaN : ms;
  }

  /** "+hh:mm" or "+hhmm" as milliseconds east of UTC. */
  private static long offsetMs(String zone) {
    String digits = zone.substring(1).replace(":", "");
    long minutes =
        Long.parseLong(digits.substring(0, 2)) * 60 + Long.parseLong(digits.substring(2, 4));
    return (zone.charAt(0) == '-' ? -1 : 1) * minutes * 60_000;
  }

  /** A wall-clock time in the process's zone, as JavaScript reads a time without an offset. */
  private static long local(long wall) {
    ZoneId zone = ZoneId.systemDefault();
    long offset = zone.getRules().getOffset(Instant.ofEpochMilli(wall)).getTotalSeconds() * 1000L;
    return wall - offset;
  }

  private static long utcMs(
      long year, int month, int day, int hour, int minute, int second, int ms) {
    return daysFromCivil(year, month, day) * 86_400_000L
        + hour * 3_600_000L
        + minute * 60_000L
        + second * 1000L
        + ms;
  }

  /** Days from 1970-01-01 to a proleptic Gregorian date. */
  private static long daysFromCivil(long y, long m, long d) {
    y -= m <= 2 ? 1 : 0;
    long era = Math.floorDiv(y, 400L);
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
  }

  /** Days in a month of the proleptic Gregorian calendar. */
  private static int daysIn(long year, int month) {
    return switch (month) {
      case 2 -> (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28;
      case 4, 6, 9, 11 -> 30;
      default -> 31;
    };
  }
}
