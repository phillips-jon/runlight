using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Runlight;

/// <summary>
/// The pieces of JavaScript's Intl the email reports use, for the dashboard's languages (en, de,
/// es, fr, and pt), written out so they read the same on every platform: Intl.NumberFormat for
/// counts, percents, one decimal place, and currencies, Intl.DateTimeFormat for a month and year or
/// a short day, and Intl.DisplayNames for a region. Region names and currency symbols are Node's
/// ICU's, from Assets/intl.json (written by scripts/dotnet-intl.mjs).
/// </summary>
/// <remarks>
/// Numbers round as ICU does, half away from zero on the number's shortest decimal form, so 2.05
/// to one place is 2.1, though the double just under it is what is stored.
/// </remarks>
public static class Intl
{
    private static readonly Dictionary<string, string> Group = new(StringComparer.Ordinal) { ["en"] = ",", ["de"] = ".", ["es"] = ".", ["fr"] = ((char)0x202F).ToString(), ["pt"] = "." };
    private static readonly Dictionary<string, string> DecimalMark = new(StringComparer.Ordinal) { ["en"] = ".", ["de"] = ",", ["es"] = ",", ["fr"] = ",", ["pt"] = "," };
    private static readonly string Nbsp = ((char)0xA0).ToString();

    private static readonly Dictionary<string, string[]> Months = new(StringComparer.Ordinal)
    {
        ["en"] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        ["de"] = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
        ["es"] = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
        ["fr"] = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
        ["pt"] = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"],
    };

    private static readonly Dictionary<string, string[]> ShortMonths = new(StringComparer.Ordinal)
    {
        ["en"] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        ["de"] = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."],
        ["es"] = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
        ["fr"] = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
        ["pt"] = ["jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."],
    };

    /// <summary>{ month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with the year.</summary>
    private static readonly Dictionary<string, string[]> DatePatterns = new(StringComparer.Ordinal)
    {
        ["en"] = ["{M} {y}", "{m} {d}", "{m} {d}, {y}"],
        ["de"] = ["{M} {y}", "{d}. {m}", "{d}. {m} {y}"],
        ["es"] = ["{M} de {y}", "{d} {m}", "{d} {m} {y}"],
        ["fr"] = ["{M} {y}", "{d} {m}", "{d} {m} {y}"],
        ["pt"] = ["{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"],
    };

