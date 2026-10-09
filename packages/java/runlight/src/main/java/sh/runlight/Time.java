package sh.runlight;

import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Dates in a site's timezone. Ranges are computed here as epoch milliseconds so the database only
 * ever compares integers.
 *
 * <p>A range is an object with from (inclusive), to (exclusive), and fromDate and toDate (the first
 * and last local dates covered, YYYY-MM-DD, both inclusive), and interval. A bucket is an object
 * with start and end.
 *
 * <p>The TypeScript reads local times through Intl.DateTimeFormat, which knows ICU's zone names.
 * java.time knows nearly the same ones, and the differences are settled here: a name is matched
 * without regard to case, the few that java.time does not know or reads as abbreviations go to the
 * zone they name in the time zone database, ICU's own extra names (PST, SystemV/EST5EDT) are added,
 * and "Factory", which ICU refuses, is refused.
 */
public final class Time {
  private Time() {}

  public static final List<String> PERIODS =
      List.of(
          "today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all");
  public static final List<String> INTERVALS = List.of("hour", "day", "week", "month");
  public static final List<String> COMPARE_MODES = List.of("previous", "year", "custom", "off");

  private static final int MAX_BUCKETS = 1000;

  /** A month of hours. Longer hourly ranges are cut off rather than refused. */
  private static final int MAX_HOURS = 744;

  /** Names Intl reads as another zone where java.time has no name, or reads it otherwise. */
  private static final Map<String, String> ALIASES = new HashMap<>();

  static {
    String[] pairs = {
      "cet",
      "Europe/Brussels",
      "eet",
      "Europe/Athens",
      "est",
      "America/Panama",
      "gmt",
      "UTC",
      "gmt+0",
      "UTC",
      "gmt-0",
      "UTC",
      "hst",
      "Pacific/Honolulu",
      "met",
      "Europe/Brussels",
      "mst",
      "America/Phoenix",
      "uct",
      "UTC",
      "wet",
      "Europe/Lisbon",
      // ICU's three letter names, kept from early Java.
      "act",
      "Australia/Darwin",
      "aet",
      "Australia/Sydney",
      "agt",
      "America/Argentina/Buenos_Aires",
      "art",
      "Africa/Cairo",
      "ast",
      "America/Anchorage",
      "bet",
      "America/Sao_Paulo",
      "bst",
      "Asia/Dhaka",
      "cat",
      "Africa/Maputo",
      "cnt",
      "America/St_Johns",
      "cst",
      "America/Chicago",
      "ctt",
      "Asia/Shanghai",
      "eat",
      "Africa/Nairobi",
      "ect",
      "Europe/Paris",
      "iet",
      "America/Indiana/Indianapolis",
      "ist",
      "Asia/Kolkata",
      "jst",
      "Asia/Tokyo",
      "mit",
      "Pacific/Apia",
      "net",
      "Asia/Yerevan",
      "nst",
      "Pacific/Auckland",
      "plt",
      "Asia/Karachi",
      "pnt",
      "America/Phoenix",
      "prt",
      "America/Puerto_Rico",
      "pst",
      "America/Los_Angeles",
      "sst",
      "Pacific/Guadalcanal",
      "vst",
      "Asia/Ho_Chi_Minh",
      // ICU's System V zones.
      "systemv/ast4",
      "Etc/GMT+4",
      "systemv/ast4adt",
      "America/Halifax",
      "systemv/est5",
      "Etc/GMT+5",
      "systemv/est5edt",
      "America/New_York",
      "systemv/cst6",
      "Etc/GMT+6",
      "systemv/cst6cdt",
      "America/Chicago",
      "systemv/mst7",
      "Etc/GMT+7",
      "systemv/mst7mdt",
      "America/Denver",
      "systemv/pst8",
      "Etc/GMT+8",
      "systemv/pst8pdt",
      "America/Los_Angeles",
      "systemv/yst9",
      "Etc/GMT+9",
      "systemv/yst9ydt",
      "America/Anchorage",
      "systemv/hst10",
      "Etc/GMT+10",
      // Names the database dropped and ICU kept.
      "canada/east-saskatchewan",
      "America/Regina",
      "us/pacific-new",
      "America/Los_Angeles",
      // A link java.time's database leaves out.
      "roc",
      "Asia/Taipei",
    };
    for (int i = 0; i < pairs.length; i += 2) {
      ALIASES.put(pairs[i], pairs[i + 1]);
    }
  }

  /** A zone from the database, or a fixed offset, which Intl takes up to 23:59 either way. */
  private record Zone(ZoneId id, long offsetMs) {}

  private static final Map<String, Optional<Zone>> ZONES = new ConcurrentHashMap<>();
  private static volatile Map<String, String> names;

  private static final Pattern OFFSET =
      Pattern.compile("^([+\\-]|−)([01][0-9]|2[0-3])(?::?([0-5][0-9]))?\\z");

