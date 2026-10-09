using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Runlight;

/// <summary>
/// The few JavaScript string and number rules the port has to keep exactly: numbers as
/// String(number) prints them, trim() with JavaScript's idea of white space,
/// decodeURIComponent's strictness, String(value), Number(value), Math.round, truthiness,
/// property reads, and comparing text with <c>&lt;</c>.
/// </summary>
/// <remarks>
/// .NET strings are UTF-16, as JavaScript's are, so <c>Length</c>, <c>Substring</c>, and the
/// indexer count and cut as the SDK does. Bytes read as text become U+FFFD where they are not
/// UTF-8, as a browser's TextDecoder makes them.
/// </remarks>
public static class Js
{
    /// <summary>2^53 - 1, the largest integer JavaScript holds exactly.</summary>
    public const long MaxSafeInteger = 9_007_199_254_740_991L;

    private static readonly UTF8Encoding Utf8Lenient = new(false, false);
    private static readonly UTF8Encoding Utf8Strict = new(false, true);

    // ---- numbers

    /// <summary>
    /// <c>String(n)</c>: the shortest digits that read back as <paramref name="n"/>, in plain
    /// notation from 1e-7 up to 1e21 and exponential notation outside it.
    /// </summary>
    public static string FormatNumber(double n)
    {
        if (double.IsNaN(n))
        {
            return "NaN";
        }
        if (double.IsInfinity(n))
        {
            return n > 0 ? "Infinity" : "-Infinity";
        }
        if (n == 0)
        {
            return "0";
        }
        var (digits, point) = Shortest(Math.Abs(n));
        int k = digits.Length;
        var b = new StringBuilder(n < 0 ? "-" : "");
        if (k <= point && point <= 21)
        {
            b.Append(digits);
            b.Append('0', point - k);
        }
        else if (0 < point && point <= 21)
        {
            b.Append(digits, 0, point).Append('.').Append(digits, point, k - point);
        }
        else if (-6 < point && point <= 0)
        {
            b.Append("0.").Append('0', -point).Append(digits);
        }
        else
        {
            b.Append(digits[0]);
            if (k > 1)
            {
                b.Append('.').Append(digits, 1, k - 1);
            }
            b.Append('e');
            if (point >= 1)
            {
                b.Append('+');
            }
            b.Append((point - 1).ToString(CultureInfo.InvariantCulture));
        }
        return b.ToString();
    }

