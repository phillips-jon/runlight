namespace Runlight.Http;

/// <summary>
/// An incoming request, shaped like the Fetch API's Request so the routes read the same as the
/// TypeScript SDK's: an absolute URL, a method, headers, and a body read as text or JSON.
/// </summary>
public sealed class Request
{
    private readonly byte[] _body;

    public Request(string url, string method = "GET", Headers? headers = null, byte[]? body = null, string remoteAddress = "")
    {
        Url = url;
        Method = method.ToUpperInvariant();
        Headers = headers == null ? new Headers() : new Headers(headers);
        _body = body ?? [];
        RemoteAddress = remoteAddress;
    }

    public Request(string url, string method, Headers? headers, string body, string remoteAddress = "")
        : this(url, method, headers, Js.Utf8(body), remoteAddress)
    {
    }

    public string Url { get; }

    public string Method { get; }

    public Headers Headers { get; }

    /// <summary>The address the request came from, before any proxy header is read.</summary>
    public string RemoteAddress { get; }

    /// <summary>The body's bytes.</summary>
    public byte[] Bytes() => _body;

    /// <summary>The body as text, bytes that are not UTF-8 read as U+FFFD.</summary>
    public string Text() => Js.Decode(_body);

    /// <summary>The body as JSON. Throws <see cref="JsonParseException"/> when it is not.</summary>
    public object? Json() => Runlight.Json.Parse(Text());

    public Url ParsedUrl() => new(Url);

    /// <summary>The same request with other parts, as <c>new Request(request, init)</c> makes one.</summary>
    public Request With(string? url = null, string? method = null, Headers? headers = null, byte[]? body = null) =>
        new(url ?? Url, method ?? Method, headers ?? Headers, body ?? _body, RemoteAddress);
}