  /** The zone Intl.DateTimeFormat would use for a timeZone option, or null where it throws. */
  private static Zone zone(String timezone) {
    return ZONES.computeIfAbsent(timezone, key -> Optional.ofNullable(open(key))).orElse(null);
  }

  private static Zone open(String timezone) {
    // An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional
    // minutes.
    Matcher m = OFFSET.matcher(timezone);
    if (m.matches()) {
      int hours = Integer.parseInt(m.group(2));
      int minutes = m.group(3) == null ? 0 : Integer.parseInt(m.group(3));
      int sign = m.group(1).equals("+") ? 1 : -1;
      return new Zone(null, sign * (hours * 3_600_000L + minutes * 60_000L));
    }
    for (int i = 0; i < timezone.length(); i++) {
      char c = timezone.charAt(i);
      if (c < 0x21 || c > 0x7e) {
        return null;
      }
    }
    String key = timezone.toLowerCase(Locale.ROOT);
    String alias = ALIASES.get(key);
    if (alias != null) {
      return new Zone(ZoneId.of(alias), 0);
    }
    Map<String, String> known = names;
    if (known == null) {
      known = new HashMap<>();
      for (String name : ZoneId.getAvailableZoneIds()) {
        known.put(name.toLowerCase(Locale.ROOT), name);
      }
      known.remove("factory");
      names = known;
    }
    String name = known.get(key);
    return name == null ? null : new Zone(ZoneId.of(name), 0);
  }

  public static boolean isTimezone(String value) {
    return zone(value) != null;
  }

  /** Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them. */
  private static int[] parts(long ts, String timezone) {
    Zone zone = zone(timezone);
    if (zone == null) {
      throw new IllegalArgumentException("Invalid time zone specified: " + timezone);
    }
    if (zone.id() == null) {
      long local = Math.floorDiv(ts, 1000) * 1000 + zone.offsetMs();
      int[] date = civil(local);
      long within = Math.floorMod(local, 86_400_000L);
      return new int[] {
        date[0],
        date[1],
        date[2],
        (int) (within / 3_600_000),
        (int) (within / 60_000 % 60),
        (int) (within / 1000 % 60)
      };
    }
    ZonedDateTime local = Instant.ofEpochSecond(Math.floorDiv(ts, 1000)).atZone(zone.id());
    return new int[] {
      local.getYear(),
      local.getMonthValue(),
      local.getDayOfMonth(),
      local.getHour(),
      local.getMinute(),
      local.getSecond()
    };
  }

  /** Milliseconds the zone is ahead of UTC at an instant. */
  private static long offset(long ts, String timezone) {
    int[] p = parts(ts, timezone);
    return utc(p[0], p[1] - 1, p[2], p[3], p[4], p[5]) - (ts - ts % 1000);
  }

  public static long startOf(String date, String timezone) {
    return startOf(date, timezone, 0);
  }

  /** The instant a local date (and hour) begins in a zone. */
  public static long startOf(String date, String timezone, int hour) {
    int[] ymd = split(date);
    long guess = utc(ymd[0], ymd[1] - 1, ymd[2], hour, 0, 0);
    long first = guess - offset(guess, timezone);
    long at = guess - offset(first, timezone);
    // Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it
    // never happens, and the sum above lands before it; the day then begins when the clocks land,
    // at most a few quarter hours on.
    for (int i = 0; i < 8; i++) {
      int[] p = parts(at, timezone);
      if (utc(p[0], p[1] - 1, p[2], p[3], 0, 0) >= guess) {
        break;
      }
      at += 15 * 60_000;
    }
    return at;
  }

  /** The local date of an instant, YYYY-MM-DD. */
  public static String localDate(long ts, String timezone) {
    int[] p = parts(ts, timezone);
    return String.format("%04d-%02d-%02d", p[0], p[1], p[2]);
  }

  public static String addDays(String date, long days) {
    int[] ymd = split(date);
    return Js.slice(iso(utc(ymd[0], ymd[1] - 1, ymd[2] + days, 0, 0, 0)), 0, 10);
  }

  public static String addMonths(String date, long months) {
    int[] ymd = split(date);
    return Js.slice(iso(utc(ymd[0], ymd[1] - 1 + months, 1, 0, 0, 0)), 0, 10);
  }

  private static final Pattern DATE = Pattern.compile("^\\d{4}-\\d{2}-\\d{2}\\z");

  public static boolean isDate(String value) {
    // Years from 1900 to 9998, so the day after any date is a date too.
    if (value == null
        || !DATE.matcher(value).matches()
        || value.compareTo("1900") < 0
        || value.compareTo("9999") >= 0) {
      return false;
    }
    // A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong
    // one.
    int[] ymd = split(value);
    if (ymd[1] < 1 || ymd[1] > 12 || ymd[2] < 1) {
      return false;
    }
    return ymd[2] <= java.time.YearMonth.of(ymd[0], ymd[1]).lengthOfMonth();
  }

