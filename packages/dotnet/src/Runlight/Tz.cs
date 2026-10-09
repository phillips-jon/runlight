using System;
using System.Buffers.Binary;
using System.IO;

namespace Runlight;

/// <summary>
/// A time zone's offset from UTC at any instant, to the second, as ICU gives it to JavaScript's
/// Intl: read from the IANA database's compiled files (TZif, RFC 8536) where the system has them,
/// with the rule in each file's footer for times past its last transition. .NET's TimeZoneInfo
/// is the fallback where there are no such files (Windows); it rounds old local mean times to the
/// minute and misreads footers whose changes fall at hour 24, which the files read here do not.
/// </summary>
internal sealed class Tz
{
    private static readonly string[] Dirs = [Environment.GetEnvironmentVariable("TZDIR") ?? "", "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo"];

    private readonly long[] _times = [];
    private readonly int[] _offsets = [];
    private readonly int _firstOffset;
    private readonly Rule? _footer;
    private readonly TimeZoneInfo? _info;
    private readonly int? _fixed;

    private Tz(long[] times, int[] offsets, int firstOffset, Rule? footer)
    {
        _times = times;
        _offsets = offsets;
        _firstOffset = firstOffset;
        _footer = footer;
    }

    private Tz(TimeZoneInfo info) => _info = info;

    private Tz(int fixedSeconds) => _fixed = fixedSeconds;

    /// <summary>A zone at a fixed offset, in seconds east of UTC.</summary>
    public static Tz Fixed(int seconds) => new(seconds);

