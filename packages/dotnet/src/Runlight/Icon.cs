using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight;

/// <summary>A site's icon: the image's bytes and its media type.</summary>
public sealed record SiteIcon(byte[] Body, string Type);

/// <summary>
/// A site's icon, for the dashboard header: the best icon its home page links to, or
/// /favicon.ico. Fetched from the site's own configured origin (never from request input), cached
/// in memory for a day.
/// </summary>
public static class Icon
{
    private const int TimeoutMs = 4000;
    private const int MaxBytes = 256 * 1024;
    private const long Day = 86_400_000;

    /// <summary>A few hundred sites at most; past that the oldest go, so the cache cannot grow without end.</summary>
    private const int CacheSize = 500;

    /// <summary>The characters of JavaScript's \s, for character classes.</summary>
    private const string SpaceChars = "\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff";

    /// <summary>JavaScript's \s, for patterns.</summary>
    private const string Space = "[" + SpaceChars + "]";

    private static readonly Regex LinkTag = new("<" + Letters("link") + "(?![A-Za-z0-9_])[^>]*>", RegexOptions.CultureInvariant);
    private static readonly Regex Spaces = new(Space + "+", RegexOptions.CultureInvariant);

    /// <summary>One attribute: its name, then any value, double quoted, single quoted, or bare.</summary>
    private static readonly Regex AttributePattern = new(
        "([^" + SpaceChars + "\"'>/=]+)(?:" + Space + "*=" + Space + "*(?:\"([^\"]*)\"|'([^']*)'|([^" + SpaceChars + ">]+)))?",
        RegexOptions.CultureInvariant);

    private static readonly object Lock = new();
    private static readonly Dictionary<string, (long At, SiteIcon? Icon)> Cache = new(StringComparer.Ordinal);
    private static readonly LinkedList<string> Order = new();

    /// <summary>Lookups under way, so many dashboards opening at once share one.</summary>
    private static readonly Dictionary<string, Task<SiteIcon?>> Pending = new(StringComparer.Ordinal);

    /// <summary>A word matched in either case, as JavaScript's /i matches ASCII letters.</summary>
    private static string Letters(string word)
    {
        var b = new StringBuilder();
        foreach (char c in word)
        {
            b.Append('[').Append(char.ToLowerInvariant(c)).Append(char.ToUpperInvariant(c)).Append(']');
        }
        return b.ToString();
    }

