using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Tests;

/// <summary>A request a fake fetcher saw.</summary>
public sealed record SeenRequest(string Url, string Method, JsObject Headers, string? Body, int TimeoutMs, FetchInit Init);

/// <summary>
/// An <see cref="IFetcher"/> that records each request and answers from a queue: a Response, or
/// "timeout" or "network" to fail, as packages/php/tests/RecordingFetcher.php does.
/// </summary>
public sealed class RecordingFetcher(params object[] queue) : IFetcher
{
    private readonly Queue<object> _queue = new(queue);

    public List<SeenRequest> Requests { get; } = [];

    public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        init ??= new FetchInit();
        Requests.Add(FakeFetcher.Seen(url, init));
        if (!_queue.TryDequeue(out object? next))
        {
            throw new InvalidOperationException("No canned answer left");
        }
        return next switch
        {
            "timeout" => throw new FetchException("The operation timed out", true),
            "network" => throw new FetchException("Could not connect"),
            Response r => Task.FromResult(r),
            _ => throw new InvalidOperationException("not an answer: " + next),
        };
    }
}

/// <summary>
/// An <see cref="IFetcher"/> that records every request and answers from a function, so a test can
/// require the exact method, URL, headers, and body a service is sent. Headers are recorded as the
/// TS fixtures record them: lowercase names in order, as iterating Fetch Headers gives them.
/// </summary>
public sealed class FakeFetcher(Func<string, FetchInit, Task<Response>> answer) : IFetcher
{
    public FakeFetcher(Func<string, FetchInit, Response> answer)
        : this((url, init) => Task.FromResult(answer(url, init)))
    {
    }

    public List<SeenRequest> Requests { get; } = [];

    public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        init ??= new FetchInit();
        Requests.Add(Seen(url, init));
        return answer(url, init);
    }

    internal static SeenRequest Seen(string url, FetchInit init)
    {
        var headers = new JsObject();
        foreach (var (name, value) in init.Headers)
        {
            headers[name] = value;
        }
        return new SeenRequest(url, init.Method, headers, init.BodyText, init.TimeoutMs, init);
    }
}
