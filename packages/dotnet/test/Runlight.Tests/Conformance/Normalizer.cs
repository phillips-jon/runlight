using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>
/// The masking http-conformance.ts applies to answers, ported line by line from the PHP's
/// tests/Conformance/Normalizer.php: ids and other random values become placeholders, so answers
/// compare across runs and implementations. Values are as Json.Parse gives them (objects as
/// JsObject, arrays as lists, so {} and [] stay apart).
///
/// The regexes are JavaScript's, written here to read the same way: <c>\z</c> for JavaScript's
/// <c>$</c> without the m flag, and JavaScript's <c>\s</c> spelled out, since it matches Unicode
/// spaces that .NET's <c>\s</c> treats differently.
/// </summary>
public static class Normalizer
{
    /// <summary>Headers every implementation must send the same, where it sends them.</summary>
    public static readonly string[] Headers =
    [
        "content-type",
        "cache-control",
        "location",
        "set-cookie",
        "www-authenticate",
        "allow",
        "content-disposition",
        "content-security-policy",
        "x-frame-options",
        "referrer-policy",
        "x-content-type-options",
        "x-robots-tag",
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-max-age",
    ];

    // The version and the implementation differ between ports and releases, so they are placeholders too.
    private static readonly string[] Random = ["token", "secret", "hint", "version", "library", "language", "ticket", "recovery"];

    /// <summary>JavaScript's \s: WhiteSpace and LineTerminator, Unicode spaces included, as raw characters for a class.</summary>
    private static readonly string JsSpace = new(
    [
        (char)0x09, (char)0x0A, (char)0x0B, (char)0x0C, (char)0x0D, ' ', (char)0xA0, (char)0x1680,
        (char)0x2000, '-', (char)0x200A, (char)0x2028, (char)0x2029, (char)0x202F, (char)0x205F, (char)0x3000, (char)0xFEFF,
    ]);

    private const RegexOptions Options = RegexOptions.CultureInvariant;

    private static readonly Regex SecretQuery = new("([?&](?:code|ticket|secret|code_challenge)=)[^&#" + JsSpace + "\"'<>]+", Options);
    private static readonly Regex LongHex = new("(?<![A-Za-z0-9])[a-f0-9]{24,}(?![A-Za-z0-9])", Options);
    private static readonly Regex KeyInText = new("(?<![A-Za-z0-9_])rlo?_[A-Za-z0-9]{20,}(?![A-Za-z0-9])", Options);
    private static readonly Regex WholeKey = new("^rlo?_[A-Za-z0-9]+\\z", Options);
    private static readonly Regex WholeHex = new("^[a-f0-9]{24}\\z", Options);
    private static readonly Regex CookiePair = new("^([^=;]+)=([^;]*)", Options);

    /// <summary>Random parts inside a longer string: secrets in a query, and long runs of hex such as ids and signatures.</summary>
    public static string Scrub(string text)
    {
        text = SecretQuery.Replace(text, "$1<value>");
        text = LongHex.Replace(text, "<hex>");
        return KeyInText.Replace(text, "<key>");
    }

    /// <summary>Ids and other random values become "&lt;key&gt;", so answers compare across runs and implementations.</summary>
    public static object? Normalize(object? value, string key = "")
    {
        switch (value)
        {
            case List<object?> list:
                return list.Select(v => Normalize(v, key)).ToList();
            case JsObject obj:
                var output = new JsObject();
                foreach (var (k, v) in obj)
                {
                    output[k] = Normalize(v, k);
                }
                return output;
            case string s:
                if (Random.Contains(key, StringComparer.Ordinal) || WholeKey.IsMatch(s) || WholeHex.IsMatch(s))
                {
                    return "<" + (key.Length > 0 ? key : "value") + ">";
                }
                return Scrub(s);
            default:
                return value;
        }
    }

    /// <summary>A Set-Cookie header with its value as &lt;value&gt;, unless it clears the cookie.</summary>
    public static string CookieShape(string header) =>
        CookiePair.Replace(header, m => m.Groups[1].Value + "=" + (m.Groups[2].Value.Length > 0 ? "<value>" : ""), 1);

    /// <summary>
    /// Answers as one text to compare: object keys sorted, since JavaScript's deepEqual ignores their
    /// order, and numbers written as JSON writes them, so 1.0 and 1 are the same number as in JavaScript.
    /// </summary>
    public static string Canonical(object? value)
    {
        var output = new StringBuilder();
        Write(output, value, "");
        return output.ToString();
    }

    private static void Write(StringBuilder output, object? value, string indent)
    {
        string inner = indent + "  ";
        switch (value)
        {
            case JsObject obj:
                var keys = obj.Where(e => e.Value is not Undefined).Select(e => e.Key).OrderBy(k => k, StringComparer.Ordinal).ToList();
                if (keys.Count == 0)
                {
                    output.Append("{}");
                    return;
                }
                output.Append("{\n");
                for (int i = 0; i < keys.Count; i++)
                {
                    output.Append(inner).Append(Json.Quote(keys[i])).Append(": ");
                    Write(output, obj.Get(keys[i]), inner);
                    output.Append(i < keys.Count - 1 ? ",\n" : "\n");
                }
                output.Append(indent).Append('}');
                return;
            case List<object?> list:
                if (list.Count == 0)
                {
                    output.Append("[]");
                    return;
                }
                output.Append("[\n");
                for (int i = 0; i < list.Count; i++)
                {
                    output.Append(inner);
                    Write(output, list[i] is Undefined ? null : list[i], inner);
                    output.Append(i < list.Count - 1 ? ",\n" : "\n");
                }
                output.Append(indent).Append(']');
                return;
            default:
                output.Append(Json.Stringify(value));
                return;
        }
    }
}