    /// <summary>
    /// The shortest decimal digits that read back as <paramref name="x"/> (positive and finite),
    /// without leading or trailing zeros, and ECMAScript's <c>n</c>: the value is
    /// <c>0.d1...dk * 10^point</c>.
    /// </summary>
    public static (string Digits, int Point) Shortest(double x)
    {
        string s = x.ToString("R", CultureInfo.InvariantCulture);
        int e = s.IndexOfAny(['E', 'e']);
        string mantissa = e >= 0 ? s[..e] : s;
        int exp = e >= 0 ? int.Parse(s[(e + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) : 0;
        int dot = mantissa.IndexOf('.', StringComparison.Ordinal);
        string intPart = dot >= 0 ? mantissa[..dot] : mantissa;
        string frac = dot >= 0 ? mantissa[(dot + 1)..] : "";
        string all = intPart + frac;
        int point = intPart.Length + exp;
        int lead = 0;
        while (lead < all.Length - 1 && all[lead] == '0')
        {
            lead++;
        }
        all = all[lead..];
        point -= lead;
        int end = all.Length;
        while (end > 1 && all[end - 1] == '0')
        {
            end--;
        }
        return (all[..end], point);
    }

    /// <summary>A <c>long</c> as JavaScript prints the number it would hold.</summary>
    public static string FormatLong(long n)
    {
        if (n <= MaxSafeInteger && n >= -MaxSafeInteger)
        {
            return n.ToString(CultureInfo.InvariantCulture);
        }
        return FormatNumber(n);
    }

    /// <summary><c>Math.round</c>: halves go up, toward positive infinity, so -2.5 becomes -2.</summary>
    public static double Round(double value)
    {
        if (!double.IsFinite(value))
        {
            return value;
        }
        double floor = Math.Floor(value);
        // A double's distance from its floor is exact, so 0.49999999999999994 stays 0.
        return value - floor >= 0.5 ? floor + 1 : floor;
    }

    /// <summary><c>Math.round</c> as a long, for counts and times.</summary>
    public static long RoundLong(double value) => ToLong(Round(value));

    /// <summary>A JavaScript number as a long: truncated, NaN as 0, held at the ends of the range.</summary>
    public static long ToLong(double n)
    {
        if (double.IsNaN(n))
        {
            return 0;
        }
        if (n >= 9.2233720368547758E18)
        {
            return long.MaxValue;
        }
        if (n <= -9.2233720368547758E18)
        {
            return long.MinValue;
        }
        return (long)n;
    }

    /// <summary><c>Number.isInteger</c>.</summary>
    public static bool IsInteger(double n) => double.IsFinite(n) && n == Math.Floor(n);

    /// <summary>A number value as a double: a long, int, or double; anything else NaN.</summary>
    public static double Num(object? v) => Json.TryNumberOf(v, out double n) ? n : double.NaN;

    /// <summary>Number(value).</summary>
    public static double Number(object? value)
    {
        switch (value)
        {
            case null:
            case false:
                return 0;
            case true:
                return 1;
            case Undefined:
                return double.NaN;
        }
        if (Json.TryNumberOf(value, out double n))
        {
            return n;
        }
        if (value is IList list)
        {
            return Number(String(list));
        }
        if (value is not string s)
        {
            return double.NaN;
        }
        string text = Trim(s);
        if (text.Length == 0)
        {
            return 0;
        }
        if (text.Length > 2 && text[0] == '0' && (text[1] is 'x' or 'X' or 'o' or 'O' or 'b' or 'B'))
        {
            int radix = char.ToLowerInvariant(text[1]) switch
            {
                'x' => 16,
                'o' => 8,
                _ => 2,
            };
            double v = 0;
            for (int i = 2; i < text.Length; i++)
            {
                int d = HexDigit(text[i]);
                if (d < 0 || d >= radix)
                {
                    return double.NaN;
                }
                v = v * radix + d;
            }
            return v;
        }
        if (text is "Infinity" or "+Infinity")
        {
            return double.PositiveInfinity;
        }
        if (text == "-Infinity")
        {
            return double.NegativeInfinity;
        }
        if (!IsDecimalLiteral(text))
        {
            return double.NaN;
        }
        return double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
    }

    /// <summary>The value of a hex digit, or -1.</summary>
    public static int HexDigit(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>Whether text is a StrDecimalLiteral without Infinity: <c>[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?</c>.</summary>
    private static bool IsDecimalLiteral(string t)
    {
        int i = 0;
        if (i < t.Length && (t[i] == '+' || t[i] == '-'))
        {
            i++;
        }
        int intDigits = 0;
        while (i < t.Length && char.IsAsciiDigit(t[i]))
        {
            i++;
            intDigits++;
        }
        int fracDigits = 0;
        if (i < t.Length && t[i] == '.')
        {
            i++;
            while (i < t.Length && char.IsAsciiDigit(t[i]))
            {
                i++;
                fracDigits++;
            }
        }
        if (intDigits == 0 && fracDigits == 0)
        {
            return false;
        }
        if (i < t.Length && (t[i] == 'e' || t[i] == 'E'))
        {
            i++;
            if (i < t.Length && (t[i] == '+' || t[i] == '-'))
            {
                i++;
            }
            int expDigits = 0;
            while (i < t.Length && char.IsAsciiDigit(t[i]))
            {
                i++;
                expDigits++;
            }
            if (expDigits == 0)
            {
                return false;
            }
        }
        return i == t.Length;
    }

    /// <summary>parseInt(text, 10): leading white space, a sign, then digits; NaN when there are none.</summary>
    public static double ParseInt(string text)
    {
        string t = Trim(text);
        int i = 0;
        bool negative = false;
        if (i < t.Length && (t[i] == '+' || t[i] == '-'))
        {
            negative = t[i] == '-';
            i++;
        }
        int start = i;
        while (i < t.Length && char.IsAsciiDigit(t[i]))
        {
            i++;
        }
        if (i == start)
        {
            return double.NaN;
        }
        double v = double.Parse(t.AsSpan(start, i - start), NumberStyles.None, CultureInfo.InvariantCulture);
        return negative ? -v : v;
    }

    /// <summary>parseFloat(text).</summary>
    public static double ParseFloat(string text)
    {
        string t = Trim(text);
        int i = 0;
        if (i < t.Length && (t[i] == '+' || t[i] == '-'))
        {
            i++;
        }
        if (string.CompareOrdinal(t, i, "Infinity", 0, 8) == 0)
        {
            return t[0] == '-' ? double.NegativeInfinity : double.PositiveInfinity;
        }
        int intDigits = 0;
        while (i < t.Length && char.IsAsciiDigit(t[i]))
        {
            i++;
            intDigits++;
        }
        int fracDigits = 0;
        if (i < t.Length && t[i] == '.')
        {
            int dot = i;
            i++;
            while (i < t.Length && char.IsAsciiDigit(t[i]))
            {
                i++;
                fracDigits++;
            }
            if (fracDigits == 0 && intDigits == 0)
            {
                i = dot;
            }
        }
        if (intDigits == 0 && fracDigits == 0)
        {
            return double.NaN;
        }
        int end = i;
        if (i < t.Length && (t[i] == 'e' || t[i] == 'E'))
        {
            int j = i + 1;
            if (j < t.Length && (t[j] == '+' || t[j] == '-'))
            {
                j++;
            }
            int expStart = j;
            while (j < t.Length && char.IsAsciiDigit(t[j]))
            {
                j++;
            }
            if (j > expStart)
            {
                end = j;
            }
        }
        string part = t[..end];
        if (part.EndsWith('.'))
        {
            part = part[..^1];
        }
        return double.Parse(part, NumberStyles.Float, CultureInfo.InvariantCulture);
    }

    // ---- text

    /// <summary>Whether JavaScript's <c>\s</c> matches <paramref name="c"/>, which is also what trim() removes.</summary>
    public static bool IsSpace(char c) => c switch
    {
        (char)0x09 or (char)0x0a or (char)0x0b or (char)0x0c or (char)0x0d or (char)0x20
            or (char)0xa0 or (char)0x1680 or (char)0x2028 or (char)0x2029 or (char)0x202f
            or (char)0x205f or (char)0x3000 or (char)0xfeff => true,
        _ => c >= (char)0x2000 && c <= (char)0x200a,
    };

    /// <summary>String.prototype.trim.</summary>
    public static string Trim(string s)
    {
        int start = 0;
        int end = s.Length;
        while (start < end && IsSpace(s[start]))
        {
            start++;
        }
        while (end > start && IsSpace(s[end - 1]))
        {
            end--;
        }
        return start == 0 && end == s.Length ? s : s.Substring(start, end - start);
    }

    /// <summary>String.prototype.trimEnd.</summary>
    public static string TrimEnd(string s)
    {
        int end = s.Length;
        while (end > 0 && IsSpace(s[end - 1]))
        {
            end--;
        }
        return s[..end];
    }

    /// <summary>String.prototype.trimStart.</summary>
    public static string TrimStart(string s)
    {
        int start = 0;
        while (start < s.Length && IsSpace(s[start]))
        {
            start++;
        }
        return s[start..];
    }

    private static Dictionary<int, string>? _lower;
    private static Dictionary<int, string>? _upper;

    private static Dictionary<int, string> Table(string rows)
    {
        var map = new Dictionary<int, string>();
        foreach (string row in rows.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            int colon = row.IndexOf(':', StringComparison.Ordinal);
            map[int.Parse(row.AsSpan(0, colon), NumberStyles.HexNumber, CultureInfo.InvariantCulture)] = row[(colon + 1)..];
        }
        return map;
    }

    /// <summary>String.prototype.toLowerCase: JavaScript's full mappings, a final capital sigma as a final small one.</summary>
    public static string Lower(string s) => ChangeCase(s, _lower ??= Table(CaseTables.Lower), true);

    /// <summary>String.prototype.toUpperCase: JavaScript's full mappings (the German sharp s as "SS").</summary>
    public static string Upper(string s) => ChangeCase(s, _upper ??= Table(CaseTables.Upper), false);

    private static string ChangeCase(string s, Dictionary<int, string> table, bool lower)
    {
        bool plain = true;
        foreach (char c in s)
        {
            if (c >= 0x80 || (lower ? c is >= 'A' and <= 'Z' : c is >= 'a' and <= 'z'))
            {
                plain = false;
                break;
            }
        }
        if (plain)
        {
            return s;
        }
        var b = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            int cp = s[i];
            int width = 1;
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                cp = char.ConvertToUtf32(s[i], s[i + 1]);
                width = 2;
            }
            if (lower && cp == 0x03A3 && FinalSigma(s, i))
            {
                b.Append((char)0x03C2);
            }
            else if (table.TryGetValue(cp, out string? mapped))
            {
                b.Append(mapped);
            }
            else
            {
                b.Append(s, i, width);
            }
            i += width - 1;
        }
        return b.ToString();
    }

    /// <summary>Whether the capital sigma at <paramref name="at"/> ends a word: a cased letter before it and none after.</summary>
    private static bool FinalSigma(string s, int at)
    {
        int i = at - 1;
        while (i >= 0 && CaseIgnorable(s[i]))
        {
            i--;
        }
        if (i < 0 || !Cased(s[i]))
        {
            return false;
        }
        int j = at + 1;
        while (j < s.Length && CaseIgnorable(s[j]))
        {
            j++;
        }
        return j >= s.Length || !Cased(s[j]);
    }

    private static bool Cased(char c) => char.IsLower(c) || char.IsUpper(c) || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.TitlecaseLetter;

    private static bool CaseIgnorable(char c) => c is '\'' or '.' or ':' or '^' or '`' or (char)0xB7 or (char)0x2019 ||
        CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format
            or UnicodeCategory.ModifierLetter or UnicodeCategory.ModifierSymbol;

    /// <summary>String.prototype.slice, with JavaScript's clamping (a negative index counts from the end).</summary>
    public static string Slice(string s, long start, long? end = null)
    {
        long n = s.Length;
        long a = start < 0 ? Math.Max(start + n, 0) : Math.Min(start, n);
        long e = end ?? n;
        long z = e < 0 ? Math.Max(e + n, 0) : Math.Min(e, n);
        return a >= z ? "" : s.Substring((int)a, (int)(z - a));
    }

    /// <summary>
    /// text.slice(0, length), counting UTF-16 code units. Where JavaScript would cut a pair in
    /// two and keep half of a character, this leaves the whole character out, as the PHP port does.
    /// </summary>
    public static string Cut(string text, int length)
    {
        if (text.Length <= length)
        {
            return text;
        }
        int end = length;
        if (end > 0 && char.IsHighSurrogate(text[end - 1]))
        {
            end--;
        }
        return text[..end];
    }

    /// <summary>The bytes as text, each ill-formed sequence replaced by U+FFFD as the WHATWG decoder does.</summary>
    public static string Decode(byte[] bytes) => Decode(bytes.AsSpan());

    /// <summary>The bytes as text, each ill-formed sequence replaced by U+FFFD as the WHATWG decoder does.</summary>
    public static string Decode(ReadOnlySpan<byte> bytes) => Utf8Lenient.GetString(bytes);

    /// <summary>The bytes as text when they are UTF-8, else null.</summary>
    public static string? DecodeStrict(byte[] bytes)
    {
        try
        {
            return Utf8Strict.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>The text as UTF-8 bytes, a lone surrogate written as U+FFFD, as JavaScript writes text out.</summary>
    public static byte[] Utf8(string s) => Utf8Lenient.GetBytes(s);

    /// <summary>The length of the text written out as UTF-8.</summary>
    public static int Utf8Length(string s) => Utf8Lenient.GetByteCount(s);

    /// <summary>The text as JavaScript would read it back once written out: each lone surrogate as U+FFFD.</summary>
    public static string WellFormed(string s)
    {
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsSurrogate(s[i]))
            {
                return Utf8Lenient.GetString(Utf8Lenient.GetBytes(s));
            }
        }
        return s;
    }

    /// <summary>decodeURIComponent, or null where it would throw: a broken escape or bytes that are not UTF-8.</summary>
    public static string? DecodeURIComponent(string text)
    {
        if (text.IndexOf('%', StringComparison.Ordinal) < 0)
        {
            return text;
        }
        var b = new StringBuilder(text.Length);
        int i = 0;
        while (i < text.Length)
        {
            char c = text[i];
            if (c != '%')
            {
                b.Append(c);
                i++;
                continue;
            }
            var bytes = new List<byte>();
            while (i < text.Length && text[i] == '%')
            {
                if (i + 2 >= text.Length)
                {
                    return null;
                }
                int h = HexDigit(text[i + 1]);
                int l = HexDigit(text[i + 2]);
                if (h < 0 || l < 0)
                {
                    return null;
                }
                bytes.Add((byte)((h << 4) | l));
                i += 3;
            }
            string? part = DecodeStrict([.. bytes]);
            if (part == null)
            {
                return null;
            }
            b.Append(part);
        }
        return b.ToString();
    }

    /// <summary>encodeURIComponent(text).</summary>
    public static string EncodeURIComponent(string text) => Escape(text, "-_.!~*'()");

    /// <summary>encodeURI(text).</summary>
    public static string EncodeURI(string text) => Escape(text, "-_.!~*'();/?:@&=+$,#");

    private static string Escape(string text, string keep)
    {
        var b = new StringBuilder(text.Length);
        foreach (byte x in Utf8(text))
        {
            char c = (char)x;
            if (char.IsAsciiLetterOrDigit(c) || (x < 0x80 && keep.Contains(c, StringComparison.Ordinal)))
            {
                b.Append(c);
            }
            else
            {
                b.Append('%').Append("0123456789ABCDEF"[x >> 4]).Append("0123456789ABCDEF"[x & 15]);
            }
        }
        return b.ToString();
    }

    /// <summary>String(value) for the values the SDK passes it.</summary>
    public static string String(object? value)
    {
        switch (value)
        {
            case null:
                return "null";
            case Undefined:
                return "undefined";
            case bool b:
                return b ? "true" : "false";
            case string s:
                return s;
            case long l:
                return FormatLong(l);
            case int i:
                return i.ToString(CultureInfo.InvariantCulture);
            case double d:
                return FormatNumber(d);
            case JsObject:
                return "[object Object]";
            case IList list:
                {
                    var parts = new List<string>();
                    foreach (var v in list)
                    {
                        parts.Add(v is null or Undefined ? "" : String(v));
                    }
                    return string.Join(',', parts);
                }
        }
        if (Json.TryNumberOf(value, out double n))
        {
            return FormatNumber(n);
        }
        return value.ToString() ?? "";
    }

    /// <summary>Whether JavaScript reads a value as true.</summary>
    public static bool Truthy(object? value)
    {
        switch (value)
        {
            case null:
            case Undefined:
                return false;
            case bool b:
                return b;
            case string s:
                return s.Length > 0;
        }
        if (Json.TryNumberOf(value, out double n))
        {
            return n != 0 && !double.IsNaN(n);
        }
        return true;
    }

    /// <summary>Whether typeof value is "object" and it is not null: an array or an object.</summary>
    public static bool IsObject(object? value) => value is JsObject || value is IList;

    /// <summary>A plain object (not an array).</summary>
    public static bool IsPlainObject(object? value) => value is JsObject;

    /// <summary>
    /// value[key]: <see cref="Undefined.Value"/> when there is no such property, and a TypeError
    /// (an <see cref="InvalidOperationException"/>) for a property of null or undefined.
    /// </summary>
    public static object? Get(object? value, string key)
    {
        if (value is null or Undefined)
        {
            throw new InvalidOperationException("Cannot read properties of " + (value is null ? "null" : "undefined") + " (reading '" + key + "')");
        }
        if (value is JsObject o)
        {
            return o.Prop(key);
        }
        if (value is IList list)
        {
            if (key == "length")
            {
                return (double)list.Count;
            }
            long index = JsObject.ArrayIndex(key);
            return index >= 0 && index < list.Count ? list[(int)index] : Undefined.Value;
        }
        if (value is string s && key == "length")
        {
            return (double)s.Length;
        }
        return Undefined.Value;
    }

    /// <summary>Orders two strings as JavaScript's <c>&lt;</c> does, by UTF-16 code units: negative, zero, or positive.</summary>
    public static int Compare(string a, string b) => Math.Sign(string.CompareOrdinal(a, b));

    /// <summary>
    /// JSON.parse of a body as Response.json() reads it: a byte order mark is skipped and bytes
    /// that are not UTF-8 read as U+FFFD.
    /// </summary>
    public static bool ParseJson(byte[] body, out object? value)
    {
        string text = Decode(body);
        return ParseJson(text, out value);
    }

    /// <summary>JSON.parse of text as Response.json() reads it, a byte order mark skipped.</summary>
    public static bool ParseJson(string text, out object? value)
    {
        if (text.Length > 0 && text[0] == (char)0xFEFF)
        {
            text = text[1..];
        }
        return Json.TryParse(text, out value);
    }

    /// <summary>A whole number of milliseconds since 1970 as ISO 8601: <c>new Date(ms).toISOString()</c>.</summary>
    public static string IsoString(long ms) =>
        DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>The number with leading zeros to <paramref name="width"/> digits.</summary>
    public static string Pad(long n, int width)
    {
        string s = n.ToString(CultureInfo.InvariantCulture);
        return s.Length >= width ? s : new string('0', width - s.Length) + s;
    }

    /// <summary>A whole number as invariant text.</summary>
    public static string Str(long n) => n.ToString(CultureInfo.InvariantCulture);

    /// <summary>A list of values: <c>[a, b, c]</c>.</summary>
    public static List<object?> List(params object?[] items) => [.. items];
}
