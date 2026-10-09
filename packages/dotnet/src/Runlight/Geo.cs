using System;
using System.Text;
using System.Text.RegularExpressions;
using Runlight.Http;

namespace Runlight;

/// <summary>
/// Where a visitor is, from a hosting platform's headers or a database lookup.
/// </summary>
/// <remarks>
/// A location is { country, region, city }: the country ISO 3166-1 alpha-2 in upper case, the
/// region ISO 3166-2 such as "US-CA". A lookup is a function from an IP address to an object with
/// any of those keys, such as one made by FileLookup from an MMDB file. Where the TypeScript would
/// throw a TypeError on a value of the wrong type (a number for a city), this throws a
/// <see cref="JsTypeError"/> too, and the callers catch it where the TypeScript does.
/// </remarks>
public static class Geo
{
    private static readonly Regex Region = new("^([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Bracketed = new("[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]*\\([^)]*\\)[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]*\\z", RegexOptions.CultureInvariant);

    public static JsObject Empty() => new() { ["country"] = "", ["region"] = "", ["city"] = "" };

    private static string Decode(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "";
        }
        return Js.Trim(Js.DecodeURIComponent(value) ?? value);
    }

    private static bool IsUpperPair(string s) => s.Length == 2 && char.IsAsciiLetterUpper(s[0]) && char.IsAsciiLetterUpper(s[1]);

    private static JsObject Clean(JsObject location)
    {
        string country = Js.Slice(Js.Upper(Text(location.Prop("country"))), 0, 2);
        if (!IsUpperPair(country) || country == "XX" || country == "T1")
        {
            country = "";
        }
        // A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database that has no codes
        // ("California") is kept readable, as "US-California".
        string raw = Js.Trim(Text(location.Prop("region")));
        string region = Region.IsMatch(raw) ? raw.ToUpperInvariant() : Js.Slice(raw, 0, 80);
        if (region.Length > 0 && !(region.Length >= 3 && IsUpperPair(region[..2]) && region[2] == '-') && country.Length > 0)
        {
            region = country + "-" + region;
        }
        if (country.Length == 0)
        {
            region = "";
        }
        string city = country.Length > 0 ? Js.Slice(Text(location.Prop("city")), 0, 100) : "";
        return new JsObject { ["country"] = country, ["region"] = region, ["city"] = city };
    }

    /// <summary>A string, or "" for null, as <c>value ?? ""</c> gives; anything else has no string methods in JavaScript.</summary>
    private static string Text(object? value)
    {
        if (value is null or Undefined)
        {
            return "";
        }
        return value as string ?? throw new JsTypeError("Not a string");
    }

    /// <summary>Location from the headers a hosting platform adds, if any.</summary>
    public static JsObject? LocationFromHeaders(Headers headers)
    {
        string? vercel = headers.Get("x-vercel-ip-country");
        if (!string.IsNullOrEmpty(vercel))
        {
            return Clean(new JsObject
            {
                ["country"] = vercel,
                ["region"] = Decode(headers.Get("x-vercel-ip-country-region")),
                ["city"] = Decode(headers.Get("x-vercel-ip-city")),
            });
        }
        string? cloudflare = headers.Get("cf-ipcountry");
        if (!string.IsNullOrEmpty(cloudflare))
        {
            return Clean(new JsObject
            {
                ["country"] = cloudflare,
                ["region"] = Decode(headers.Get("cf-region-code")),
                ["city"] = Decode(headers.Get("cf-ipcity")),
            });
        }
        string? netlify = headers.Get("x-nf-geo");
        if (!string.IsNullOrEmpty(netlify))
        {
            try
            {
                object? geo = Json.Parse(Atob(netlify));
                if (geo == null)
                {
                    // Reading a field of null is a TypeError.
                    return null;
                }
                return Clean(new JsObject
                {
                    ["country"] = Field(Field(geo, "country"), "code"),
                    ["region"] = Field(Field(geo, "subdivision"), "code"),
                    ["city"] = Field(geo, "city"),
                });
            }
            catch (Exception e) when (e is JsonParseException or JsTypeError or FormatException)
            {
                return null;
            }
        }
        return null;
    }

    /// <summary><c>value?.key</c>: a field of a JSON object, or null (undefined) for anything else.</summary>
    private static object? Field(object? value, string key) => value is JsObject o && o.Has(key) ? o.Get(key) : null;

    /// <summary>atob(): forgiving base64 to a binary string, each byte one character.</summary>
    private static string Atob(string text)
    {
        var b = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (c is not ('\t' or '\n' or '\f' or '\r' or ' '))
            {
                b.Append(c);
            }
        }
        text = b.ToString();
        if (text.Length % 4 == 0)
        {
            if (text.EndsWith("==", StringComparison.Ordinal))
            {
                text = text[..^2];
            }
            else if (text.EndsWith('='))
            {
                text = text[..^1];
            }
        }
        if (text.Length % 4 == 1)
        {
            throw new FormatException("The string to be decoded is not correctly encoded.");
        }
        foreach (char c in text)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '+' && c != '/')
            {
                throw new FormatException("The string to be decoded is not correctly encoded.");
            }
        }
        string padded = text.PadRight((text.Length + 3) / 4 * 4, '=');
        byte[] bytes = Convert.FromBase64String(padded);
        var output = new StringBuilder(bytes.Length);
        foreach (byte x in bytes)
        {
            output.Append((char)x);
        }
        return output.ToString();
    }

    /// <summary>Where a visitor is: the platform's headers first, then the lookup, else nowhere.</summary>
    public static JsObject Locate(Headers headers, string ip, Func<string, JsObject?>? lookup = null)
    {
        var fromHeaders = LocationFromHeaders(headers);
        if (fromHeaders != null && fromHeaders.Str("country")!.Length > 0)
        {
            return fromHeaders;
        }
        if (lookup != null && ip.Length > 0)
        {
            try
            {
                var found = lookup(ip);
                if (found != null)
                {
                    return Clean(found);
                }
            }
            catch (Exception)
            {
                // A broken lookup must never lose the event.
            }
        }
        return Empty();
    }

    /// <summary>
    /// A lookup answering from an MMDB reader. DB-IP's records follow MaxMind's city layout, with
    /// names but no subdivision codes; a city loses the district DB-IP adds in brackets, as in
    /// "Toronto (Old Toronto)". This is the TypeScript server's lookupFrom.
    /// </summary>
    public static Func<string, JsObject?> LookupFrom(Func<string, object?> get)
    {
        return ip =>
        {
            object? found;
            try
            {
                found = get(ip);
            }
            catch (Exception)
            {
                return null;
            }
            object? country = At(found, "country", "iso_code");
            if (!Js.Truthy(country))
            {
                return null;
            }
            object? sub = At(found, "subdivisions", 0);
            object? city = At(found, "city", "names", "en") ?? "";
            return new JsObject
            {
                ["country"] = country,
                ["region"] = At(sub, "iso_code") ?? At(sub, "names", "en") ?? "",
                ["city"] = city is string s ? CityName(s) : city,
            };
        };
    }

    /// <summary>A lookup from an MMDB reader.</summary>
    public static Func<string, JsObject?> LookupFrom(Mmdb reader) => LookupFrom(reader.Get);

    /// <summary>A lookup from an MMDB file the owner supplies, such as MaxMind's GeoLite2 City.</summary>
    public static Func<string, JsObject?> FileLookup(string file) => LookupFrom(Mmdb.Open(file));

    /// <summary>A city as people say it, without a trailing bracketed district.</summary>
    public static string CityName(string name) => Js.Trim(Bracketed.Replace(name, "", 1));

    /// <summary><c>value?.a?.b</c>, through maps and lists decoded from a database record.</summary>
    private static object? At(object? value, params object[] path)
    {
        foreach (object key in path)
        {
            if (key is string k && value is JsObject o && o.Has(k))
            {
                value = o.Get(k);
            }
            else if (key is int i && value is System.Collections.Generic.List<object?> list && i < list.Count)
            {
                value = list[i];
            }
            else
            {
                return null;
            }
        }
        return value;
    }
}
