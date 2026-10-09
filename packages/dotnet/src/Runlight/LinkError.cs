using System;

namespace Runlight;

/// <summary>
/// A link that cannot be made. <see cref="Code"/> and <see cref="Params"/> let the dashboard say it
/// in its own language.
/// </summary>
public class LinkError : Exception
{
    public LinkError()
        : this("", "")
    {
    }

    public LinkError(string message)
        : this(message, "")
    {
    }

    public LinkError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "";
        Params = [];
    }

    public LinkError(string message, string code, JsObject? parameters = null)
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
