using System;

namespace Runlight;

/// <summary>
/// What went wrong with the assistant, as a code the dashboard says in its own words; a service's own text goes
/// in <c>Params["detail"]</c>.
/// </summary>
public sealed class AssistantError : Exception
{
    public AssistantError()
    {
    }

    public AssistantError(string message)
        : base(message)
    {
    }

    public AssistantError(string message, Exception inner)
        : base(message, inner)
    {
    }

    public AssistantError(string message, string code, JsObject? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? [];
    }

    /// <summary>The code, such as "assistant_slow".</summary>
    public string Code { get; } = "";

    /// <summary>What the message names, such as the host: string values, in the TypeScript's order.</summary>
    public JsObject Params { get; } = [];
}
