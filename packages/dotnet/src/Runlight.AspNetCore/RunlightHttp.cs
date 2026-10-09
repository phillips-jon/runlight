using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Runlight.Http;
using Runlight.Server;
using RunlightInstance = Runlight.Runlight;

namespace Runlight.AspNetCore;

/// <summary>A request body past its limit, answered with 413 rather than passed on empty.</summary>
public sealed class BodyTooLargeException : Exception
{
    /// <summary>A body past its limit.</summary>
    public BodyTooLargeException()
    {
    }

    /// <summary>A body past its limit, with what it was.</summary>
    public BodyTooLargeException(string message)
        : base(message)
    {
    }

    /// <summary>A body past its limit, with what it was and the error behind it.</summary>
    public BodyTooLargeException(string message, Exception inner)
        : base(message, inner)
    {
    }
}

/// <summary>
/// What the Node adapter (@runlight/sdk/node) does, for ASP.NET Core: an <see cref="HttpContext"/> as Runlight's
/// <see cref="Request"/>, and Runlight's <see cref="Response"/> written back, streamed as it comes. The endpoint
/// mapping and the middleware are built on these, and an app that routes requests its own way can call
/// <see cref="ServeAsync(HttpContext, RunlightInstance, Routes)"/> from any endpoint or middleware.
/// </summary>
public static class RunlightHttp
{
    /// <summary>The collect endpoint's limit; its payloads are under 8 KB.</summary>
    public const int MaxCollectBody = 16 * 1024;

    /// <summary>Everything else, such as a link import of 5,000 rows.</summary>
    public const int MaxBody = 10 * 1024 * 1024;

    /// <summary>
    /// Answers a request as the front controller answers it (a link domain, then <c>{linkPath}/{slug}</c>, then
    /// the routes), and runs the Runlight's <see cref="RunlightInstance.IdleAsync"/> once the answer is sent.
    /// </summary>
    public static Task ServeAsync(HttpContext context, RunlightInstance runlight, Routes routes)
    {
        ArgumentNullException.ThrowIfNull(runlight);
        ArgumentNullException.ThrowIfNull(routes);
        return ServeAsync(context, (request, ip, ct) => FrontController.AnswerAsync(runlight, routes, request, ip, ct), runlight.IdleAsync);
    }