    private static readonly Regex Grouping = new("\\B(?=([0-9]{3})+\\z)", RegexOptions.CultureInvariant);
    private static readonly Regex CurrencyCode = new("^[A-Za-z]{3}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex RegionCode = new("^([A-Z]{2}|[0-9]{3})\\z", RegexOptions.CultureInvariant);

    private static JsObject? _data;

    private static JsObject Data => _data ??= (JsObject)Json.Parse(Assets.Text("intl.json"))!;

    private static string Lang(string lang) => Group.ContainsKey(lang) ? lang : "en";

    /// <summary>new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n); the defaults are 0 and 3.</summary>
    public static string Number(string lang, double n, int minFraction = 0, int maxFraction = 3)
    {
        lang = Lang(lang);
        if (double.IsNaN(n))
        {
            return "NaN";
        }
        if (double.IsInfinity(n))
        {
            return (n < 0 ? "-" : "") + "∞";
        }
        var (negative, whole, fraction) = Rounded(n, minFraction, maxFraction);
        // Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
        if (!(lang == "es" && whole.Length < 5))
        {
            whole = Grouping.Replace(whole, Group[lang]);
        }
        return (negative ? "-" : "") + whole + (fraction.Length > 0 ? DecimalMark[lang] + fraction : "");
    }

    /// <summary>new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n).</summary>
    public static string Percent(string lang, double n)
    {
        lang = Lang(lang);
        string number = Number(lang, Times100(n), 0, 0);
        return lang is "en" or "pt" ? number + "%" : number + Nbsp + "%";
    }

    /// <summary>
    /// new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n),
    /// or <c>`${n} ${currency}`</c> where Intl throws (a currency code that is not three letters).
    /// </summary>
    public static string Currency(string lang, double n, string currency, int maxFraction)
    {
        ArgumentNullException.ThrowIfNull(currency);
        lang = Lang(lang);
        if (!CurrencyCode.IsMatch(currency))
        {
            return Js.String(n) + " " + currency;
        }
        string code = currency.ToUpperInvariant();
        string symbol = Data.Obj("currencies")!.Obj(lang)!.Str(code) ?? code;
        double digits = Data.Obj("digits")!.Has(code) ? Data.Obj("digits")!.Num(code) : 2;
        int minFraction = (int)Math.Min(digits, maxFraction);
        string amount = Number(lang, Math.Abs(n), minFraction, maxFraction);
        string sign = n < 0 || (n == 0 && double.IsNegative(n)) ? "-" : "";
        if (lang == "en")
        {
            // A space only between letters and digits, as CLDR's currency spacing has it: $12, CHF 7.
            bool spaced = !IsSymbol(symbol, symbol.Length - 1);
            return sign + symbol + (spaced ? Nbsp : "") + amount;
        }
        if (lang == "pt")
        {
            return sign + symbol + Nbsp + amount;
        }
        return sign + amount + Nbsp + symbol;
    }

    /// <summary>Whether the code point ending at index is in Unicode's symbol categories (\p{S}).</summary>
    private static bool IsSymbol(string text, int index)
    {
        if (index < 0)
        {
            return false;
        }
        if (index > 0 && char.IsLowSurrogate(text[index]) && char.IsHighSurrogate(text[index - 1]))
        {
            index--;
        }
        return CharUnicodeInfo.GetUnicodeCategory(text, index) is UnicodeCategory.MathSymbol or UnicodeCategory.CurrencySymbol
            or UnicodeCategory.ModifierSymbol or UnicodeCategory.OtherSymbol;
    }

    /// <summary>A date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it.</summary>
    public static string MonthYear(string lang, string date) => Date(lang, date, 0);

    /// <summary>A date as { month: "short", day: "numeric" } writes it, with <c>year: "numeric"</c> too when asked.</summary>
    public static string ShortDay(string lang, string date, bool withYear) => Date(lang, date, withYear ? 2 : 1);

    private static string Date(string lang, string date, int pattern)
    {
        ArgumentNullException.ThrowIfNull(date);
        lang = Lang(lang);
        string[] parts = date.Split('-');
        int y = int.Parse(parts[0], CultureInfo.InvariantCulture);
        int m = int.Parse(parts[1], CultureInfo.InvariantCulture);
        int d = int.Parse(parts[2], CultureInfo.InvariantCulture);
        return DatePatterns[lang][pattern]
            .Replace("{M}", Months[lang][m - 1], StringComparison.Ordinal)
            .Replace("{m}", ShortMonths[lang][m - 1], StringComparison.Ordinal)
            .Replace("{d}", d.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{y}", y.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
    }

    /// <summary>
    /// new Intl.DisplayNames(lang, { type: "region" }).of(code), or the code where ICU has no name.
    /// Only an upper case code is looked up; Intl gives any other back as it came.
    /// </summary>
    public static string Region(string lang, string code)
    {
        ArgumentNullException.ThrowIfNull(code);
        if (!RegionCode.IsMatch(code))
        {
            return code;
        }
        return Data.Obj("regions")!.Obj(Lang(lang))!.Str(code) is { Length: > 0 } name ? name : code;
    }

    /// <summary>n * 100, worked out on the decimal digits, as ICU scales a percent, so 0.135 is 13.5 and not 13.500000000000002.</summary>
    private static double Times100(double n)
    {
        if (!double.IsFinite(n) || n == 0)
        {
            return n * 100;
        }
        var (negative, digits, point) = Decimal(n);
        return double.Parse((negative ? "-" : "") + Plain(digits, point + 2), NumberStyles.Float, CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// The number's sign, whole digits, and fraction digits, rounded half away from zero to at most
    /// <paramref name="max"/> places and padded to at least <paramref name="min"/>.
    /// </summary>
    private static (bool Negative, string Whole, string Fraction) Rounded(double n, int min, int max)
    {
        var (negative, digits, point) = Decimal(n);
        // Digits as a whole number of units of 10^-max.
        int keep = point + max;
        string units;
        if (keep < 0)
        {
            units = "0";
        }
        else if (digits.Length > keep)
        {
            units = keep == 0 ? "0" : digits[..keep];
            if (digits[keep] >= '5')
            {
                units = Messages.Increment(units);
            }
        }
        else
        {
            units = digits.PadRight(keep, '0');
        }
        units = units.PadLeft(max + 1, '0');
        string whole = units[..^max].TrimStart('0');
        string fraction = (max > 0 ? units[^max..] : "").TrimEnd('0').PadRight(min, '0');
        return (negative, whole.Length == 0 ? "0" : whole, fraction);
    }

    /// <summary>
    /// The shortest decimal form of a double: its sign, its significant digits, and where the point
    /// goes (the number of digits before it, which may be zero or negative).
    /// </summary>
    private static (bool Negative, string Digits, int Point) Decimal(double n)
    {
        bool negative = n < 0 || (n == 0 && double.IsNegative(n));
        if (n == 0)
        {
            return (negative, "0", 1);
        }
        var (digits, point) = Js.Shortest(Math.Abs(n));
        return (negative, digits, point);
    }

    /// <summary>Digits with the point after <paramref name="point"/> of them, written out in full.</summary>
    private static string Plain(string digits, int point)
    {
        if (point <= 0)
        {
            return "0." + new string('0', -point) + digits;
        }
        if (point >= digits.Length)
        {
            return digits + new string('0', point - digits.Length);
        }
        return digits[..point] + "." + digits[point..];
    }
}
