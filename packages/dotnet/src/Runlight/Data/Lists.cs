using System.Collections.Generic;
using System.Linq;

namespace Runlight.Data;

/// <summary>
/// The SDK's data lists, read from Assets/data.json, which scripts/dotnet-assets.mts writes from
/// packages/sdk/src/data, so every implementation reads the same lists.
/// </summary>
public static class Lists
{
    private static readonly JsObject Data = (JsObject)Json.Parse(Assets.Text("data.json"))!;

    /// <summary>
    /// AI agents, matched on the user agent, checked before the bot test so they are recorded as
    /// fetches rather than dropped. Each is { name, company, kind ("live" or "crawl"), token }; the
    /// token is matched case-insensitively as a substring of the user agent.
    /// </summary>
    public static IReadOnlyList<JsObject> AiAgents { get; } = [.. Data.Arr("aiAgents")!.Cast<JsObject>()];

    /// <summary>Anything that is clearly not a person in a browser.</summary>
    public static JsPattern BotPattern { get; } = Pattern(Data.Obj("botPattern")!);

    /// <summary>
    /// Known traffic sources, each { name, kind, hosts, aliases? }: hosts match a referrer host or any
    /// subdomain of it, aliases a lowercased utm_source, ref, or source parameter.
    /// </summary>
    public static IReadOnlyList<JsObject> Sources { get; } = [.. Data.Arr("sources")!.Cast<JsObject>()];

    /// <summary>Hosts known by their shape rather than their name, each { pattern, name (or null), kind }.</summary>
    public static IReadOnlyList<(JsPattern Pattern, string? Name, string Kind)> SourcePatterns { get; } =
        [.. Data.Arr("sourcePatterns")!.Cast<JsObject>().Select(o => (Pattern(o), o.Str("name"), o.Str("kind")!))];

    private static JsPattern Pattern(JsObject o) => new(o.Str("source")!, o.Str("flags") ?? "");
}
