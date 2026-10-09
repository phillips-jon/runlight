using System;

namespace Runlight;

/// <summary>Why a goal was refused, as a code the dashboard says in its own words.</summary>
public sealed class GoalError : Exception
{
    public GoalError()
        : this("", "")
    {
    }

    public GoalError(string message)
        : this(message, "")
    {
    }

    public GoalError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "";
        Params = [];
    }

    public GoalError(string message, string code, JsObject? parameters = null)
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