    /// <summary>
    /// A tag's attributes, read one after another so a name inside another (data-rel) or inside
    /// a value (title="rel=icon") is never taken for one. The first of a repeated name counts, as
    /// in a browser.
    /// </summary>
    private static Dictionary<string, string> Attrs(string tag)
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (Match m in AttributePattern.Matches(tag["<link".Length..]))
        {
            string name = Js.Lower(m.Groups[1].Value);
            if (!output.ContainsKey(name))
            {
                string value = m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Success ? m.Groups[3].Value : m.Groups[4].Success ? m.Groups[4].Value : "";
                output[name] = Js.Trim(value);
            }
        }
        return output;
    }

    /// <summary>Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon.</summary>
    public static List<string> IconLinks(string html, string baseUrl)
    {
        var found = new List<(string Url, int Score)>();
        foreach (Match tag in LinkTag.Matches(html))
        {
            var attributes = Attrs(tag.Value);
            string[] rel = Spaces.Split(Js.Lower(attributes.GetValueOrDefault("rel", "")));
            string href = attributes.GetValueOrDefault("href", "");
            if (href.Length == 0 || !(rel.Contains("icon") || rel.Contains("apple-touch-icon")))
            {
                continue;
            }
            var parsed = Url.Parse(href, baseUrl);
            if (parsed == null)
            {
                continue;
            }
            string url = parsed.Href;
            // Only https, which is all the fetch below takes.
            if (!url.StartsWith("https://", StringComparison.Ordinal))
            {
                continue;
            }
            string type = Js.Lower(attributes.GetValueOrDefault("type", ""));
            int score = rel.Contains("apple-touch-icon") ? 3
                : type.Contains("svg", StringComparison.Ordinal) || url.EndsWith(".svg", StringComparison.Ordinal) ? 2
                : type.Contains("png", StringComparison.Ordinal) || url.EndsWith(".png", StringComparison.Ordinal) ? 1 : 0;
            found.Add((url, score));
        }
        // OrderByDescending is stable, as Array.prototype.sort is.
        return found.OrderByDescending(f => f.Score).Select(f => f.Url).ToList();
    }

    /// <summary>A GET of a public https address, with redirects followed only to public addresses too.</summary>
    private static async Task<Response?> GetAsync(string url, IFetcher fetcher, long maxBytes, bool truncate)
    {
        try
        {
            var init = new PublicFetchInit { TimeoutMs = TimeoutMs, Redirects = 3, MaxBytes = maxBytes, Truncate = truncate };
            init.Headers.Set("user-agent", "Runlight (+https://runlight.sh)");
            var response = await Safefetch.PublicFetchAsync(url, init, fetcher).ConfigureAwait(false);
            await response.BytesAsync().ConfigureAwait(false);
            return response;
        }
#pragma warning disable CA1031 // Any failure means no icon from here, as the TypeScript's catch.
        catch (Exception)
#pragma warning restore CA1031
        {
            return null;
        }
    }

    private static async Task<SiteIcon?> ImageAsync(string url, IFetcher fetcher)
    {
        // An image must arrive whole, so one longer than the cap is no use.
        var response = await GetAsync(url, fetcher, MaxBytes, false).ConfigureAwait(false);
        if (response == null || !response.Ok)
        {
            return null;
        }
        string type = Js.Lower(Js.Trim((response.Headers.Get("content-type") ?? "").Split(';')[0]));
        if (!type.StartsWith("image/", StringComparison.Ordinal))
        {
            return null;
        }
        if (Js.Number(response.Headers.Get("content-length")) > MaxBytes)
        {
            return null;
        }
        byte[] body = response.Bytes();
        if (body.Length == 0 || body.Length > MaxBytes)
        {
            return null;
        }
        return new SiteIcon(body, type);
    }

    /// <summary>The site's icon, or null when it has none that can be fetched.</summary>
    /// <param name="origin">The site's own origin, such as https://example.com.</param>
    /// <param name="now">The time, in epoch milliseconds.</param>
    /// <param name="fetcher">What fetches.</param>
    public static Task<SiteIcon?> FetchIconAsync(string origin, long now, IFetcher fetcher)
    {
        lock (Lock)
        {
            if (Cache.TryGetValue(origin, out var cached) && now - cached.At < (cached.Icon != null ? Day : Day / 24))
            {
                return Task.FromResult(cached.Icon);
            }
            if (!Pending.TryGetValue(origin, out var lookup))
            {
                // On the pool, so the lookup is in Pending before it can finish and leave.
                lookup = Task.Run(() => LookUpAsync(origin, now, fetcher));
                Pending[origin] = lookup;
            }
            return lookup;
        }
    }

    private static async Task<SiteIcon?> LookUpAsync(string origin, long now, IFetcher fetcher)
    {
        try
        {
            SiteIcon? icon = null;
            // The head is all that is needed, so a huge page is not read to the end.
            var page = await GetAsync(origin + "/", fetcher, 200_000, true).ConfigureAwait(false);
            if (page != null && page.Ok && (page.Headers.Get("content-type") ?? "").Contains("html", StringComparison.Ordinal))
            {
                string html = Body.Utf8(page.Bytes());
                // A Response from the fetcher has no url of its own, so links resolve against the origin.
                foreach (string url in IconLinks(html, origin).Take(4))
                {
                    icon = await ImageAsync(url, fetcher).ConfigureAwait(false);
                    if (icon != null)
                    {
                        break;
                    }
                }
            }
            icon ??= await ImageAsync(origin + "/favicon.ico", fetcher).ConfigureAwait(false);
            lock (Lock)
            {
                // As a Map, an origin already there keeps its place.
                if (!Cache.ContainsKey(origin))
                {
                    Order.AddLast(origin);
                }
                Cache[origin] = (now, icon);
                if (Cache.Count > CacheSize)
                {
                    Cache.Remove(Order.First!.Value);
                    Order.RemoveFirst();
                }
            }
            return icon;
        }
        finally
        {
            lock (Lock)
            {
                Pending.Remove(origin);
            }
        }
    }

    /// <summary>Forgets every icon, for tests.</summary>
    internal static void Forget()
    {
        lock (Lock)
        {
            Cache.Clear();
            Order.Clear();
        }
    }
}
