using System;

namespace Runlight;

/// <summary>Environment variables, trimmed, with an empty one read as unset.</summary>
public static class Env
{
    public static string? Get(string name)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        if (value == null)
        {
            return null;
        }
        value = value.Trim();
        return value.Length == 0 ? null : value;
    }
}

/// <summary>
/// The SDK's version and the HTTP API's, read from Assets/build.json, which
/// scripts/dotnet-assets.mts writes from the TypeScript SDK, so the two always report the same.
/// </summary>
public static class Version
{
    public static string Current => Assets.Build.Str("version")!;

    /// <summary>Bumped when the HTTP API changes shape, so the dashboard and the hub can tell.</summary>
    public static int Api => (int)Assets.Build.Num("apiVersion");
}

public static class Brand
{
    /// <summary>The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. A data: URL.</summary>
    public static string RunlightIcon => Assets.Build.Str("icon")!;
}
