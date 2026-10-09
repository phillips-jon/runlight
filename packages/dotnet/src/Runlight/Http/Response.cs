using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Http;

/// <summary>
/// An answer, shaped like the Fetch API's Response. The body is bytes, or a writer that streams
/// its parts for answers too long to hold at once.
/// </summary>
public sealed class Response
{
    private byte[]? _body;
    private Func<Stream, CancellationToken, Task>? _stream;

    public Response(byte[] body, int status = 200, Headers? headers = null)
    {
        _body = body;
        Status = status;
        Headers = headers == null ? new Headers() : new Headers(headers);
    }

    public Response(string body = "", int status = 200, Headers? headers = null)
        : this(Js.Utf8(body), status, headers)
    {
    }

    /// <summary>A streamed answer: the writer is called once with the stream to write to.</summary>
    public Response(Func<Stream, CancellationToken, Task> stream, int status = 200, Headers? headers = null)
    {
        _stream = stream;
        Status = status;
        Headers = headers == null ? new Headers() : new Headers(headers);
    }

    public int Status { get; }

    public Headers Headers { get; }

    public static Response JsonOf(object? data, int status = 200, Headers? headers = null)
    {
        var h = new Headers { ["content-type"] = "application/json" };
        if (headers != null)
        {
            foreach (var e in headers.All())
            {
                if (!h.Has(e.Key))
                {
                    foreach (string v in e.Value)
                    {
                        h.Append(e.Key, v);
                    }
                }
            }
        }
        return new Response(Runlight.Json.Stringify(data), status, h);
    }

    public static Response Redirect(string location, int status = 302) =>
        new("", status, new Headers { ["location"] = location });

    public bool Ok => Status >= 200 && Status < 300;

    public bool Streamed => _stream != null;

    /// <summary>The whole body; a streamed body is run and captured.</summary>
    public async Task<byte[]> BytesAsync(CancellationToken cancellationToken = default)
    {
        if (_body != null)
        {
            return _body;
        }
        using var buffer = new MemoryStream();
        await _stream!(buffer, cancellationToken).ConfigureAwait(false);
        _body = buffer.ToArray();
        _stream = null;
        return _body;
    }

    /// <summary>The whole body as text.</summary>
    public async Task<string> TextAsync(CancellationToken cancellationToken = default) =>
        Js.Decode(await BytesAsync(cancellationToken).ConfigureAwait(false));

    /// <summary>The body as text when it is held, not streamed.</summary>
    public string Text() => _body != null ? Js.Decode(_body) : throw new InvalidOperationException("a streamed body is read with TextAsync");

    /// <summary>The body's bytes when they are held, not streamed.</summary>
    public byte[] Bytes() => _body ?? throw new InvalidOperationException("a streamed body is read with BytesAsync");

    /// <summary>Writes the body to a stream: the bytes, or the streamed writer.</summary>
    public async Task WriteToAsync(Stream output, CancellationToken cancellationToken = default)
    {
        if (_body != null)
        {
            await output.WriteAsync(_body, cancellationToken).ConfigureAwait(false);
            return;
        }
        var stream = _stream!;
        _stream = null;
        await stream(output, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Header pairs as they are sent: each value of each name, Set-Cookie ones apart.</summary>
    public IEnumerable<KeyValuePair<string, string>> HeaderLines()
    {
        foreach (var e in Headers.All())
        {
            if (e.Key == "set-cookie")
            {
                foreach (string v in e.Value)
                {
                    yield return new(e.Key, v);
                }
            }
            else
            {
                yield return new(e.Key, string.Join(", ", e.Value));
            }
        }
    }
}
