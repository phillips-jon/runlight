using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Http;

/// <summary>What fetch's init holds, where it applies.</summary>
public sealed class FetchInit
{
    public string Method { get; set; } = "GET";

    public Headers Headers { get; set; } = new();

    public byte[]? Body { get; set; }

    /// <summary>The body as text, written as UTF-8.</summary>
    public string? BodyText
    {
        get => Body == null ? null : Js.Decode(Body);
        set => Body = value == null ? null : Js.Utf8(value);
    }

    /// <summary>"follow" (the default) or "manual", which hands back the 3xx answer.</summary>
    public string Redirect { get; set; } = "follow";

    /// <summary>The whole request's limit.</summary>
    public int TimeoutMs { get; set; } = 30_000;

    /// <summary>Stop reading past this and throw <see cref="BodyTooLongException"/>.</summary>
    public long? MaxBytes { get; set; }

    /// <summary>With MaxBytes, hand back the first MaxBytes instead of throwing (the start of a page).</summary>
    public bool Truncate { get; set; }

    /// <summary>"host:port:address" pins, so a checked address is the one connected to.</summary>
    public List<string> Resolve { get; set; } = [];
}

/// <summary>
/// Outgoing requests, the .NET stand-in for JavaScript's fetch(). Everything that calls another
/// server (mail services, importers, connected installs, the assistant's providers, site icons)
/// goes through one, so tests can pass a fake.
/// </summary>
public interface IFetcher
{
    /// <exception cref="FetchException">When no answer comes back (refused, timed out, bad TLS).</exception>
    Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default);
}

/// <summary>No answer came back: refused, timed out, or bad TLS.</summary>
public class FetchException : Exception
{
    public FetchException()
    {
    }

    public FetchException(string message)
        : base(message)
    {
    }

    public FetchException(string message, Exception inner)
        : base(message, inner)
    {
    }

    public FetchException(string message, bool timedOut, Exception? inner = null)
        : base(message, inner)
    {
        TimedOut = timedOut;
    }

    public bool TimedOut { get; }
}

/// <summary>An answer's body ran past the limit asked for.</summary>
public sealed class BodyTooLongException : Exception
{
    public BodyTooLongException()
    {
    }

    public BodyTooLongException(string message)
        : base(message)
    {
    }

    public BodyTooLongException(string message, Exception inner)
        : base(message, inner)
    {
    }
}
