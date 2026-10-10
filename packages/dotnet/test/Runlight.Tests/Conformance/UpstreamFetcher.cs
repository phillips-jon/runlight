using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>A request the core sent another server: its normalizable record, and the body's text for captures.</summary>
public sealed record Fetched(JsObject Seen, string Text);

/// <summary>
/// The servers a scenario stands in for, as the fake fetch in http-conformance.ts plays them: a
/// request goes to the first upstream whose url its URL starts with (and whose method matches, when
/// one is given); a request none matches fails as a network error does. Every request is recorded,
/// matched or not.
/// </summary>
public sealed class UpstreamFetcher(IReadOnlyList<JsObject> upstream) : IFetcher
{
    /// <summary>The servers stood in for are on the public internet, wherever their names point.</summary>
    public Task<IReadOnlyList<string>> LookupAsync(string name) => Task.FromResult<IReadOnlyList<string>>(["93.184.215.14"]);

    private readonly object _lock = new();
    private List<Fetched> _fetched = [];

    public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        init ??= new FetchInit();
        string method = (init.Method ?? "GET").ToUpperInvariant();
        var given = new JsObject();
        foreach (var (name, value) in init.Headers.OrderBy(e => e.Key, StringComparer.Ordinal))
        {
            given[name] = value;
        }
        string text = init.BodyText ?? "";
        var seen = new JsObject { ["method"] = method, ["url"] = url };
        if (!given.IsEmpty)
        {
            seen["headers"] = given;
        }
        if (text.Length > 0)
        {
            seen["body"] = SentBody(text, given.Str("content-type") ?? "");
        }
        lock (_lock)
        {
            _fetched.Add(new Fetched(seen, text));
        }

        var match = upstream.FirstOrDefault(u =>
            url.StartsWith(u.Str("url") ?? "", StringComparison.Ordinal) && (!Js.Truthy(u.Get("method")) || u.Str("method") == method));
        if (match == null)
        {
            throw new FetchException("fetch failed");
        }
        bool hasBody = match.Has("body");
        object? given2 = match.Get("body");
        string body = !hasBody ? "" : given2 is string s ? s : Json.Stringify(given2);
        // typeof null is "object" too, so a null body is sent as JSON.
        var pairs = new OrderedDictionary<string, string>(StringComparer.Ordinal);
        if (hasBody && given2 is not (string or double or long or bool))
        {
            pairs["content-type"] = "application/json";
        }
        foreach (var (name, value) in match.Obj("headers") ?? new JsObject())
        {
            pairs[name] = Js.String(value);
        }
        var headers = new Headers(pairs);
        byte[] bytes = Js.Utf8(body);
        // The cap a real fetcher keeps, so code that reads only the start of a page sees what it would.
        if (init.MaxBytes is long maxBytes && bytes.LongLength > maxBytes)
        {
            if (!init.Truncate)
            {
                throw new BodyTooLongException("Body over " + maxBytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes");
            }
            bytes = bytes[..(int)maxBytes];
        }
        int status = match.Has("status") ? (int)match.Num("status") : 200;
        return Task.FromResult(new Response(bytes, status, headers));
    }

    /// <summary>The requests made since the last take, and forgets them.</summary>
    public List<Fetched> Take()
    {
        lock (_lock)
        {
            var output = _fetched;
            _fetched = [];
            return output;
        }
    }

    /// <summary>A body another server was sent, as JSON or form fields when it is one of those, else its text.</summary>
    public static object? SentBody(string text, string type)
    {
        if (type.StartsWith("application/x-www-form-urlencoded", StringComparison.Ordinal))
        {
            var fields = new JsObject();
            foreach (var (name, value) in new SearchParams(text))
            {
                fields[name] = value;
            }
            return fields;
        }
        return Json.TryParse(text, out object? parsed) ? parsed : text;
    }
}