  private static long daysBetween(String from, String to) {
    int[] f = split(from);
    int[] t = split(to);
    return Math.floorDiv(
        utc(t[0], t[1] - 1, t[2], 0, 0, 0) - utc(f[0], f[1] - 1, f[2], 0, 0, 0), 86_400_000L);
  }

  private static String defaultInterval(String fromDate, String toDate) {
    long days = daysBetween(fromDate, toDate);
    if (days < 1) {
      return "hour";
    }
    if (days <= 92) {
      return "day";
    }
    return "month";
  }

  private static boolean blank(Object value) {
    return value == null || value == Json.UNDEFINED || "".equals(value);
  }

  /**
   * A named period or custom dates as a range in the site's timezone. {@code firstDate} is the
   * earliest local date with data, used by "all".
   *
   * @param input an object with period, from, to, and interval, each a string or absent
   */
  public static Map<String, Object> resolveRange(
      Map<String, ?> input, String timezone, long now, String firstDate) {
    String today = localDate(now, timezone);
    Object from = input.get("from");
    Object to = input.get("to");
    String fromDate;
    String toDate;
    if (!blank(from) || !blank(to)) {
      if (blank(from)
          || blank(to)
          || !isDate((String) from)
          || !isDate((String) to)
          || ((String) from).compareTo((String) to) > 0) {
        return null;
      }
      fromDate = (String) from;
      toDate = (String) to;
    } else {
      String monthStart = today.substring(0, 8) + "01";
      Object period = input.get("period");
      String name = period instanceof String s ? s : "30d";
      switch (name) {
        case "today" -> {
          fromDate = today;
          toDate = today;
        }
        case "yesterday" -> {
          fromDate = addDays(today, -1);
          toDate = fromDate;
        }
        case "7d" -> {
          fromDate = addDays(today, -6);
          toDate = today;
        }
        case "30d" -> {
          fromDate = addDays(today, -29);
          toDate = today;
        }
        case "90d" -> {
          fromDate = addDays(today, -89);
          toDate = today;
        }
        case "month" -> {
          fromDate = monthStart;
          toDate = today;
        }
        case "last_month" -> {
          fromDate = addMonths(today, -1);
          toDate = addDays(monthStart, -1);
        }
        case "year" -> {
          fromDate = today.substring(0, 4) + "-01-01";
          toDate = today;
        }
        case "12mo" -> {
          fromDate = addMonths(today, -11);
          toDate = today;
        }
        case "all" -> {
          fromDate =
              firstDate != null && !firstDate.isEmpty() && firstDate.compareTo(today) < 0
                  ? firstDate
                  : today;
          toDate = today;
        }
        default -> {
          return null;
        }
      }
    }
    Object interval = input.get("interval");
    String chosen =
        interval instanceof String s && INTERVALS.contains(s)
            ? s
            : defaultInterval(fromDate, toDate);
    return range(fromDate, toDate, timezone, chosen);
  }

  private static Map<String, Object> range(
      String fromDate, String toDate, String timezone, Object interval) {
    return Json.object(
        "from", startOf(fromDate, timezone),
        "to", startOf(addDays(toDate, 1), timezone),
        "fromDate", fromDate,
        "toDate", toDate,
        "interval", interval);
  }

  private static String addYears(String date, int years) {
    int[] ymd = split(date);
    long shifted = utc(ymd[0] + years, ymd[1] - 1, ymd[2], 0, 0, 0);
    // Feb 29 in a year without one becomes Feb 28, not Mar 1.
    int[] civil = civil(shifted);
    if (civil[1] - 1 != ymd[1] - 1) {
      // setUTCDate(0): the last day of the month before.
      shifted = utc(civil[0], civil[1] - 1, 0, 0, 0, 0);
    }
    return Js.slice(iso(shifted), 0, 10);
  }

  public static Map<String, Object> compareRange(
      Map<String, Object> range, String mode, String timezone) {
    return compareRange(range, mode, timezone, Map.of());
  }

  /**
   * The range a period is compared with: the same number of days just before it, the same dates a
   * year earlier, or custom dates. Null for "off" or bad custom dates.
   */
  public static Map<String, Object> compareRange(
      Map<String, Object> range, String mode, String timezone, Map<String, ?> custom) {
    String fromDate;
    String toDate;
    if (mode.equals("off")) {
      return null;
    }
    if (mode.equals("year")) {
      fromDate = addYears((String) range.get("fromDate"), -1);
      toDate = addYears((String) range.get("toDate"), -1);
    } else if (mode.equals("custom")) {
      Object from = custom.get("from");
      Object to = custom.get("to");
      if (blank(from)
          || blank(to)
          || !isDate((String) from)
          || !isDate((String) to)
          || ((String) from).compareTo((String) to) > 0) {
        return null;
      }
      fromDate = (String) from;
      toDate = (String) to;
    } else {
      long days = daysBetween((String) range.get("fromDate"), (String) range.get("toDate")) + 1;
      fromDate = addDays((String) range.get("fromDate"), -days);
      toDate = addDays((String) range.get("fromDate"), -1);
    }
    return range(fromDate, toDate, timezone, range.get("interval"));
  }

