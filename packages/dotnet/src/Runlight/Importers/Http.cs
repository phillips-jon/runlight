using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Importers;

/// <summary>
/// JSON over HTTPS with a timeout and a few retries on rate limits and server
/// errors, plus the few pieces of JavaScript the importers lean on (Date.parse,
/// toISOString, and fields that may be missing). An importer takes one, so tests
/// can pass a fake fetcher and a sleep that does not wait.
/// </summary>
public sealed partial class Http
{
    private static readonly Lazy<HttpClientFetcher> DefaultFetcher = new(() => new HttpClientFetcher());

    private readonly IFetcher _fetcher;
    private readonly Func<double, CancellationToken, Task> _sleep;

    /// <param name="fetcher">Where requests go; a shared <see cref="HttpClientFetcher"/> when null.</param>
    /// <param name="sleep">Waits this many milliseconds; Task.Delay when null.</param>
    public Http(IFetcher? fetcher = null, Func<double, CancellationToken, Task>? sleep = null)
    {
        _fetcher = fetcher ?? DefaultFetcher.Value;
        _sleep = sleep ?? ((ms, ct) => ms > 0 ? Task.Delay(TimeSpan.FromMilliseconds(ms), ct) : Task.CompletedTask);
    }

    /// <summary>Waits <paramref name="ms"/> milliseconds.</summary>
    public Task PauseAsync(double ms, CancellationToken cancellationToken = default) => _sleep(ms, cancellationToken);

    /// <summary>Fetches JSON, parsed as <see cref="Json.Parse"/> reads it.</summary>
    /// <param name="url">The address.</param>
    /// <param name="headers">Headers besides accept.</param>
    /// <param name="method">The method; GET when null.</param>
    /// <param name="body">The body, for a POST.</param>
    /// <param name="cancellationToken">Stops the request.</param>
    public async Task<object?> GetJsonAsync(string url, JsObject? headers = null, string? method = null, string? body = null, CancellationToken cancellationToken = default)
    {
        for (int attempt = 1; ; attempt++)
        {
            var h = new Headers();
            h.Set("accept", "application/json");
            foreach (var (k, v) in headers ?? [])
            {
                h.Set(k, Js.String(v));
            }
            var init = new FetchInit { Headers = h, TimeoutMs = 20_000 };
            if (method != null)
            {
                init.Method = method;
            }
            if (body != null)
            {
                init.BodyText = body;
            }
            Response response;
            try
            {
                response = await _fetcher.FetchAsync(url, init, cancellationToken).ConfigureAwait(false);
            }
            catch (FetchException)
            {
                if (attempt < 3)
                {
                    continue;
                }
                string host = new Url(url).Host;
                throw new ImportError("Could not reach " + host, "unreachable", new JsObject { ["host"] = host });
            }
            if (response.Ok)
            {
                string text = await response.TextAsync(cancellationToken).ConfigureAwait(false);
                return Json.Parse(text.Length > 0 && text[0] == (char)0xFEFF ? text[1..] : text);
            }
            if (response.Status == 401)
            {
                throw new HttpError("The key or sign-in was refused", 401, "import_refused");
            }
            if ((response.Status == 429 || response.Status >= 500) && attempt < 4)
            {
                // Retry-After in seconds; none, zero, negative, or not a number waits the default backoff.
                double wait = Js.Number(response.Headers.Get("retry-after")) * 1000;
                wait = double.IsNaN(wait) || wait <= 0 ? 800 * attempt : wait;
                await PauseAsync(Math.Min(wait, 10_000), cancellationToken).ConfigureAwait(false);
                continue;
            }
            string at = new Url(url).Host;
            string status = Js.Str(response.Status);
            throw new HttpError(at + " answered " + status, response.Status, "import_status", new JsObject { ["host"] = at, ["status"] = status });
        }
    }

    /// <summary><c>object?.key</c>: the field, or Undefined when the object or the field is missing. A null field stays null.</summary>
    public static object? Field(object? value, string key) => value is JsObject o ? o.Prop(key) : Undefined.Value;

    /// <summary><c>list?.[index]</c>: the item, or Undefined when the list or the item is missing.</summary>
    public static object? Field(object? value, int index) =>
        value is List<object?> list && index >= 0 && index < list.Count ? list[index] : Undefined.Value;

