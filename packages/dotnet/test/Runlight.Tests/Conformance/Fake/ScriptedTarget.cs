using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Tests.ConformanceRunner.Fake;

/// <summary>A target that hands each request to the next function in a script, for tests that look at exactly what the runner sends.</summary>
public sealed class ScriptedTarget(IEnumerable<Func<Request, string, Task<Response?>>> script) : ITarget
{
    private readonly Queue<Func<Request, string, Task<Response?>>> _script = new(script);

    public List<(string To, Request Request)> Seen { get; } = [];

    public int Idled { get; private set; }

    public async Task<Response> HandleAsync(Request request) => await NextAsync("routes", request) ?? new Response("", 404);

    public async Task<Response> LinksAsync(Request request) => await NextAsync("links", request) ?? new Response("", 404);

    public Task<Response?> LinkDomainAsync(Request request) => NextAsync("linkDomain", request);

    public Task IdleAsync()
    {
        Idled++;
        return Task.CompletedTask;
    }

    private Task<Response?> NextAsync(string to, Request request)
    {
        Seen.Add((to, request));
        var step = _script.Count > 0 ? _script.Dequeue() : throw new InvalidOperationException("The script ran out");
        return step(request, to);
    }
}
