using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Runlight.Data;
using Runlight.Http;

namespace Runlight;

/// <summary>
/// Pages and where visits came from.
/// </summary>
/// <remarks>
/// A page is { hostname, path, utm: { source, medium, campaign, term, content }, ref, paid }: <c>ref</c>
/// is a <c>ref</c> or <c>source</c> query parameter, used when there is no utm_source, and <c>paid</c>
/// says a click id such as gclid was present (the id itself is never kept). An attribution is
/// { referrerHost, referrerPath, source, channel }, the channel one of Direct, Organic Search,
/// Paid Search, Social, Email, AI, Referral, or Campaign.
/// </remarks>
public static class Sources
{
    private static readonly string[] ClickIds = ["gclid", "gbraid", "wbraid", "dclid", "fbclid", "msclkid", "ttclid", "twclid", "li_fat_id", "yclid"];
    private static readonly Regex PaidMediums = new("^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)\\z", RegexOptions.CultureInvariant);
    private static readonly Regex EmailMediums = new("^(e-?mail|newsletter|mail)\\z", RegexOptions.CultureInvariant);
    private static readonly Regex SocialMediums = new("^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Escapes = new("(?:%[0-9A-Fa-f]{2})+", RegexOptions.CultureInvariant);

    private static readonly Dictionary<string, JsObject> ByHost = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, JsObject> ByAlias = new(StringComparer.Ordinal);

    static Sources()
    {
        // Later entries win, as Map.set does: the alias "kit" names Newsletter, not Kit.
        foreach (var source in Lists.Sources)
        {
            foreach (var host in source.Arr("hosts")!)
            {
                ByHost[(string)host!] = source;
            }
            foreach (var alias in source.Arr("aliases") ?? [])
            {
                ByAlias[(string)alias!] = source;
            }
        }
    }

    private static string Clip(string? value, int max = 200) => Js.Slice(Js.Trim(value ?? ""), 0, max);

    public static string StripWww(string host)
    {
        string lower = Js.Lower(host);
        return lower.StartsWith("www.", StringComparison.Ordinal) ? lower[4..] : lower;
    }

    /// <summary>
    /// The most specific known source for a host: mail.google.com before google.com. Android apps
    /// send their package name as the referrer (com.google.android.gm for Gmail), which is matched
    /// the same way. Hosts known only by their shape (click trackers, webmail) come last.
    /// </summary>
    public static JsObject? SourceForHost(string host)
    {
        string clean = StripWww(host);
        string candidate = clean;
        while (candidate.Contains('.', StringComparison.Ordinal))
        {
            if (ByHost.TryGetValue(candidate, out var found))
            {
                return found;
            }
            candidate = candidate[(candidate.IndexOf('.', StringComparison.Ordinal) + 1)..];
        }
        foreach (var (pattern, name, kind) in Lists.SourcePatterns)
        {
            if (pattern.IsMatch(clean))
            {
                return new JsObject { ["name"] = name ?? clean, ["kind"] = kind, ["hosts"] = new List<object?>() };
            }
        }
        return null;
    }

    public static JsObject? SourceForAlias(string value)
    {
        string key = Js.Trim(Js.Lower(value));
        if (ByAlias.TryGetValue(key, out var source))
        {
            return source;
        }
        return ByHost.TryGetValue(StripWww(key), out source) ? source : null;
    }

    /// <summary>
    /// A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a
    /// leading slash, percent-encoded as the browser's URL parser encodes it, and with a hash route
    /// kept, as ParsePage keeps it. Null when it is not a path or a URL.
    /// </summary>
    public static string? RecordedPath(string input)
    {
        bool absolute = input.Length >= 7 && (input.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || input.StartsWith("https://", StringComparison.OrdinalIgnoreCase));
        var url = absolute
            ? Url.Parse(input)
            : Url.Parse(input.StartsWith('/') ? input : "/" + input, "https://x.invalid");
        return url == null ? null : ParsePage(url).Str("path");
    }

    /// <summary>
    /// A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text
    /// is decoded; an encoded slash, space, or other mark that would change the path's meaning
    /// stays as it is.
    /// </summary>
    public static string ReadablePath(string path) => Escapes.Replace(path, m =>
    {
        string? text = Js.DecodeURIComponent(m.Value);
        if (text == null)
        {
            return m.Value;
        }
        return Unreadable(text) ? m.Value : text;
    });

    /// <summary>Whether decoded text holds white space, a slash, ?, #, %, or a control, format, private, or unassigned character.</summary>
    private static bool Unreadable(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 0x10000 && Js.IsSpace((char)rune.Value))
            {
                return true;
            }
            if (rune.Value is '/' or '?' or '#' or '%')
            {
                return true;
            }
            if (System.Text.Rune.GetUnicodeCategory(rune) is System.Globalization.UnicodeCategory.Control or System.Globalization.UnicodeCategory.Format
                or System.Globalization.UnicodeCategory.Surrogate or System.Globalization.UnicodeCategory.PrivateUse or System.Globalization.UnicodeCategory.OtherNotAssigned)
            {
                return true;
            }
        }
        return false;
    }

    public static JsObject ParsePage(Url url)
    {
        var q = url.SearchParams;
        string path = url.Pathname.Length > 0 ? url.Pathname : "/";
        // The tracker only sends a hash when the site asked for hash routing.
        if (url.Hash.Length > 1)
        {
            path += url.Hash;
        }
        bool paid = false;
        foreach (string id in ClickIds)
        {
            if (q.Has(id))
            {
                paid = true;
                break;
            }
        }
        return new JsObject
        {
            ["hostname"] = StripWww(url.Hostname),
            ["path"] = Js.Slice(path, 0, 1000),
            ["utm"] = new JsObject
            {
                ["source"] = Clip(q.Get("utm_source")),
                ["medium"] = Js.Lower(Clip(q.Get("utm_medium"))),
                ["campaign"] = Clip(q.Get("utm_campaign")),
                ["term"] = Clip(q.Get("utm_term")),
                ["content"] = Clip(q.Get("utm_content")),
            },
            ["ref"] = Clip(q.Get("ref") ?? q.Get("source")),
            ["paid"] = paid,
        };
    }

    /// <summary>
    /// Where a visit came from. <paramref name="internalHosts"/> are the site's own hostnames: a
    /// referrer on one of them is navigation within the site, not a source.
    /// </summary>
    public static JsObject Attribute(JsObject page, string referrer, IReadOnlyCollection<string> internalHosts)
    {
        string referrerHost = "";
        string referrerPath = "";
        if (referrer.Length > 0)
        {
            // Not a URL is treated as no referrer.
            var url = Url.Parse(referrer);
            // Android apps refer as android-app://<package>/.
            if (url != null && url.Protocol is "http:" or "https:" or "android-app:")
            {
                string host = StripWww(url.Hostname);
                if (host != page.Str("hostname") && !Contains(internalHosts, host))
                {
                    referrerHost = host;
                    referrerPath = url.Protocol == "android-app:" ? "" : Js.Slice(url.Pathname, 0, 500);
                }
            }
        }

        var utm = page.Obj("utm")!;
        string utmSource = utm.Str("source")!;
        string utmMedium = utm.Str("medium")!;
        string pageRef = page.Str("ref")!;
        string tagged = utmSource.Length > 0 ? utmSource : pageRef;
        var known = tagged.Length > 0 ? SourceForAlias(tagged) : (referrerHost.Length > 0 ? SourceForHost(referrerHost) : null);
        string source = known?.Str("name") ?? (tagged.Length > 0 ? tagged : referrerHost);
        string? kind = known?.Str("kind") ?? (referrerHost.Length > 0 ? SourceForHost(referrerHost)?.Str("kind") : null);
        string medium = utmMedium;

        string channel;
        if ((page.Bool("paid") || PaidMediums.IsMatch(medium)) && kind == "search")
        {
            channel = "Paid Search";
        }
        else if (kind == "ai")
        {
            channel = "AI";
        }
        else if (EmailMediums.IsMatch(medium) || kind == "email")
        {
            channel = "Email";
        }
        else if (kind == "search")
        {
            channel = "Organic Search";
        }
        else if (SocialMediums.IsMatch(medium) || kind == "social")
        {
            channel = "Social";
        }
        else if (utmSource.Length > 0 || utmMedium.Length > 0 || utm.Str("campaign")!.Length > 0)
        {
            channel = "Campaign";
        }
        else if (referrerHost.Length > 0 || pageRef.Length > 0)
        {
            channel = "Referral";
        }
        else
        {
            channel = "Direct";
        }

        return new JsObject { ["referrerHost"] = referrerHost, ["referrerPath"] = referrerPath, ["source"] = source, ["channel"] = channel };
    }

    private static bool Contains(IReadOnlyCollection<string> hosts, string host)
    {
        foreach (string h in hosts)
        {
            if (h == host)
            {
                return true;
            }
        }
        return false;
    }
}