    /// <summary><c>a ?? b</c>: b when a is null or missing.</summary>
    public static object? Coalesce(object? value, object? fallback) => value is null or Undefined ? fallback : value;

    /// <summary>An object as JSON.stringify would keep it: the fields holding undefined left out.</summary>
    public static JsObject Defined(JsObject fields)
    {
        var o = new JsObject();
        foreach (var (k, v) in fields)
        {
            if (v is not Undefined)
            {
                o[k] = v;
            }
        }
        return o;
    }

    [GeneratedRegex("^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?(?:[Tt]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]{1,9}))?)?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?\\z", RegexOptions.CultureInvariant)]
    private static partial Regex IsoDate();

    [GeneratedRegex("^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]+))?)? ?([Zz]|GMT|UTC|[+-][0-9]{2}:?[0-9]{2})?\\z", RegexOptions.CultureInvariant)]
    private static partial Regex LegacyDate();

    private const double MaxTime = 8.64e15;

    /// <summary>
    /// Date.parse: milliseconds, or NaN for text that is not a date. The ISO forms are read as
    /// JavaScript reads them (a date alone is UTC, a date and time without an offset is local time);
    /// a date and time with a space, or an offset without its colon, as V8's fallback parser reads
    /// them; other forms go to .NET's parser, which takes what V8 takes in the formats services send.
    /// </summary>
    public static double ParseDate(object? value)
    {
        if (value is not string raw)
        {
            return double.NaN;
        }
        string text = Js.Trim(raw);
        var m = IsoDate().Match(text);
        if (m.Success)
        {
            long year = long.Parse(m.Groups[1].Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            int month = m.Groups[2].Success ? Int(m.Groups[2]) : 1;
            int day = m.Groups[3].Success ? Int(m.Groups[3]) : 1;
            bool timed = m.Groups[4].Success;
            int hour = timed ? Int(m.Groups[4]) : 0;
            int minute = timed ? Int(m.Groups[5]) : 0;
            int second = m.Groups[6].Success ? Int(m.Groups[6]) : 0;
            int ms = m.Groups[7].Success ? int.Parse(m.Groups[7].Value.PadRight(3, '0')[..3], CultureInfo.InvariantCulture) : 0;
            if (m.Groups[1].Value == "-000000" || month < 1 || month > 12 || day < 1 || day > DaysIn(year, month) || hour > 24 || minute > 59 || second > 59 || (hour == 24 && (minute > 0 || second > 0 || ms > 0)))
            {
                return double.NaN;
            }
            string zone = m.Groups[8].Value;
            double utc = UtcMs(year, month, day, hour, minute, second, ms);
            if (zone is "Z" or "z" || (!timed && zone.Length == 0))
            {
                return Clip(utc);
            }
            if (zone.Length > 0)
            {
                return Clip(utc - (Offset(zone) * 60_000.0));
            }
            return Clip(utc - LocalOffsetMs(utc));
        }
        var legacy = LegacyDate().Match(text);
        if (legacy.Success)
        {
            int month = Int(legacy.Groups[2]);
            int day = Int(legacy.Groups[3]);
            long year = Int(legacy.Groups[1]);
            int hour = Int(legacy.Groups[4]);
            int minute = Int(legacy.Groups[5]);
            int second = legacy.Groups[6].Success ? Int(legacy.Groups[6]) : 0;
            int ms = legacy.Groups[7].Success ? int.Parse(legacy.Groups[7].Value.PadRight(3, '0')[..3], CultureInfo.InvariantCulture) : 0;
            if (month < 1 || month > 12 || day < 1 || day > DaysIn(year, month) || hour > 24 || minute > 59 || second > 59)
            {
                return double.NaN;
            }
            string zone = legacy.Groups[8].Value;
            double utc = UtcMs(year, month, day, hour, minute, second, ms);
            if (zone.Length == 0)
            {
                return Clip(utc - LocalOffsetMs(utc));
            }
            return Clip(zone is "Z" or "z" or "GMT" or "UTC" ? utc : utc - (Offset(zone) * 60_000.0));
        }
        bool digit = false;
        foreach (char c in text)
        {
            digit |= c is >= '0' and <= '9';
        }
        if (!digit)
        {
            return double.NaN;
        }
        if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal, out var parsed))
        {
            return parsed.ToUnixTimeMilliseconds();
        }
        return double.NaN;
    }

    private static int Int(Group g) => int.Parse(g.Value, CultureInfo.InvariantCulture);

    /// <summary>An offset such as +02:00 or -0130, in minutes.</summary>
    private static int Offset(string zone)
    {
        string digits = zone[1..].Replace(":", "", StringComparison.Ordinal);
        int minutes = (int.Parse(digits[..2], CultureInfo.InvariantCulture) * 60) + int.Parse(digits[2..4], CultureInfo.InvariantCulture);
        return zone[0] == '-' ? -minutes : minutes;
    }

    /// <summary>The process's zone offset at an instant, as JavaScript reads a time without one.</summary>
    private static double LocalOffsetMs(double utc)
    {
        if (Math.Abs(utc) > 2.5e14)
        {
            return 0;
        }
        return TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds((long)utc)).TotalMilliseconds;
    }

    private static double Clip(double ms) => Math.Abs(ms) > MaxTime ? double.NaN : ms;

    /// <summary><c>new Date(ms).toISOString()</c>; an ArgumentOutOfRangeException where JavaScript throws a RangeError.</summary>
    public static string IsoString(double ms)
    {
        if (!double.IsFinite(ms) || Math.Abs(Math.Truncate(ms)) > MaxTime)
        {
            throw new ArgumentOutOfRangeException(nameof(ms), "Invalid time value");
        }
        // TimeClip truncates toward zero.
        long t = (long)Math.Truncate(ms);
        long days = Math.DivRem(t, 86_400_000L, out long rest);
        if (rest < 0)
        {
            days--;
            rest += 86_400_000L;
        }
        var (year, month, day) = CivilFromDays(days);
        string prefix = year is >= 0 and <= 9999 ? Js.Pad(year, 4) : (year < 0 ? "-" : "+") + Js.Pad(Math.Abs(year), 6);
        return prefix + "-" + Js.Pad(month, 2) + "-" + Js.Pad(day, 2) + "T" + Js.Pad(rest / 3_600_000, 2) + ":" + Js.Pad(rest / 60_000 % 60, 2) + ":" + Js.Pad(rest / 1000 % 60, 2) + "." + Js.Pad(rest % 1000, 3) + "Z";
    }

    private static double UtcMs(long year, int month, int day, int hour, int minute, int second, int ms) =>
        (DaysFromCivil(year, month, day) * 86_400_000.0) + (hour * 3_600_000.0) + (minute * 60_000.0) + (second * 1000.0) + ms;

    /// <summary>Days since 1970-01-01 of a date in the proleptic Gregorian calendar.</summary>
    private static long DaysFromCivil(long y, int m, int d)
    {
        y -= m <= 2 ? 1 : 0;
        long era = (y >= 0 ? y : y - 399) / 400;
        long yoe = y - (era * 400);
        long doy = ((153 * (m + (m > 2 ? -3 : 9))) + 2) / 5 + d - 1;
        long doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy;
        return (era * 146_097) + doe - 719_468;
    }

    private static (long Year, int Month, int Day) CivilFromDays(long z)
    {
        z += 719_468;
        long era = (z >= 0 ? z : z - 146_096) / 146_097;
        long doe = z - (era * 146_097);
        long yoe = (doe - (doe / 1460) + (doe / 36_524) - (doe / 146_096)) / 365;
        long y = yoe + (era * 400);
        long doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100));
        long mp = ((5 * doy) + 2) / 153;
        int d = (int)(doy - (((153 * mp) + 2) / 5) + 1);
        int m = (int)(mp < 10 ? mp + 3 : mp - 9);
        return (m <= 2 ? y + 1 : y, m, d);
    }

    /// <summary>Days in a month of the proleptic Gregorian calendar.</summary>
    private static int DaysIn(long year, int month) => month switch
    {
        2 => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28,
        4 or 6 or 9 or 11 => 30,
        _ => 31,
    };
}
