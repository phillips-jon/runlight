using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Runlight;

/// <summary>
/// The dashboard's translations, for text the server writes (email reports). Same keys, same
/// placeholders, so every language stays in one place.
/// </summary>
public static class Messages
{
    private static JsObject? _raw;
    private static readonly ConcurrentDictionary<string, JsObject> Parsed = new(StringComparer.Ordinal);
    private static readonly Regex Placeholder = new("\\{([A-Za-z0-9_]+)\\}", RegexOptions.CultureInvariant);
    private static readonly Regex Exponent = new("^([0-9]+)(?:\\.([0-9]+))?e([+-][0-9]+)\\z", RegexOptions.CultureInvariant);

    /// <summary>Each language's table as JSON text, from the shared assets.</summary>
    private static JsObject Raw => _raw ??= (JsObject)Json.Parse(Assets.Text("locales.json"))!;

    internal static JsObject Table(string lang) => Parsed.GetOrAdd(lang, static l =>
        Raw.Get(l) is string text && Json.Parse(text) is JsObject table ? table : []);

    /// <summary>The languages there are words for, English first.</summary>
    public static IReadOnlyList<string> Languages() => ["en", .. Raw.Keys.Where(code => code != "en")];

    /// <summary>
    /// The words for one language: T(key, vars) and Tn(key, n, vars), with Lang the language used,
    /// English when the one asked for is not known.
    /// </summary>
    public static Translator Translator(string lang) => new(Languages().Contains(lang) ? lang : "en");

    internal static string Fill(string text, JsObject? vars) =>
        vars == null ? text : Placeholder.Replace(text, m => vars.Has(m.Groups[1].Value) ? Js.String(vars.Get(m.Groups[1].Value)) : m.Value);

    /// <summary>
    /// Intl.PluralRules(lang).select(n) for the dashboard's languages, by CLDR's cardinal rules. As
    /// there, the number is first written with at most three decimals (rounding half away from
    /// zero), and its integer digits i and visible decimals v are read from that. Any other
    /// language answers "other".
    /// </summary>
    /// <remarks>
    /// en, de: one when i = 1 and v = 0. es: one when n = 1; many when i is a non-zero multiple of a
    /// million and v = 0. fr, pt: one when i is 0 or 1; many as in es.
    /// </remarks>
    public static string Plural(string lang, double n)
    {
        if (!double.IsFinite(n))
        {
            return "other";
        }
        var (i, fraction) = Decimal(Math.Abs(n));
        int v = fraction.Length;
        bool million = i != "0" && i.Length >= 7 && i.EndsWith("000000", StringComparison.Ordinal);
        switch (lang)
        {
            case "en":
            case "de":
                return i == "1" && v == 0 ? "one" : "other";
            case "es":
                if (i == "1" && v == 0)
                {
                    return "one";
                }
                return million && v == 0 ? "many" : "other";
            case "fr":
            case "pt":
                if (i == "0" || i == "1")
                {
                    return "one";
                }
                return million && v == 0 ? "many" : "other";
        }
        return "other";
    }

    /// <summary>
    /// A non-negative number as its integer digits and up to three decimals without trailing
    /// zeros, from the shortest decimal that reads back as the number, as ICU formats it.
    /// </summary>
    private static (string Whole, string Fraction) Decimal(double n)
    {
        string text = Json.Number(n);
        // Plain digits, from JavaScript's exponent form where it uses one.
        var m = Exponent.Match(text);
        if (m.Success)
        {
            string digits = m.Groups[1].Value + m.Groups[2].Value;
            int point = m.Groups[1].Value.Length + int.Parse(m.Groups[3].Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            if (point <= 0)
            {
                text = "0." + new string('0', -point) + digits;
            }
            else if (point >= digits.Length)
            {
                text = digits + new string('0', point - digits.Length);
            }
            else
            {
                text = digits[..point] + "." + digits[point..];
            }
        }
        int dot = text.IndexOf('.', StringComparison.Ordinal);
        string whole = dot >= 0 ? text[..dot] : text;
        string fraction = dot >= 0 ? text[(dot + 1)..] : "";
        if (fraction.Length > 3)
        {
            bool up = fraction[3] >= '5';
            fraction = fraction[..3];
            if (up)
            {
                // Add one at the third decimal, carrying into the whole part.
                string all = Increment(whole + fraction);
                whole = all[..^3];
                fraction = all[^3..];
            }
        }
        // ICU reads i as a 64-bit integer, keeping only the lowest 18 digits of a larger number, so 1e21 has i = 0.
        whole = (whole.Length > 18 ? whole[^18..] : whole).TrimStart('0');
        return (whole.Length == 0 ? "0" : whole, fraction.TrimEnd('0'));
    }

    /// <summary>A string of decimal digits plus one.</summary>
    internal static string Increment(string digits)
    {
        var b = new StringBuilder(digits);
        int i = b.Length - 1;
        while (i >= 0 && b[i] == '9')
        {
            b[i] = '0';
            i--;
        }
        if (i < 0)
        {
            return "1" + b;
        }
        b[i] = (char)(b[i] + 1);
        return b.ToString();
    }
}

/// <summary>The words for one language, as Messages.Translator gives them.</summary>
public sealed class Translator
{
    internal Translator(string lang)
    {
        Lang = lang;
    }

    /// <summary>The language used.</summary>
    public string Lang { get; }

    /// <summary>The text for a key, its placeholders filled from vars: the language's, else English, else the key.</summary>
    public string T(string key, JsObject? vars = null)
    {
        string text = Messages.Table(Lang).Get(key) as string ?? Messages.Table("en").Get(key) as string ?? key;
        return Messages.Fill(text, vars);
    }

    /// <summary>The text for a count: the plural form the language uses for n, else the "other" form.</summary>
    public string Tn(string key, double n, JsObject? vars = null)
    {
        string form = Messages.Plural(Lang, n);
        var table = Messages.Table(Lang);
        string? own = table.Get(key + "_" + form) as string ?? table.Get(key + "_other") as string;
        return !string.IsNullOrEmpty(own) ? Messages.Fill(own, vars) : T(key + "_other", vars);
    }
}
