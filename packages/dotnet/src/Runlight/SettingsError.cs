using System;

namespace Runlight;

/// <summary>
/// A setting refused, such as a site's domain or the assistant's service, as a code the dashboard
/// says in its own words. A RangeError in TypeScript.
/// </summary>
public class SettingsError : Exception
{
    public SettingsError()
        : this("", "")
    {
    }

    public SettingsError(string message)
        : this(message, "")
    {
    }

    public SettingsError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "";
        Params = [];
    }

    public SettingsError(string message, string code, JsObject? parameters = null)
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
