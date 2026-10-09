using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Runlight.Data;

namespace Runlight;

/// <summary>
/// Browser, OS, and device from a user agent, plus the AI agent and bot tests.
/// </summary>
/// <remarks>
/// A client is { browser, browserVersion, os, osVersion, device ("desktop", "mobile", or
/// "tablet") }. Client hints are the low entropy ones Chromium browsers send on every request:
/// brands, mobile, and platform. The patterns keep JavaScript's meaning: <c>\d</c> is ASCII,
/// <c>.</c> stops at any line terminator, and <c>\S</c> at any JavaScript white space.
/// </remarks>
public static class Ua
{
    /// <summary>Any character JavaScript's <c>.</c> matches.</summary>
    private const string Dot = "[^\\n\\r\\u2028\\u2029]";

    /// <summary>Any character JavaScript's <c>\S</c> matches.</summary>
    private const string NonSpace = "[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]";

    private static Regex R(string pattern) => new(pattern, RegexOptions.CultureInvariant);

    private static readonly (string Name, Regex Pattern)[] Browsers =
    [
        ("Edge", R("(?:Edg|EdgA|EdgiOS|Edge)/([0-9]+)")),
        ("Opera", R("(?:OPR|OPiOS|Opera)/([0-9]+)")),
        ("Samsung Internet", R("SamsungBrowser/([0-9]+)")),
        ("Yandex Browser", R("YaBrowser/([0-9]+)")),
        ("Vivaldi", R("Vivaldi/([0-9]+)")),
        ("UC Browser", R("UCBrowser/([0-9]+)")),
        ("DuckDuckGo", R("(?:Ddg|DuckDuckGo)/([0-9]+)")),
        ("Facebook", R("FB(?:AV|_IAB)/([0-9]+)")),
        ("Instagram", R("Instagram ([0-9]+)")),
        ("Firefox", R("(?:Firefox|FxiOS)/([0-9]+)")),
        ("Chrome", R("(?:CriOS|Chrome)/([0-9]+)")),
        ("Safari", R("Version/([0-9]+)[0-9.]* (?:Mobile/" + NonSpace + "+ )?Safari/")),
        ("Internet Explorer", R("(?:MSIE |Trident/" + Dot + "*rv:)([0-9]+)")),
    ];

    private static readonly Dictionary<string, string> Windows = new(StringComparer.Ordinal)
    {
        ["10.0"] = "10",
        ["6.3"] = "8.1",
        ["6.2"] = "8",
        ["6.1"] = "7",
        ["6.0"] = "Vista",
        ["5.1"] = "XP",
    };

    private static readonly Regex WindowsNt = R("Windows NT ([0-9]+\\.[0-9]+)");
    private static readonly Regex Ios = R("(?:iPhone|iPad|iPod)" + Dot + "*? OS ([0-9]+)");
    private static readonly Regex AndroidVersion = R("Android ([0-9]+)");
    private static readonly Regex Mac = R("Mac OS X|Macintosh");
    private static readonly Regex Linux = R("Linux|X11");
    private static readonly Regex Tablet = R("iPad|Tablet|PlayBook|Silk");
    private static readonly Regex Mobile = R("Mobi|iPhone|iPod|Opera Mini|IEMobile");

    /// <summary>The AI agent a user agent names, or null.</summary>
    public static JsObject? AiAgent(string ua)
    {
        string lower = Js.Lower(ua);
        foreach (var agent in Lists.AiAgents)
        {
            if (lower.Contains(agent.Str("token")!, StringComparison.Ordinal))
            {
                return agent;
            }
        }
        return null;
    }

    public static bool IsBot(string ua)
    {
        string lower = JsPattern.AsciiLower(ua);
        if (ua.Length < 20 || (!lower.Contains("mozilla", StringComparison.Ordinal) && !lower.Contains("opera", StringComparison.Ordinal)))
        {
            return true;
        }
        return Lists.BotPattern.IsMatch(ua);
    }

    private static string Unquote(string? value) => Js.Trim((value ?? "").Replace("\"", "", StringComparison.Ordinal));

    /// <summary>The browser, OS, and device of a user agent, with the client hints and the screen width when there are any.</summary>
    public static JsObject ParseClient(string ua, JsObject? hints = null, double? screenWidth = null)
    {
        hints ??= new JsObject();
        string browser = "Other";
        string browserVersion = "";
        foreach (var (name, pattern) in Browsers)
        {
            var match = pattern.Match(ua);
            if (match.Success)
            {
                browser = name;
                browserVersion = match.Groups[1].Value;
                break;
            }
        }
        if (browser == "Chrome" && ua.Contains("; wv)", StringComparison.Ordinal))
        {
            browser = "Android WebView";
        }
        // Brave looks like Chrome in the user agent but names itself in the hints.
        if (browser == "Chrome" && (hints.Str("brands") ?? "").Contains("\"Brave\"", StringComparison.Ordinal))
        {
            browser = "Brave";
        }

        string os = "Other";
        string osVersion = "";
        Match m;
        if ((m = WindowsNt.Match(ua)).Success)
        {
            os = "Windows";
            osVersion = Windows.GetValueOrDefault(m.Groups[1].Value, "");
        }
        else if ((m = Ios.Match(ua)).Success)
        {
            os = "iOS";
            osVersion = m.Groups[1].Value;
        }
        else if ((m = AndroidVersion.Match(ua)).Success)
        {
            os = "Android";
            osVersion = m.Groups[1].Value;
        }
        else if (ua.Contains("Android", StringComparison.Ordinal))
        {
            os = "Android";
        }
        else if (ua.Contains("CrOS", StringComparison.Ordinal))
        {
            os = "Chrome OS";
        }
        else if (Mac.IsMatch(ua))
        {
            // macOS froze its version in the user agent at 10.15, so it says nothing.
            os = "macOS";
        }
        else if (Linux.IsMatch(ua))
        {
            os = "Linux";
        }
        string platform = Unquote(hints.Str("platform"));
        if (os == "Other" && platform.Length > 0)
        {
            os = platform == "macOS" ? "macOS" : platform;
        }

        string device = "desktop";
        if (Tablet.IsMatch(ua) || (os == "Android" && !ua.Contains("Mobile", StringComparison.Ordinal)))
        {
            device = "tablet";
        }
        else if (Mobile.IsMatch(ua) || Unquote(hints.Str("mobile")) == "?1")
        {
            device = "mobile";
        }
        else if (os == "macOS" && screenWidth is 768 or 810 or 820 or 834 or 1024)
        {
            // iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
            device = "tablet";
            os = "iOS";
        }

        return new JsObject
        {
            ["browser"] = browser,
            ["browserVersion"] = browserVersion,
            ["os"] = os,
            ["osVersion"] = osVersion,
            ["device"] = device,
        };
    }
}
