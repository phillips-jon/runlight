using System;

namespace Runlight;

/// <summary>Why a funnel was refused, as a code the dashboard says in its own words.</summary>
public sealed class FunnelError : Exception
{
    public FunnelError()
        : this("", "")
    {
    }

    public FunnelError(string message)
        : this(message, "")
    {
    }

    public FunnelError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "";
        Params = [];
    }

    public FunnelError(string message, string code, JsObject? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? [];
    }

    /// <summary>The code the dashboard says in its own words.</summary>
    public string Code { get; }

    /// <summary>The words that go into the message, each a string.</summary>
    public JsObject Params { get; }
}
