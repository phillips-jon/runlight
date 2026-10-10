using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;

namespace Runlight;

/// <summary>
/// Dates in a site's timezone, without a date library. Ranges are computed here as epoch
/// milliseconds so the database only ever compares integers.
/// </summary>
/// <remarks>
/// A range is { from, to, fromDate, toDate, interval }: <c>from</c> inclusive, <c>to</c> exclusive,
/// and the first and last local dates covered, YYYY-MM-DD, both inclusive. A bucket is
/// { start, end }. The TypeScript reads local times through Intl.DateTimeFormat, which knows ICU's
/// zone names; here a name is matched against the IANA list without regard to case, and ICU's
/// own extra names (PST, SystemV/EST5EDT) are mapped to the zone they name.
/// </remarks>
public static class Time
{
    public static readonly string[] Periods = ["today", "yesterday", "7d", "30d", "90d", "month", "last_month", "year", "12mo", "all"];
    public static readonly string[] Intervals = ["hour", "day", "week", "month"];
    public static readonly string[] CompareModes = ["previous", "year", "custom", "off"];

    private const int MaxBuckets = 1000;

    /// <summary>A month of hours. Longer hourly ranges are cut off rather than refused.</summary>
    private const int MaxHours = 744;

    /// <summary>Names Intl reads as another zone.</summary>
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.Ordinal)
    {
        // Old names the time zone database made links in 2024b, which Debian and Ubuntu still build as zones of
        // their own with other history (WET kept to UTC in 1970); ICU reads them as the links.
        ["cet"] = "Europe/Brussels",
        ["eet"] = "Europe/Athens",
        ["est"] = "America/Panama",
        ["hst"] = "Pacific/Honolulu",
        ["met"] = "Europe/Brussels",
        ["mst"] = "America/Phoenix",
        ["wet"] = "Europe/Lisbon",
        // ICU's three letter names, kept from early Java.
        ["act"] = "Australia/Darwin",
        ["aet"] = "Australia/Sydney",
        ["agt"] = "America/Argentina/Buenos_Aires",
        ["art"] = "Africa/Cairo",
        ["ast"] = "America/Anchorage",
        ["bet"] = "America/Sao_Paulo",
        ["bst"] = "Asia/Dhaka",
        ["cat"] = "Africa/Maputo",
        ["cnt"] = "America/St_Johns",
        ["cst"] = "America/Chicago",
        ["ctt"] = "Asia/Shanghai",
        ["eat"] = "Africa/Nairobi",
        ["ect"] = "Europe/Paris",
        ["iet"] = "America/Indiana/Indianapolis",
        ["ist"] = "Asia/Kolkata",
        ["jst"] = "Asia/Tokyo",
        ["mit"] = "Pacific/Apia",
        ["net"] = "Asia/Yerevan",
        ["nst"] = "Pacific/Auckland",
        ["plt"] = "Asia/Karachi",
        ["pnt"] = "America/Phoenix",
        ["prt"] = "America/Puerto_Rico",
        ["pst"] = "America/Los_Angeles",
        ["sst"] = "Pacific/Guadalcanal",
        ["vst"] = "Asia/Ho_Chi_Minh",
        // ICU's System V zones.
        ["systemv/ast4"] = "Etc/GMT+4",
        ["systemv/ast4adt"] = "America/Halifax",
        ["systemv/est5"] = "Etc/GMT+5",
        ["systemv/est5edt"] = "America/New_York",
        ["systemv/cst6"] = "Etc/GMT+6",
        ["systemv/cst6cdt"] = "America/Chicago",
        ["systemv/mst7"] = "Etc/GMT+7",
        ["systemv/mst7mdt"] = "America/Denver",
        ["systemv/pst8"] = "Etc/GMT+8",
        ["systemv/pst8pdt"] = "America/Los_Angeles",
        ["systemv/yst9"] = "Etc/GMT+9",
        ["systemv/yst9ydt"] = "America/Anchorage",
        ["systemv/hst10"] = "Etc/GMT+10",
        // Names the database dropped and ICU kept.
        ["canada/east-saskatchewan"] = "America/Regina",
        ["us/pacific-new"] = "America/Los_Angeles",
    };

    private static readonly Dictionary<string, string> Names = BuildNames();
    private static readonly ConcurrentDictionary<string, Tz?> Zones = new(StringComparer.Ordinal);

    private static Dictionary<string, string> BuildNames()
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string id in ZoneNames.All)
        {
            output[AsciiLower(id)] = id;
        }
        output.Remove("factory");
        return output;
    }

    private static string AsciiLower(string s) => Data.JsPattern.AsciiLower(s);

    /// <summary>The zone Intl.DateTimeFormat would use for a timeZone option, or null where it throws a RangeError.</summary>
    private static Tz? Zone(string timezone) => Zones.GetOrAdd(timezone, Open);

    private static Tz? Open(string timezone)
    {
        // An offset, as ECMA-402 takes one: a sign (a minus sign too), two digit hours, and optional minutes.
        var offset = FixedOffset(timezone);
        if (offset is TimeSpan span)
        {
            return Tz.Fixed((int)span.TotalSeconds);
        }
        foreach (char c in timezone)
        {
            if (c < 0x21 || c > 0x7e)
            {
                return null;
            }
        }
        string key = AsciiLower(timezone);
        if (Aliases.TryGetValue(key, out string? alias))
        {
            return System(alias);
        }
        return Names.TryGetValue(key, out string? name) ? System(name) : null;
    }

    private static Tz? System(string id) => Tz.Find(id);

    private static TimeSpan? FixedOffset(string name)
    {
        if (name.Length < 3)
        {
            return null;
        }
        char sign = name[0];
        if (sign != '+' && sign != '-' && sign != (char)0x2212)
        {
            return null;
        }
        string rest = name[1..];
        string hh;
        string mm;
        if (rest.Length == 2)
        {
            hh = rest;
            mm = "00";
        }
        else if (rest.Length == 4)
        {
            hh = rest[..2];
            mm = rest[2..];
        }
        else if (rest.Length == 5 && rest[2] == ':')
        {
            hh = rest[..2];
            mm = rest[3..];
        }
        else
        {
            return null;
        }
        foreach (char c in hh + mm)
        {
            if (!char.IsAsciiDigit(c))
            {
                return null;
            }
        }
        int h = int.Parse(hh, NumberStyles.None, CultureInfo.InvariantCulture);
        int m = int.Parse(mm, NumberStyles.None, CultureInfo.InvariantCulture);
        if (h > 23 || m > 59)
        {
            return null;
        }
        var value = new TimeSpan(h, m, 0);
        return sign == '+' ? value : -value;
    }

    public static bool IsTimezone(string value) => Zone(value) != null;

    /// <summary>Year, month, day, hour, minute, and second of an instant in a zone, as Intl formats them.</summary>
    private static (long Y, long Mo, long D, long H, long Mi, long S) Parts(long ts, string timezone)
    {
        var zone = Zone(timezone) ?? throw new ArgumentException("Invalid time zone specified: " + timezone);
        long seconds = FloorDiv(ts, 1000);
        long local = seconds + zone.Offset(seconds);
        long days = FloorDiv(local, 86_400);
        long rest = local - days * 86_400;
        var (y, m, d) = Civil(days * 86_400_000L);
        return (y, m, d, rest / 3600, rest % 3600 / 60, rest % 60);
    }

    /// <summary>Milliseconds the zone is ahead of UTC at an instant.</summary>
    private static long Offset(long ts, string timezone)
    {
        var (y, mo, d, h, mi, s) = Parts(ts, timezone);
        return Utc(y, mo - 1, d, h, mi, s) - (ts - (ts % 1000));
    }

    /// <summary>The instant a local date (and hour) begins in a zone.</summary>
    public static long StartOf(string date, string timezone, long hour = 0)
    {
        var (y, m, d) = Split(date);
        long guess = Utc(y, m - 1, d, hour);
        long first = guess - Offset(guess, timezone);
        long at = guess - Offset(first, timezone);
        // Where clocks jump forward at that time (midnight in Santiago, Havana, and the Azores), it
        // never happens, and the sum above lands before it; the day then begins when the clocks
        // land, at most a few quarter hours on.
        for (int i = 0; i < 8; i++)
        {
            var (ly, lm, ld, lh, _, _) = Parts(at, timezone);
            if (Utc(ly, lm - 1, ld, lh) >= guess)
            {
                break;
            }
            at += 15 * 60_000;
        }
        return at;
    }

    /// <summary>The local date of an instant, YYYY-MM-DD.</summary>
    public static string LocalDate(long ts, string timezone)
    {
        var (y, m, d, _, _, _) = Parts(ts, timezone);
        return Js.Pad(y, 4) + "-" + Js.Pad(m, 2) + "-" + Js.Pad(d, 2);
    }

    public static string AddDays(string date, long days)
    {
        var (y, m, d) = Split(date);
        return Iso(Utc(y, m - 1, d + days))[..10];
    }

    public static string AddMonths(string date, long months)
    {
        var (y, m, _) = Split(date);
        return Iso(Utc(y, m - 1 + months, 1))[..10];
    }

    public static bool IsDate(string value)
    {
        // Years from 1900 to 9998, so the day after any date is a date too.
        if (value.Length != 10 || value[4] != '-' || value[7] != '-')
        {
            return false;
        }
        for (int i = 0; i < 10; i++)
        {
            if (i != 4 && i != 7 && !char.IsAsciiDigit(value[i]))
            {
                return false;
            }
        }
        if (string.CompareOrdinal(value, "1900") < 0 || string.CompareOrdinal(value, "9999") >= 0)
        {
            return false;
        }
        // A month or day that does not exist (2026-13-01) makes no date at all, rather than a wrong one.
        var (y, m, d) = Split(value);
        return m >= 1 && m <= 12 && d >= 1 && d <= DateTime.DaysInMonth((int)y, (int)m);
    }

    private static long DaysBetween(string from, string to)
    {
        var (fy, fm, fd) = Split(from);
        var (ty, tm, td) = Split(to);
        return (Utc(ty, tm - 1, td) - Utc(fy, fm - 1, fd)) / 86_400_000;
    }

    private static string DefaultInterval(string fromDate, string toDate)
    {
        long days = DaysBetween(fromDate, toDate);
        if (days < 1)
        {
            return "hour";
        }
        return days <= 92 ? "day" : "month";
    }

    private static bool Blank(string? s) => string.IsNullOrEmpty(s);

    /// <summary>
    /// A named period or custom dates as a range in the site's timezone. <paramref name="firstDate"/>
    /// is the earliest local date with data, used by "all". Null for a period or dates it cannot read.
    /// </summary>
    public static JsObject? ResolveRange(string? period, string? from, string? to, string? interval, string timezone, long now, string? firstDate = null)
    {
        string today = LocalDate(now, timezone);
        string fromDate;
        string toDate;
        if (!Blank(from) || !Blank(to))
        {
            if (Blank(from) || Blank(to) || !IsDate(from!) || !IsDate(to!) || string.CompareOrdinal(from, to) > 0)
            {
                return null;
            }
            fromDate = from!;
            toDate = to!;
        }
        else
        {
            string monthStart = today[..8] + "01";
            switch (period ?? "30d")
            {
                case "today":
                    fromDate = toDate = today;
                    break;
                case "yesterday":
                    fromDate = toDate = AddDays(today, -1);
                    break;
                case "7d":
                    fromDate = AddDays(today, -6);
                    toDate = today;
                    break;
                case "30d":
                    fromDate = AddDays(today, -29);
                    toDate = today;
                    break;
                case "90d":
                    fromDate = AddDays(today, -89);
                    toDate = today;
                    break;
                case "month":
                    fromDate = monthStart;
                    toDate = today;
                    break;
                case "last_month":
                    fromDate = AddMonths(today, -1);
                    toDate = AddDays(monthStart, -1);
                    break;
                case "year":
                    fromDate = today[..4] + "-01-01";
                    toDate = today;
                    break;
                case "12mo":
                    fromDate = AddMonths(today, -11);
                    toDate = today;
                    break;
                case "all":
                    fromDate = !Blank(firstDate) && string.CompareOrdinal(firstDate, today) < 0 ? firstDate! : today;
                    toDate = today;
                    break;
                default:
                    return null;
            }
        }
        string chosen = interval != null && Array.IndexOf(Intervals, interval) >= 0 ? interval : DefaultInterval(fromDate, toDate);
        return Range(fromDate, toDate, chosen, timezone);
    }

    private static JsObject Range(string fromDate, string toDate, string interval, string timezone) => new()
    {
        ["from"] = StartOf(fromDate, timezone),
        ["to"] = StartOf(AddDays(toDate, 1), timezone),
        ["fromDate"] = fromDate,
        ["toDate"] = toDate,
        ["interval"] = interval,
    };

    private static string AddYears(string date, long years)
    {
        var (y, m, d) = Split(date);
        long shifted = Utc(y + years, m - 1, d);
        // Feb 29 in a year without one becomes Feb 28, not Mar 1.
        var (sy, sm, _) = Civil(shifted);
        if (sm != m)
        {
            // setUTCDate(0): the last day of the month before.
            shifted = Utc(sy, sm - 1, 0);
        }
        return Iso(shifted)[..10];
    }

    /// <summary>
    /// The range a period is compared with: the same number of days just before it, the same dates
    /// a year earlier, or custom dates. Null for "off" or bad custom dates.
    /// </summary>
    public static JsObject? CompareRange(JsObject range, string mode, string timezone, string? customFrom = null, string? customTo = null)
    {
        if (mode == "off")
        {
            return null;
        }
        string fromDate;
        string toDate;
        string rangeFrom = range.Str("fromDate")!;
        string rangeTo = range.Str("toDate")!;
        if (mode == "year")
        {
            fromDate = AddYears(rangeFrom, -1);
            toDate = AddYears(rangeTo, -1);
        }
        else if (mode == "custom")
        {
            if (Blank(customFrom) || Blank(customTo) || !IsDate(customFrom!) || !IsDate(customTo!) || string.CompareOrdinal(customFrom, customTo) > 0)
            {
                return null;
            }
            fromDate = customFrom!;
            toDate = customTo!;
        }
        else
        {
            long days = DaysBetween(rangeFrom, rangeTo) + 1;
            fromDate = AddDays(rangeFrom, -days);
            toDate = AddDays(rangeFrom, -1);
        }
        return Range(fromDate, toDate, range.Str("interval")!, timezone);
    }

    /// <summary>Chart buckets covering a range, each starting on a local boundary: { start, end }.</summary>
    public static List<JsObject> Buckets(JsObject range, string timezone)
    {
        var starts = new List<long>();
        long from = range.Long("from");
        long to = range.Long("to");
        string interval = range.Str("interval")!;
        if (interval == "hour")
        {
            for (long t = from; t < to && starts.Count < MaxHours; t += 3_600_000)
            {
                starts.Add(t);
            }
        }
        else
        {
            string date = range.Str("fromDate")!;
            string toDate = range.Str("toDate")!;
            if (interval == "week")
            {
                date = AddDays(date, -Weekday(date));
            }
            else if (interval == "month")
            {
                date = date[..8] + "01";
            }
            while (string.CompareOrdinal(date, toDate) <= 0 && starts.Count < MaxBuckets)
            {
                starts.Add(StartOf(date, timezone));
                date = interval switch
                {
                    "day" => AddDays(date, 1),
                    "week" => AddDays(date, 7),
                    _ => AddMonths(date, 1),
                };
            }
        }
        var output = new List<JsObject>(starts.Count);
        for (int i = 0; i < starts.Count; i++)
        {
            long next = i + 1 < starts.Count ? starts[i + 1] : to;
            output.Add(new JsObject { ["start"] = Math.Max(starts[i], from), ["end"] = Math.Min(next, to) });
        }
        return output;
    }

    /// <summary>The weekday (Monday is 0) and hour of an instant in a zone.</summary>
    public static (long Weekday, long Hour) LocalWeekdayHour(long ts, string timezone)
    {
        var (y, m, d, h, _, _) = Parts(ts, timezone);
        return (Weekday(Js.Pad(y, 4) + "-" + Js.Pad(m, 2) + "-" + Js.Pad(d, 2)), h);
    }

    /// <summary>Monday is 0.</summary>
    private static long Weekday(string date)
    {
        var (y, m, d) = Split(date);
        long days = Utc(y, m - 1, d) / 86_400_000;
        // 1970-01-01 was a Thursday.
        return Mod(days + 3, 7);
    }

    private static (long, long, long) Split(string date)
    {
        string[] parts = date.Split('-');
        return (Int(parts, 0), Int(parts, 1), Int(parts, 2));
    }

    private static long Int(string[] parts, int i)
    {
        if (i >= parts.Length)
        {
            return 0;
        }
        // intval: leading digits, else 0.
        string p = parts[i];
        int n = 0;
        while (n < p.Length && char.IsAsciiDigit(p[n]))
        {
            n++;
        }
        return n == 0 ? 0 : long.Parse(p.AsSpan(0, Math.Min(n, 18)), NumberStyles.None, CultureInfo.InvariantCulture);
    }

    private static long Mod(long a, long b) => ((a % b) + b) % b;

    private static long FloorDiv(long a, long b) => (a - Mod(a, b)) / b;

    /// <summary>Date.UTC: months and days past their ends roll over, and a year from 0 to 99 means 1900 to 1999.</summary>
    public static long Utc(long year, long month, long day, long hour = 0, long minute = 0, long second = 0)
    {
        if (year >= 0 && year <= 99)
        {
            year += 1900;
        }
        year += (month - Mod(month, 12)) / 12;
        month = Mod(month, 12) + 1;
        long days = DaysFromCivil(year, month, 1) + day - 1;
        return days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000;
    }

    /// <summary>Days from 1970-01-01 to a proleptic Gregorian date.</summary>
    private static long DaysFromCivil(long y, long m, long d)
    {
        y -= m <= 2 ? 1 : 0;
        long era = (y >= 0 ? y : y - 399) / 400;
        long yoe = y - era * 400;
        long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
        long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// <summary>Year, month, and day of an instant in UTC.</summary>
    private static (long, long, long) Civil(long ms)
    {
        long z = (ms - Mod(ms, 86_400_000)) / 86_400_000 + 719468;
        long era = (z >= 0 ? z : z - 146096) / 146097;
        long doe = z - era * 146097;
        long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        long d = doy - (153 * mp + 2) / 5 + 1;
        long m = mp < 10 ? mp + 3 : mp - 9;
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d);
    }

    /// <summary>The date part of Date.prototype.toISOString, with its six digit form outside years 0 to 9999.</summary>
    private static string Iso(long ms)
    {
        var (y, m, d) = Civil(ms);
        string year = y >= 0 && y <= 9999 ? Js.Pad(y, 4) : (y < 0 ? "-" : "+") + Js.Pad(Math.Abs(y), 6);
        return year + "-" + Js.Pad(m, 2) + "-" + Js.Pad(d, 2);
    }
}