  /** Chart buckets covering a range, each starting on a local boundary. */
  public static List<Map<String, Object>> buckets(Map<String, Object> range, String timezone) {
    List<Long> starts = new ArrayList<>();
    long from = Js.asLong(range.get("from"));
    long to = Js.asLong(range.get("to"));
    String interval = (String) range.get("interval");
    if (interval.equals("hour")) {
      for (long t = from; t < to && starts.size() < MAX_HOURS; t += 3_600_000) {
        starts.add(t);
      }
    } else {
      String date = (String) range.get("fromDate");
      String toDate = (String) range.get("toDate");
      if (interval.equals("week")) {
        date = addDays(date, -weekday(date));
      } else if (interval.equals("month")) {
        date = date.substring(0, 8) + "01";
      }
      while (date.compareTo(toDate) <= 0 && starts.size() < MAX_BUCKETS) {
        starts.add(startOf(date, timezone));
        date =
            switch (interval) {
              case "day" -> addDays(date, 1);
              case "week" -> addDays(date, 7);
              default -> addMonths(date, 1);
            };
      }
    }
    List<Map<String, Object>> out = new ArrayList<>(starts.size());
    for (int i = 0; i < starts.size(); i++) {
      long next = i + 1 < starts.size() ? starts.get(i + 1) : to;
      out.add(Json.object("start", Math.max(starts.get(i), from), "end", Math.min(next, to)));
    }
    return out;
  }

  /** Weekday (Monday is 0) and hour. */
  public static int[] localWeekdayHour(long ts, String timezone) {
    int[] p = parts(ts, timezone);
    return new int[] {weekday(String.format("%04d-%02d-%02d", p[0], p[1], p[2])), p[3]};
  }

  /** Monday is 0. */
  private static int weekday(String date) {
    int[] ymd = split(date);
    long days = Math.floorDiv(utc(ymd[0], ymd[1] - 1, ymd[2], 0, 0, 0), 86_400_000L);
    // 1970-01-01 was a Thursday.
    return (int) Math.floorMod(days + 3, 7L);
  }

  private static int[] split(String date) {
    String[] parts = date.split("-", -1);
    int[] out = new int[3];
    for (int i = 0; i < 3 && i < parts.length; i++) {
      out[i] = (int) Js.toNumber(parts[i]);
    }
    return out;
  }

  /**
   * Date.UTC: months and days past their ends roll over, and a year from 0 to 99 means 1900 to
   * 1999.
   */
  public static long utc(long year, long month, long day, long hour, long minute, long second) {
    if (year >= 0 && year <= 99) {
      year += 1900;
    }
    year += Math.floorDiv(month, 12L);
    month = Math.floorMod(month, 12L) + 1;
    long days = daysFromCivil(year, month, 1) + day - 1;
    return days * 86_400_000L + hour * 3_600_000L + minute * 60_000L + second * 1000L;
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

  /** Year, month, and day of an instant in UTC. */
  private static int[] civil(long ms) {
    long z = Math.floorDiv(ms, 86_400_000L) + 719468;
    long era = Math.floorDiv(z, 146097L);
    long doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long mp = (5 * doy + 2) / 153;
    long d = doy - (153 * mp + 2) / 5 + 1;
    long m = mp < 10 ? mp + 3 : mp - 9;
    return new int[] {(int) (yoe + era * 400 + (m <= 2 ? 1 : 0)), (int) m, (int) d};
  }

  /**
   * The date part of Date.prototype.toISOString, with its six digit form outside years 0 to 9999.
   */
  private static String iso(long ms) {
    int[] c = civil(ms);
    String year =
        c[0] >= 0 && c[0] <= 9999
            ? String.format("%04d", c[0])
            : (c[0] < 0 ? "-" : "+") + String.format("%06d", Math.abs(c[0]));
    return String.format("%s-%02d-%02d", year, c[1], c[2]);
  }

  /** Date.prototype.toISOString. */
  public static String isoString(long ms) {
    long day = Math.floorDiv(ms, 86_400_000L);
    long within = Math.floorMod(ms, 86_400_000L);
    String date = iso(day * 86_400_000L);
    return String.format(
        "%sT%02d:%02d:%02d.%03dZ",
        date, within / 3_600_000, within / 60_000 % 60, within / 1000 % 60, within % 1000);
  }
}
