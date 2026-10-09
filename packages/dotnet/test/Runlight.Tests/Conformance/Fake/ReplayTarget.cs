using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Tests.ConformanceRunner.Fake;

/// <summary>
/// A stand-in for the .NET core that answers each step, deliberately, with the answer http.json expects
/// of it: placeholders filled with fresh values, ZIP files zipped, the requests to other servers made
/// through the runner's fetcher, and Set-Cookie lines with values for the jars. Replaying every scenario
/// through it proves the runner itself (normalizing, captures, jars, templates, ZIP reading, and the
/// fetched record) apart from the core.
///
/// It also checks what it is sent: the entry point, method, and URL each step names, no template left
/// unfilled, and nothing read from the environment.
/// </summary>
public sealed class ReplayTarget : ITarget
{
    private readonly List<JsObject> _steps;
    private readonly Denormalizer _values = new();
    private int _at;

    public ReplayTarget(JsObject scenario, PlayOptions options)
    {
        _steps = scenario.Arr("steps")!.Cast<JsObject>().ToList();
        Options = options;
        if (!options.Routes.Has("token"))
        {
            throw new InvalidOperationException("Routes() must be given the token, null included");
        }
    }

    public PlayOptions Options { get; }

    public int Idled { get; private set; }

    public List<Request> Requests { get; } = [];

    public async Task<Response> HandleAsync(Request request) => await AnswerAsync("routes", request) ?? throw new InvalidOperationException("The routes always answer");

    public async Task<Response> LinksAsync(Request request) => await AnswerAsync("links", request) ?? throw new InvalidOperationException("The link handler always answers");

    public Task<Response?> LinkDomainAsync(Request request) => AnswerAsync("linkDomain", request);

    public Task IdleAsync()
    {
        Idled++;
        return Task.CompletedTask;
    }

    private async Task<Response?> AnswerAsync(string to, Request request)
    {
        var step = _at < _steps.Count ? _steps[_at] : throw new InvalidOperationException("More requests than steps");
        _at++;
        Requests.Add(request);
        Check(step, to, request);
        var expect = step.Obj("expect")!;

        foreach (var fetched in (expect.Arr("fetched") ?? []).Cast<JsObject>())
        {
            await FetchAsync(fetched);
        }
        if (Js.Truthy(expect.Get("pass")))
        {
            return null;
        }
        var headers = new Headers();
        foreach (var (name, value) in expect.Obj("headers") ?? new JsObject())
        {
            if (name == "set-cookie")
            {
                foreach (object? line in (List<object?>)value!)
                {
                    headers.Append(name, _values.Cookie(Js.String(line)));
                }
            }
            else if (name == "content-type")
            {
                headers.Set(name, Js.String(value));
            }
            else
            {
                headers.Set(name, _values.Text(Js.String(value)));
            }
        }
        byte[] body;
        if (expect.Arr("files") is List<object?> files)
        {
            var list = files.Cast<JsObject>().Select(f => (f.Str("name")!, _values.Text(f.Str("text")!))).ToList();
            // Every other ZIP is stored rather than deflated, so both are read.
            body = TestZip.Zip(list, _at % 2 == 0);
        }
        else if (expect.Has("body"))
        {
            body = Js.Utf8(Json.Stringify(_values.Value(expect.Get("body"))));
        }
        else if (expect.Get("text") is string text)
        {
            body = Js.Utf8(_values.Text(text));
        }
        else if (expect.Arr("found") is List<object?> found)
        {
            // A page that holds the look strings found and none of the others, and is not JSON.
            var look = step.Arr("look")!;
            body = Js.Utf8("<!-- a page -->\n" + string.Join("\n", look.Where((s, i) => found[i] is true).Select(s => Js.String(s))));
        }
        else
        {
            body = [];
        }
        return new Response(body, (int)expect.Num("status"), headers);
    }

    private void Check(JsObject step, string to, Request request)
    {
        string where = $"step {_at} ({step.Str("method")} {step.Str("path")})";
        if ((step.Str("to") ?? "routes") != to)
        {
            throw new InvalidOperationException($"{where} went to {to}");
        }
        if (request.Method != step.Str("method")!.ToUpperInvariant())
        {
            throw new InvalidOperationException($"{where} was sent as {request.Method}");
        }
        string path = step.Str("path")!;
        if (!path.Contains("{{", StringComparison.Ordinal))
        {
            string prefix = to == "routes" && !Js.Truthy(step.Get("absolute")) ? "/runlight" : "";
            string url = new Url("https://" + (step.Str("host") ?? "example.com") + prefix + path).Href;
            if (request.Url != url)
            {
                throw new InvalidOperationException($"{where} was sent to {request.Url}");
            }
        }
        string sent = request.Url + "\n" + request.Text();
        foreach (var (_, value) in request.Headers)
        {
            sent += "\n" + value;
        }
        if (sent.Contains("{{", StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{where} still holds a template: {sent}");
        }
        foreach (string name in Player.Env)
        {
            if (global::Runlight.Env.Get(name) != null)
            {
                throw new InvalidOperationException($"{where} can read {name}");
            }
        }
        Options.Now();
    }

    /// <summary>Makes one of the requests the step expects, through the runner's fetcher, as the core would.</summary>
    private async Task FetchAsync(JsObject expected)
    {
        var fetched = (JsObject)_values.Value(expected)!;
        var headers = fetched.Obj("headers") ?? new JsObject();
        var init = new FetchInit { Method = fetched.Str("method")!, Headers = new Headers(headers.Select(e => new KeyValuePair<string, string>(e.Key, Js.String(e.Value)))) };
        if (fetched.Has("body"))
        {
            string type = headers.Str("content-type") ?? "";
            object? body = fetched.Get("body");
            init.BodyText = body switch
            {
                string s => s,
                JsObject o when type.StartsWith("application/x-www-form-urlencoded", StringComparison.Ordinal) =>
                    new SearchParams(o.Select(e => new KeyValuePair<string, string>(e.Key, Js.String(e.Value)))).ToString(),
                _ => Json.Stringify(body),
            };
        }
        try
        {
            (await Options.Fetcher.FetchAsync(fetched.Str("url")!, init)).Text();
        }
        catch (Exception error) when (error is FetchException or BodyTooLongException)
        {
            // A server that did not answer: the core carries on, as the TypeScript one did.
        }
    }
}
