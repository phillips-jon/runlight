using System;

namespace Runlight.Importers;

/// <summary>A service answered with a status that is not success.</summary>
public sealed class HttpError : ImportError
{
    public HttpError()
    {
    }

    public HttpError(string message)
        : base(message)
    {
    }

    public HttpError(string message, Exception inner)
        : base(message, inner)
    {
    }

    /// <param name="message">The English text.</param>
    /// <param name="status">The HTTP status the service answered with.</param>
    /// <param name="code">The string code the dashboard translates.</param>
    /// <param name="parameters">String values for the code; none when null.</param>
    public HttpError(string message, int status, string code, JsObject? parameters = null)
        : base(message, code, parameters)
    {
        Status = status;
    }

    /// <summary>The HTTP status.</summary>
    public int Status { get; }
}
