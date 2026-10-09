using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Runlight;

/// <summary>Goals: checking one from the dashboard, and the click rules the tracker carries.</summary>
public static class Goals
{
    private static readonly string[] Kinds = ["event", "page", "click"];
    private static readonly string[] Modes = ["none", "fixed", "prop"];
    private static readonly Regex Prop = new("^[A-Za-z0-9_.-]{1,40}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Currency = new("^[A-Z]{3}\\z", RegexOptions.CultureInvariant);

    /// <summary>
    /// A page to match, written the way paths are recorded: the path of a pasted URL, with a
    /// leading slash, percent-encoded as browsers send it, so /café matches the recorded
    /// /caf%C3%A9, and with a hash route kept, so /#/thanks counts only that route. <c>*</c> stays a
    /// wildcard. Null when it is not a path or a URL.
    /// </summary>
    public static string? PagePattern(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        string starred = input.Replace("*", "__STAR__", StringComparison.Ordinal);
        // A pattern written to start with * keeps that start, rather than gaining a slash.
        string? path = Sources.RecordedPath(starred.StartsWith("__STAR__", StringComparison.Ordinal) ? "/" + starred : starred);
        if (path == null)
        {
            return null;
        }
        string pattern = path.Replace("__STAR__", "*", StringComparison.Ordinal);
        return input.StartsWith('*') && pattern.StartsWith('/') ? pattern[1..] : pattern;
    }

    /// <summary><c>String(input[key] ?? "")</c>.</summary>
    public static string Field(JsObject input, string key)
    {
        ArgumentNullException.ThrowIfNull(input);
        object? value = input.Prop(key);
        return value is null or Undefined ? "" : Js.String(value);
    }

    /// <summary>
    /// Checks and tidies a goal from the dashboard. <paramref name="existing"/> is the site's other
    /// goals, so two goals cannot share a name.
    /// </summary>
    /// <returns>The GoalRow.</returns>
    /// <exception cref="GoalError">When the goal cannot be made, saying why.</exception>
    public static JsObject GoalFrom(JsObject input, string site, IReadOnlyList<JsObject> existing, long now, string? id = null)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(existing);
        string Text(string key, int max) => Js.Cut(Js.Trim(Field(input, key)), max);
        string name = Text("name", 80);
        if (name.Length == 0)
        {
            throw new GoalError("Give the goal a name", "goal_name");
        }
        foreach (var g in existing)
        {
            if (g.Str("id") != id && Js.Lower(g.Str("name") ?? "") == Js.Lower(name))
            {
                throw new GoalError("There is already a goal called \"" + name + "\"", "goal_exists", new JsObject { ["name"] = name });
            }
        }

        string kind = Field(input, "kind");
        if (!Kinds.Contains(kind))
        {
            throw new GoalError("Pick what the goal counts: an event, a page visit, or a click", "goal_kind");
        }

        string match = Text("match", 500);
        string clickBy = "";
        if (kind == "event" && match.Length == 0)
        {
            throw new GoalError("Enter the event's name", "goal_event");
        }
        if (kind == "page")
        {
            if (match.Length == 0)
            {
                throw new GoalError("Enter a page path, like /thanks or /blog/*", "goal_page");
            }
            // A full URL is fine to paste; the path is what counts.
            match = PagePattern(match) ?? throw new GoalError("That page is not a path or a URL", "goal_page_bad");
        }
        if (kind == "click")
        {
            clickBy = input.Prop("clickBy") is "link" ? "link" : "selector";
            if (match.Length == 0)
            {
                throw clickBy == "link"
                    ? new GoalError("Enter the link's address, like https://buy.stripe.com/*", "goal_link")
                    : new GoalError("Enter a CSS selector, like #signup or .buy-button", "goal_selector");
            }
        }

        // A click goal sends an event named after itself, so its name and an event goal's match must not meet.
        var others = existing.Where(g => g.Str("id") != id).ToList();
        if (kind == "click")
        {
            foreach (var g in others)
            {
                if (g.Str("kind") == "event" && Js.Lower(g.Str("match") ?? "") == Js.Lower(name))
                {
                    throw new GoalError("An event goal already counts events called \"" + name + "\", so give this click goal another name", "goal_event_taken", new JsObject { ["name"] = name });
                }
            }
        }
        if (kind == "event")
        {
            foreach (var g in others)
            {
                if (g.Str("kind") == "click" && Js.Lower(g.Str("name") ?? "") == Js.Lower(match))
                {
                    throw new GoalError("The click goal \"" + match + "\" already sends events with that name", "goal_click_taken", new JsObject { ["match"] = match });
                }
            }
        }

        string mode = Js.String(input.Prop("valueMode"));
        string valueMode = Modes.Contains(mode) ? mode : "none";
        // Page visits and click rules carry no properties, so only an event can send its own amount.
        if (valueMode == "prop" && kind != "event")
        {
            throw new GoalError("Only an event goal can take its amount from the event; use a fixed amount instead", "goal_prop_kind");
        }
        double value = valueMode == "fixed" ? Js.Number(input.Prop("value")) : 0;
        if (valueMode == "fixed" && !(double.IsFinite(value) && value >= 0 && value < 1e9))
        {
            throw new GoalError("Enter an amount, like 49 or 9.99", "goal_amount");
        }
        string valueProp = "";
        if (valueMode == "prop")
        {
            valueProp = Text("valueProp", 40);
            if (valueProp.Length == 0)
            {
                valueProp = "revenue";
            }
        }
        if (valueMode == "prop" && !Prop.IsMatch(valueProp))
        {
            throw new GoalError("A property name uses letters, numbers, dots, dashes, and underscores", "goal_prop_name");
        }
        string currency = Js.Upper(Text("currency", 20));
        if (currency.Length == 0)
        {
            currency = "USD";
        }
        if (!Currency.IsMatch(currency))
        {
            throw new GoalError("Use a three-letter currency code, like USD or EUR", "goal_currency");
        }

        var before = existing.FirstOrDefault(g => g.Str("id") == id);
        double rounded = Js.Round(value * 100) / 100;
        return new JsObject
        {
            ["id"] = id ?? Hash.RandomId(),
            ["site"] = site,
            ["name"] = name,
            ["kind"] = kind,
            ["match"] = match,
            ["clickBy"] = clickBy,
            ["valueMode"] = valueMode,
            // One number type in JavaScript: a whole amount is a long here.
            ["value"] = Js.IsInteger(rounded) && Math.Abs(rounded) < Js.MaxSafeInteger ? (long)rounded : rounded,
            ["valueProp"] = valueProp,
            ["currency"] = currency,
            ["createdAt"] = before != null && before.Has("createdAt") && before.Get("createdAt") != null ? before.Get("createdAt") : now,
        };
    }

