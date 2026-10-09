using System;

namespace Runlight.Mail;

/// <summary>
/// A mail problem to show the person setting it up. <see cref="Code"/> and <see cref="Params"/> let
/// the dashboard say it in its own language; a service's own words, which only it can give, travel
/// in <c>Params.detail</c>.
/// </summary>
public class MailError : Exception
{
    public MailError()
        : this("Mail failed")
    {
    }

    public MailError(string message)
        : this(message, "mail_failed")
    {
    }

    public MailError(string message, Exception inner)
        : base(message, inner)
    {
        Code = "mail_failed";
        Params = new JsObject { ["detail"] = message };
    }

    /// <param name="message">The English text.</param>
    /// <param name="code">The string code the dashboard translates.</param>
    /// <param name="parameters">String values for the code; null means <c>{ detail: message }</c>, as the TS default.</param>
    public MailError(string message, string code, JsObject? parameters = null)
        : base(message)
    {
        Code = code;
        Params = parameters ?? new JsObject { ["detail"] = message };
    }

    /// <summary>The string code, as TS's <c>code</c>.</summary>
    public string Code { get; }

    /// <summary>String values the code is said with, as TS's <c>params</c>.</summary>
    public JsObject Params { get; }
}