    /// <summary>
    /// Answers a request through <paramref name="handler"/>, with the connection's address as its ip, then runs
    /// <paramref name="idle"/> once the response has been sent, for the work TS does after answering. A body
    /// past its limit is a 413; a client that goes away is answered nothing.
    /// </summary>
    public static async Task ServeAsync(HttpContext context, RequestHandler handler, Func<Task>? idle = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(handler);
        CancellationToken aborted = context.RequestAborted;
        if (idle != null)
        {
            // The visitor has the answer by then; whatever is left runs without keeping them waiting.
            context.Response.OnCompleted(() => idle());
        }
        Request request;
        try
        {
            request = await ToRequestAsync(context, aborted).ConfigureAwait(false);
        }
        catch (BodyTooLargeException)
        {
            // An upload cut off part way leaves the connection unfit for another request, so it closes.
            await WriteAsync(context, TooLarge(), aborted).ConfigureAwait(false);
            return;
        }
        catch (Exception e) when (aborted.IsCancellationRequested && e is OperationCanceledException or IOException)
        {
            return;
        }
        Response answer;
        try
        {
            answer = await handler(request, request.RemoteAddress, aborted).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (aborted.IsCancellationRequested)
        {
            return;
        }
        await WriteAsync(context, answer, aborted).ConfigureAwait(false);
    }

    /// <summary>The 413 the Node adapter answers for a body past its limit.</summary>
    public static Response TooLarge() =>
        new(Json.Stringify(new JsObject { ["error"] = "That request is too large" }), 413, new Headers { ["content-type"] = "application/json", ["connection"] = "close" });

    /// <summary>
    /// The request as Runlight's: the target as sent (not ASP.NET Core's decoded path), the scheme from
    /// <c>X-Forwarded-Proto</c> or the connection, the <c>Host</c> header, every header lowercased, the body
    /// (read here, up to its limit, for any method but GET and HEAD), and the connection's address.
    /// </summary>
    /// <exception cref="BodyTooLargeException">When the body runs past its limit.</exception>
    public static async Task<Request> ToRequestAsync(HttpContext context, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        HttpRequest http = context.Request;
        string method = http.Method.ToUpperInvariant();
        var headers = HeadersOf(http);
        string target = TargetOf(context);
        byte[]? body = null;
        if (method is not ("GET" or "HEAD"))
        {
            string path = target.Split('?')[0];
            body = await ReadBodyAsync(context, path.EndsWith("/e", StringComparison.Ordinal) ? MaxCollectBody : MaxBody, cancellationToken).ConfigureAwait(false);
            // A fetch Request made with a text body and no type says it is text, as the routes expect.
            if (!headers.Has("content-type"))
            {
                headers.Set("content-type", "text/plain;charset=UTF-8");
            }
        }
        return new Request(UrlOf(http, headers, target), method, headers, body, AddressOf(context));
    }

    /// <summary>The request's headers and address with no body, for deciding whether a request is Runlight's.</summary>
    internal static Request HeadOf(HttpContext context)
    {
        HttpRequest http = context.Request;
        var headers = HeadersOf(http);
        return new Request(UrlOf(http, headers, TargetOf(context)), http.Method, headers, (byte[]?)null, AddressOf(context));
    }

    private static Headers HeadersOf(HttpRequest http)
    {
        var headers = new Headers();
        foreach (var h in http.Headers)
        {
            if (h.Key.StartsWith(':'))
            {
                continue;
            }
            foreach (string? v in h.Value)
            {
                headers.Append(h.Key, v ?? "");
            }
        }
        return headers;
    }

    /// <summary>The request target as sent, which keeps its percent-encoding and dot segments.</summary>
    private static string TargetOf(HttpContext context)
    {
        HttpRequest http = context.Request;
        return context.Features.Get<IHttpRequestFeature>()?.RawTarget is { Length: > 0 } raw && raw[0] == '/'
            ? raw
            : (http.PathBase + http.Path).ToUriComponent() + http.QueryString.ToUriComponent();
    }

    private static string UrlOf(HttpRequest http, Headers headers, string target)
    {
        string proto = Js.Lower(Js.Trim((headers.Get("x-forwarded-proto") ?? "").Split(',')[0]));
        if (proto.Length == 0)
        {
            proto = http.IsHttps ? "https" : "http";
        }
        string host = headers.Get("host") ?? "localhost";
        return Url.Parse(target.StartsWith('/') ? target : "/" + target, (proto == "https" ? "https" : "http") + "://" + host)?.Href ?? "http://localhost/";
    }

    /// <summary>The connection's address, an IPv4 address that arrived on an IPv6 socket written as IPv4.</summary>
    private static string AddressOf(HttpContext context)
    {
        IPAddress? address = context.Connection.RemoteIpAddress;
        if (address == null)
        {
            return "";
        }
        return (address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address).ToString();
    }

    /// <summary>
    /// Reads the body, at most <paramref name="limit"/> bytes. A form something ahead of Runlight already read
    /// (<c>ReadFormAsync</c>, <c>Request.Form</c>) leaves nothing to read, and is then taken from the parsed form.
    /// </summary>
    private static async Task<byte[]> ReadBodyAsync(HttpContext context, int limit, CancellationToken cancellationToken)
    {
        HttpRequest http = context.Request;
        if (http.ContentLength > limit)
        {
            throw new BodyTooLargeException("Request body over " + limit.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes");
        }
        using var buffer = new MemoryStream();
        byte[] chunk = new byte[16 * 1024];
        Stream body = http.Body;
        while (true)
        {
            int n = await body.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
            if (n == 0)
            {
                break;
            }
            buffer.Write(chunk, 0, n);
            if (buffer.Length > limit)
            {
                throw new BodyTooLargeException("Request body over " + limit.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes");
            }
        }
        if (buffer.Length == 0 && context.Features.Get<IFormFeature>()?.Form is { } form)
        {
            var fields = new List<KeyValuePair<string, string>>();
            foreach (var f in form)
            {
                foreach (string? v in f.Value)
                {
                    fields.Add(new(f.Key, v ?? ""));
                }
            }
            return Js.Utf8(new SearchParams(fields).ToString());
        }
        return buffer.ToArray();
    }

    /// <summary>
    /// Writes an answer: its status and headers, each Set-Cookie on its own, then the body. A body held whole is
    /// sent with its length; a streamed one goes out as it is written, only as fast as the client takes it. A body
    /// that fails before its first byte is a plain 500, and one that fails part way cuts the connection, rather
    /// than leave a short answer that looks whole.
    /// </summary>
    public static async Task WriteAsync(HttpContext context, Response answer, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(answer);
        HttpResponse response = context.Response;
        bool head = HttpMethods.IsHead(context.Request.Method);
        bool bodiless = answer.Status is (>= 100 and < 200) or 204 or 304;
        try
        {
            response.StatusCode = answer.Status;
            foreach (var (name, value) in answer.HeaderLines())
            {
                if (name is "content-length" or "transfer-encoding")
                {
                    continue;
                }
                response.Headers.Append(name, value);
            }
            if (!answer.Streamed)
            {
                byte[] bytes = answer.Bytes();
                if (!bodiless)
                {
                    response.ContentLength = bytes.Length;
                }
                if (bytes.Length > 0 && !head && !bodiless)
                {
                    await response.Body.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                }
                return;
            }
            if (head || bodiless)
            {
                return;
            }
            await answer.WriteToAsync(response.Body, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (cancellationToken.IsCancellationRequested && e is OperationCanceledException or IOException)
        {
            // The client went away before its answer was written: nothing to report.
        }
        catch (Exception e)
        {
            if (response.HasStarted)
            {
                context.Abort();
                return;
            }
            await Console.Error.WriteLineAsync("Runlight: " + e.Message).ConfigureAwait(false);
            response.Clear();
            response.StatusCode = 500;
        }
    }
}