    /// <summary>
    /// Click rules for the tracker, keyed by site id and by each of the site's hostnames (or "*" for
    /// a site with none), so the script finds its own. One rule is [s for selector or h for a link,
    /// what to match, the event to send].
    /// </summary>
    public static JsObject ClickRules(IEnumerable<JsObject> sites, IReadOnlyList<JsObject> goals)
    {
        ArgumentNullException.ThrowIfNull(sites);
        ArgumentNullException.ThrowIfNull(goals);
        var output = new JsObject();
        foreach (var site in sites)
        {
            string siteId = site.Str("id") ?? "";
            var rules = new List<object?>();
            foreach (var g in goals)
            {
                if (g.Str("site") == siteId && g.Str("kind") == "click")
                {
                    rules.Add(new List<object?> { g.Str("clickBy") == "link" ? "h" : "s", g.Get("match"), g.Get("name") });
                }
            }
            if (rules.Count == 0)
            {
                continue;
            }
            output[siteId] = rules;
            var hostnames = site.Arr("hostnames") ?? [];
            foreach (object? host in hostnames.Count > 0 ? hostnames : ["*"])
            {
                string h = Js.String(host);
                output[h.StartsWith("www.", StringComparison.Ordinal) ? h[4..] : h] = rules;
            }
        }
        return output;
    }
}
