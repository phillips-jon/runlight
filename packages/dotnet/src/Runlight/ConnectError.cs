using System;

namespace Runlight;

/// <summary>
/// Why connecting failed, as a code the dashboard says in its own words. The first four (expired, denied, refused,
/// token) come back from the consent page, the rest (url, unreachable, not_runlight, endpoints, old, register) from
/// starting. TypeScript's is a RangeError.
/// </summary>
public sealed class ConnectError : Exception
{
    public ConnectError()
    {
    }

    public ConnectError(string message)
        : base(message)
    {
    }

    public ConnectError(string message, Exception inner)
        : base(message, inner)
    {
    }

    public ConnectError(string message, string code, JsObject? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? [];
    }

    /// <summary>The code, such as "expired".</summary>
    public string Code { get; } = "";

    /// <summary>What the message names, such as the url: string values, in the TypeScript's order.</summary>
    public JsObject Params { get; } = [];
}
