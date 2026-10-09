using System;
using System.Collections.Generic;

namespace Runlight;

/// <summary>Funnels: checking one from the dashboard. Counting is the store's FunnelCountsAsync().</summary>
public static class Funnels
{
    /// <summary>
    /// Checks and tidies a funnel from the dashboard: a name, and two to eight steps, each a page
    /// (with * as a wildcard) or an event name.
    /// </summary>
    /// <returns>The FunnelRow: id, site, name, steps (each kind and match), and createdAt.</returns>
    /// <exception cref="FunnelError">When the funnel cannot be made, saying why.</exception>
    public static JsObject FunnelFrom(JsObject input, string site, IReadOnlyList<JsObject> existing, long now, string? id = null)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(existing);
        string name = Js.Cut(Js.Trim(Goals.Field(input, "name")), 80);
        if (name.Length == 0)
        {
            throw new FunnelError("Give the funnel a name", "funnel_name");
        }
        foreach (var f in existing)
        {
            if (f.Str("id") != id && Js.Lower(f.Str("name") ?? "") == Js.Lower(name))
            {
                throw new FunnelError("There is already a funnel called \"" + name + "\"", "funnel_exists", new JsObject { ["name"] = name });
            }
        }
        var raw = input.Get("steps") as List<object?> ?? [];
        var steps = new List<object?>();
        foreach (object? item in raw)
        {
            // Anything that is not an object reads as one with no fields.
            var step = item as JsObject ?? [];
            string kind = step.Prop("kind") is "event" ? "event" : "page";
            string match = Js.Cut(Js.Trim(Goals.Field(step, "match")), 500);
            if (match.Length == 0)
            {
                continue;
            }
            if (kind == "page")
            {
                // A full URL is fine to paste; the path is what counts.
                match = Goals.PagePattern(match) ?? throw new FunnelError("\"" + match + "\" is not a path or a URL", "funnel_page_bad", new JsObject { ["match"] = match });
            }
            steps.Add(new JsObject { ["kind"] = kind, ["match"] = match });
        }
        if (steps.Count < 2)
        {
            throw new FunnelError("A funnel needs at least two steps", "funnel_short");
        }
        if (steps.Count > 8)
        {
            throw new FunnelError("A funnel has at most eight steps", "funnel_long");
        }
        object? createdAt = now;
        foreach (var f in existing)
        {
            if (f.Str("id") == id)
            {
                createdAt = f.Get("createdAt");
                break;
            }
        }
        return new JsObject { ["id"] = id ?? Hash.RandomId(), ["site"] = site, ["name"] = name, ["steps"] = steps, ["createdAt"] = createdAt };
    }
}