    /// <summary>The zone the database names <paramref name="id"/> (as it spells it), or null.</summary>
    public static Tz? Find(string id)
    {
        if (id is "UTC" or "Etc/UTC")
        {
            return new Tz(0);
        }
        if (!id.Contains("..", StringComparison.Ordinal) && !id.StartsWith('/'))
        {
            foreach (string dir in Dirs)
            {
                if (dir.Length == 0)
                {
                    continue;
                }
                string file = Path.Combine(dir, id);
                if (File.Exists(file))
                {
                    try
                    {
                        var tz = Read(File.ReadAllBytes(file));
                        if (tz != null)
                        {
                            return tz;
                        }
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException or ArgumentException)
                    {
                        // Fall through to the system's zones.
                    }
                }
            }
        }
        try
        {
            return new Tz(TimeZoneInfo.FindSystemTimeZoneById(id));
        }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            return null;
        }
    }

    /// <summary>Seconds east of UTC at epoch second <paramref name="t"/>.</summary>
    public long Offset(long t)
    {
        if (_fixed is int f)
        {
            return f;
        }
        if (_info != null)
        {
            long clamped = Math.Clamp(t, -62_135_596_800L, 253_402_300_799L);
            return (long)_info.GetUtcOffset(DateTimeOffset.FromUnixTimeSeconds(clamped)).TotalSeconds;
        }
        if (_times.Length == 0 || t < _times[0])
        {
            return _times.Length == 0 && _footer != null ? _footer.Offset(t) : _firstOffset;
        }
        if (t >= _times[^1] && _footer != null)
        {
            return _footer.Offset(t);
        }
        int at = Array.BinarySearch(_times, t);
        if (at < 0)
        {
            at = ~at - 1;
        }
        return _offsets[at];
    }

    private static Tz? Read(byte[] b)
    {
        if (b.Length < 44 || b[0] != 'T' || b[1] != 'Z' || b[2] != 'i' || b[3] != 'f')
        {
            return null;
        }
        int version = b[4] == 0 ? 1 : b[4] - '0';
        int pos = 0;
        var (counts, start) = Header(b, pos);
        if (version < 2)
        {
            return Block(b, start, counts, 4, null);
        }
        // Skip the 32-bit block to the 64-bit one.
        pos = start + counts.Time * 5 + counts.Type * 6 + counts.Char + counts.Leap * 8 + counts.Std + counts.Ut;
        var (counts64, start64) = Header(b, pos);
        int end = start64 + counts64.Time * 9 + counts64.Type * 6 + counts64.Char + counts64.Leap * 12 + counts64.Std + counts64.Ut;
        Rule? footer = null;
        if (end < b.Length && b[end] == '\n')
        {
            int close = Array.IndexOf(b, (byte)'\n', end + 1);
            if (close > end + 1)
            {
                footer = Rule.Parse(System.Text.Encoding.ASCII.GetString(b, end + 1, close - end - 1));
            }
        }
        return Block(b, start64, counts64, 8, footer);
    }

    private readonly record struct Counts(int Ut, int Std, int Leap, int Time, int Type, int Char);

    private static (Counts, int) Header(byte[] b, int pos)
    {
        int Int(int at) => BinaryPrimitives.ReadInt32BigEndian(b.AsSpan(pos + 20 + at * 4, 4));
        return (new Counts(Int(0), Int(1), Int(2), Int(3), Int(4), Int(5)), pos + 44);
    }

    private static Tz Block(byte[] b, int start, Counts c, int width, Rule? footer)
    {
        var times = new long[c.Time];
        for (int i = 0; i < c.Time; i++)
        {
            times[i] = width == 8 ? BinaryPrimitives.ReadInt64BigEndian(b.AsSpan(start + i * 8, 8)) : BinaryPrimitives.ReadInt32BigEndian(b.AsSpan(start + i * 4, 4));
        }
        int indexAt = start + c.Time * width;
        int typesAt = indexAt + c.Time;
        int TypeOffset(int type) => BinaryPrimitives.ReadInt32BigEndian(b.AsSpan(typesAt + type * 6, 4));
        var offsets = new int[c.Time];
        for (int i = 0; i < c.Time; i++)
        {
            offsets[i] = TypeOffset(b[indexAt + i]);
        }
        return new Tz(times, offsets, c.Type > 0 ? TypeOffset(0) : 0, footer);
    }

    /// <summary>A POSIX TZ rule, as a TZif footer holds it: <c>std offset [dst [offset] [,start[/time],end[/time]]]</c>.</summary>
    private sealed class Rule
    {
        private int _std;
        private int _dst;
        private bool _hasDst;
        private Date _start;
        private Date _end;
        private int _startTime = 7200;
        private int _endTime = 7200;

        private record struct Date(char Kind, int A, int B, int C);

        public static Rule? Parse(string s)
        {
            var r = new Rule();
            int i = 0;
            if (!Name(s, ref i))
            {
                return null;
            }
            if (!Seconds(s, ref i, out int std))
            {
                return null;
            }
            r._std = -std;
            if (i >= s.Length)
            {
                return r;
            }
            if (!Name(s, ref i))
            {
                return null;
            }
            r._hasDst = true;
            r._dst = r._std + 3600;
            if (i < s.Length && s[i] != ',')
            {
                if (!Seconds(s, ref i, out int dst))
                {
                    return null;
                }
                r._dst = -dst;
            }
            if (i >= s.Length || s[i] != ',')
            {
                // No rule: the United States' rules, as POSIX leaves it to the implementation.
                r._start = new Date('M', 3, 2, 0);
                r._end = new Date('M', 11, 1, 0);
                return r;
            }
            i++;
            if (!DateOf(s, ref i, out r._start, out r._startTime) || i >= s.Length || s[i] != ',')
            {
                return null;
            }
            i++;
            if (!DateOf(s, ref i, out r._end, out r._endTime))
            {
                return null;
            }
            return r;
        }

        private static bool Name(string s, ref int i)
        {
            if (i < s.Length && s[i] == '<')
            {
                int close = s.IndexOf('>', i);
                if (close < 0)
                {
                    return false;
                }
                i = close + 1;
                return true;
            }
            int from = i;
            while (i < s.Length && char.IsAsciiLetter(s[i]))
            {
                i++;
            }
            return i - from >= 3;
        }

        /// <summary>[+-]hh[:mm[:ss]] as seconds.</summary>
        private static bool Seconds(string s, ref int i, out int seconds)
        {
            seconds = 0;
            int sign = 1;
            if (i < s.Length && (s[i] == '+' || s[i] == '-'))
            {
                sign = s[i] == '-' ? -1 : 1;
                i++;
            }
            int part = 0;
            int total = 0;
            int[] scale = [3600, 60, 1];
            while (part < 3)
            {
                int from = i;
                int n = 0;
                while (i < s.Length && char.IsAsciiDigit(s[i]))
                {
                    n = n * 10 + (s[i] - '0');
                    i++;
                }
                if (i == from)
                {
                    return false;
                }
                total += n * scale[part];
                part++;
                if (i < s.Length && s[i] == ':')
                {
                    i++;
                    continue;
                }
                break;
            }
            seconds = sign * total;
            return true;
        }

        private static bool DateOf(string s, ref int i, out Date date, out int time)
        {
            date = default;
            time = 7200;
            if (i >= s.Length)
            {
                return false;
            }
            if (s[i] == 'M')
            {
                i++;
                int[] n = new int[3];
                for (int k = 0; k < 3; k++)
                {
                    int from = i;
                    while (i < s.Length && char.IsAsciiDigit(s[i]))
                    {
                        n[k] = n[k] * 10 + (s[i] - '0');
                        i++;
                    }
                    if (i == from)
                    {
                        return false;
                    }
                    if (k < 2)
                    {
                        if (i >= s.Length || s[i] != '.')
                        {
                            return false;
                        }
                        i++;
                    }
                }
                date = new Date('M', n[0], n[1], n[2]);
            }
            else
            {
                char kind = 'n';
                if (s[i] == 'J')
                {
                    kind = 'J';
                    i++;
                }
                int from = i;
                int v = 0;
                while (i < s.Length && char.IsAsciiDigit(s[i]))
                {
                    v = v * 10 + (s[i] - '0');
                    i++;
                }
                if (i == from)
                {
                    return false;
                }
                date = new Date(kind, v, 0, 0);
            }
            if (i < s.Length && s[i] == '/')
            {
                i++;
                if (!Seconds(s, ref i, out time))
                {
                    return false;
                }
            }
            return true;
        }

        public long Offset(long t)
        {
            if (!_hasDst)
            {
                return _std;
            }
            long year = YearOf(t + _std);
            long start = Day(year, _start) * 86400 + _startTime - _std;
            long end = Day(year, _end) * 86400 + _endTime - _dst;
            bool dst = start < end ? t >= start && t < end : !(t >= end && t < start);
            return dst ? _dst : _std;
        }

        private static long YearOf(long seconds)
        {
            long days = (long)Math.Floor(seconds / 86400.0);
            return DateTime.UnixEpoch.AddDays(Math.Clamp(days, -719162, 2932896)).Year;
        }

        /// <summary>Days from 1970-01-01 to the rule's day in a year.</summary>
        private static long Day(long year, Date d)
        {
            long jan1 = Time.Utc(year, 0, 1) / 86_400_000;
            bool leap = DateTime.IsLeapYear((int)year);
            switch (d.Kind)
            {
                case 'J':
                    // 1 to 365, February 29 never counted.
                    return jan1 + d.A - 1 + (leap && d.A >= 60 ? 1 : 0);
                case 'n':
                    return jan1 + d.A;
                default:
                    {
                        int month = d.A;
                        int week = d.B;
                        int weekday = d.C;
                        long first = Time.Utc(year, month - 1, 1) / 86_400_000;
                        // 1970-01-01 was a Thursday (4).
                        long firstWeekday = ((first + 4) % 7 + 7) % 7;
                        long day = (weekday - firstWeekday + 7) % 7 + (week - 1) * 7;
                        int length = DateTime.DaysInMonth((int)year, month);
                        while (day >= length)
                        {
                            day -= 7;
                        }
                        return first + day;
                    }
            }
        }
    }
}
