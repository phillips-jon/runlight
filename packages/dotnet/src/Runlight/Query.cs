using System;
using System.Collections.Generic;

namespace Runlight;

/// <summary>
/// Report queries: which dimensions exist, where each lives, and how filters are read from a URL.
/// Shared by every store.
/// </summary>
/// <remarks>
/// A filter is { dimension, op ("is", "not", or "contains"), value }. A query is { site, from, to,
/// filters }, <c>from</c> inclusive and <c>to</c> exclusive, both epoch milliseconds.
/// </remarks>
public static class Query
{
    /// <summary>Dimensions recorded per event.</summary>
    public static readonly IReadOnlyDictionary<string, string> EventDimensions = new OrderedDictionary<string, string>(StringComparer.Ordinal)
    {
        ["page"] = "path",
        ["hostname"] = "hostname",
        ["event"] = "name",
    };

    /// <summary>Dimensions recorded once per session, from its first request.</summary>
    public static readonly IReadOnlyDictionary<string, string> SessionDimensions = new OrderedDictionary<string, string>(StringComparer.Ordinal)
    {
        ["entry"] = "entry_path",
        ["exit"] = "exit_path",
        ["referrer"] = "referrer_host",
        ["source"] = "source",
        ["channel"] = "channel",
        ["utm_source"] = "utm_source",
        ["utm_medium"] = "utm_medium",
        ["utm_campaign"] = "utm_campaign",
        ["utm_term"] = "utm_term",
        ["utm_content"] = "utm_content",
        ["country"] = "country",
        ["region"] = "region",
        ["city"] = "city",
        ["browser"] = "browser",
        ["browser_version"] = "browser_version",
        ["os"] = "os",
        ["os_version"] = "os_version",
        ["device"] = "device",
        ["screen"] = "screen",
        ["language"] = "language",
    };

    /// <summary>AI agent fetches are their own rows, outside visits.</summary>
    public static readonly string[] FetchDimensions = ["ai_agent", "ai_page"];

    /// <summary>Every dimension: the event ones, the session ones, then the fetch ones.</summary>
    public static readonly string[] Dimensions =
    [
        "page", "hostname", "event",
        "entry", "exit", "referrer", "source", "channel", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "country", "region", "city", "browser", "browser_version", "os", "os_version", "device", "screen", "language",
        "ai_agent", "ai_page",
    ];

    /// <summary>The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values.</summary>
    public const int MaxFilters = 6;

    public static bool IsDimension(string value) => Array.IndexOf(Dimensions, value) >= 0;

    public static bool IsSessionDimension(string value) => SessionDimensions.ContainsKey(value);

    public static bool IsEventDimension(string value) => EventDimensions.ContainsKey(value);

    /// <summary><c>dimension:op:value</c>, where the value may itself contain colons; null when it is not a filter.</summary>
    public static JsObject? ParseFilter(string text)
    {
        int first = text.IndexOf(':', StringComparison.Ordinal);
        int second = first < 0 ? -1 : text.IndexOf(':', first + 1);
        if (second < 0)
        {
            return null;
        }
        string dimension = text[..first];
        string op = text[(first + 1)..second];
        string value = text[(second + 1)..];
        if (!IsSessionDimension(dimension) && !IsEventDimension(dimension))
        {
            return null;
        }
        if (op != "is" && op != "not" && op != "contains")
        {
            return null;
        }
        return new JsObject { ["dimension"] = dimension, ["op"] = op, ["value"] = Js.Slice(value, 0, 500) };
    }
}
