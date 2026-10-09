using System;
using System.Collections.Generic;

namespace Runlight.Accounts;

/// <summary>
/// A problem with an account change, to show the person making it. A RangeError in TypeScript, with a
/// <see cref="Code"/> and <see cref="Params"/> the dashboard words in its own language.
/// </summary>
public class AccountError : Exception
{
    public AccountError(string message, string code, IReadOnlyDictionary<string, string>? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? new Dictionary<string, string>(StringComparer.Ordinal);
    }

    public AccountError()
        : this("Account error", "account_error")
    {
    }

    public AccountError(string message)
        : this(message, "account_error")
    {
    }

    public AccountError(string message, Exception innerException)
        : base(message, innerException)
    {
        Code = "account_error";
        Params = new Dictionary<string, string>(StringComparer.Ordinal);
    }

    /// <summary>The string code, as TypeScript has it.</summary>
    public string Code { get; }

    /// <summary>The values the message names, in the order they were given.</summary>
    public IReadOnlyDictionary<string, string> Params { get; }

    /// <summary>The params as a JSON object, keys in the order they were given.</summary>
    public JsObject ParamsObject()
    {
        var o = new JsObject();
        foreach (var e in Params)
        {
            o.Set(e.Key, e.Value);
        }
        return o;
    }
}
