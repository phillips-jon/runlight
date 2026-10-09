using System;
using Runlight.Http;

namespace Runlight;

/// <summary>
/// What the tracker sends, after validation. Anything malformed is dropped. A null number stands
/// for TypeScript's undefined.
/// </summary>
public sealed class Payload
{
    public const int MaxBody = 8 * 1024;

    /// <summary>One engagement ping covers at most the 30 minutes a session can idle.</summary>
    private const long MaxEngagedMs = 30 * 60 * 1000;

    private const int MaxProps = 30;

    /// <summary>"pageview", "event", or "engagement".</summary>
    public required string Kind { get; init; }

    public required string Site { get; init; }

    public required Url Url { get; init; }

    public required string Referrer { get; init; }

    public required string Title { get; init; }

    public long? ScreenWidth { get; init; }

    public long? ScreenHeight { get; init; }

    public required string Language { get; init; }

    public required string Name { get; init; }

    /// <summary>An event's properties, in JavaScript's key order, or null.</summary>
    public JsObject? Props { get; init; }

    public required string PageviewId { get; init; }

    public long EngagedMs { get; init; }

    public long? Scroll { get; init; }

    private static string Str(object? value, int max) => value is string s ? Js.WellFormed(Js.Slice(s, 0, max)) : "";

    private static long? Int(object? value, long min, long max)
    {
        if (!Json.TryNumberOf(value, out double n) || !double.IsFinite(n))
        {
            return null;
        }
        return (long)Math.Min(max, Math.Max(min, Js.Round(n)));
    }

    private static JsObject? PropsOf(object? value)
    {
        if (value is not JsObject o)
        {
            return null;
        }
        var output = new JsObject();
        int count = 0;
        foreach (var (key, raw) in o)
        {
            if (count >= MaxProps)
            {
                break;
            }
            string k = Js.WellFormed(Js.Slice(Js.Trim(key), 0, 60));
            if (k.Length == 0)
            {
                continue;
            }
            string text;
            if (raw is string s)
            {
                text = Js.WellFormed(Js.Slice(s, 0, 500));
            }
            else if (Json.TryNumberOf(raw, out double n) && double.IsFinite(n))
            {
                text = Js.String(n);
            }
            else if (raw is bool b)
            {
                text = b ? "true" : "false";
            }
            else
            {
                continue;
            }
            // Assigning out["__proto__"] in JavaScript sets the prototype, which a string cannot
            // be, so nothing is kept; it still counts.
            if (k != "__proto__")
            {
                output.Set(k, text);
            }
            count++;
        }
        return count == 0 ? null : output;
    }

    /// <summary>A tracker body read and checked, or null when anything about it is malformed.</summary>
    public static Payload? ParsePayload(string text)
    {
        if (text.Length > MaxBody)
        {
            return null;
        }
        if (!Json.TryParse(text, out object? parsed) || parsed is not JsObject body)
        {
            return null;
        }

        object? kind = body.Get("k");
        if (kind is not ("pageview" or "event" or "engagement"))
        {
            return null;
        }
        string k = (string)kind;

        var url = Url.Parse(Str(body.Get("u"), 2048));
        if (url == null || (url.Protocol != "http:" && url.Protocol != "https:"))
        {
            return null;
        }

        string name = Js.Trim(Str(body.Get("n"), 120));
        if (k == "event" && name.Length == 0)
        {
            return null;
        }

        string pageviewId = Str(body.Get("i"), 32);
        foreach (char c in pageviewId)
        {
            if (!char.IsAsciiLetterOrDigit(c))
            {
                return null;
            }
        }
        if (k == "engagement" && pageviewId.Length == 0)
        {
            return null;
        }

        return new Payload
        {
            Kind = k,
            Site = Str(body.Get("s"), 64),
            Url = url,
            Referrer = Str(body.Get("r"), 2048),
            Title = Str(body.Get("t"), 500),
            ScreenWidth = Int(body.Get("w"), 0, 20000),
            ScreenHeight = Int(body.Get("h"), 0, 20000),
            Language = Str(body.Get("l"), 35),
            Name = name,
            Props = k == "event" ? PropsOf(body.Get("p")) : null,
            PageviewId = pageviewId,
            EngagedMs = k == "engagement" ? Int(body.Get("e"), 0, MaxEngagedMs) ?? 0 : 0,
            Scroll = Int(body.Get("d"), 0, 100),
        };
    }
}
