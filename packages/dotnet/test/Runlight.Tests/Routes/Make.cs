using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Routes;

/// <summary>
/// What the route tests share, as the PHP's tests/Routes/Make.php: a Runlight on an in-memory SQLite unless a store
/// is given, and requests written as the TypeScript tests write them.
/// </summary>
public static class Make
{
    /// <summary>A Runlight with these options and an in-memory SQLite unless a store is given.</summary>
    public static async Task<Runlight> RunlightAsync(
        SiteOptions? site = null,
        IReadOnlyList<SiteOptions>? sites = null,
        bool managedSites = false,
        Func<long>? now = null,
        IFetcher? fetcher = null,
        string? secret = null,
        SqlStore? store = null,
        bool localInstalls = false) => new(new RunlightOptions
        {
            Store = store ?? await Databases.FreshAsync("sqlite"),
            Site = site,
            Sites = sites,
            ManagedSites = managedSites,
            Now = now,
            Fetcher = fetcher,
            Secret = secret,
            LocalInstalls = localInstalls,
        });

    /// <summary>A site in code.</summary>
    public static SiteOptions Site(string? id = null, string? name = null, string[]? hostnames = null, string? timezone = null) =>
        new() { Id = id, Name = name, Hostnames = hostnames, Timezone = timezone };

    /// <summary>Headers from pairs.</summary>
    public static Headers H(params (string Name, string Value)[] pairs)
    {
        var headers = new Headers();
        foreach (var (name, value) in pairs)
        {
            headers.Set(name, value);
        }
        return headers;
    }

    /// <summary>A request to https://example.com, with JavaScript's content type on a string body sent with none.</summary>
    public static Request Req(string path, string method = "GET", Headers? headers = null, string? body = null) => At("https://example.com" + path, method, headers, body);

    /// <summary>A request to a whole URL, with JavaScript's content type on a string body sent with none.</summary>
    public static Request At(string url, string method = "GET", Headers? headers = null, string? body = null)
    {
        headers = headers == null ? new Headers() : new Headers(headers);
        if (body != null && !headers.Has("content-type"))
        {
            headers.Set("content-type", "text/plain;charset=UTF-8");
        }
        return new Request(url, method, headers, body ?? "");
    }

    /// <summary>A JSON request with a bearer token, as the tests' owner sends it.</summary>
    public static Request Owner(string path, string method = "GET", object? body = null, string token = "secret")
    {
        var headers = H(("authorization", "Bearer " + token));
        if (body != null)
        {
            headers.Set("content-type", "application/json");
        }
        return Req(path, method, headers, body == null ? null : Json.Stringify(body));
    }

    /// <summary>The answer's body as JSON.</summary>
    public static object? Body(Response response) => Json.Parse(response.Text());

    /// <summary>The answer's body as a JSON object.</summary>
    public static JsObject Obj(Response response) => (JsObject)Body(response)!;

    /// <summary>A list from items, for JSON bodies.</summary>
    public static List<object?> L(params object?[] items) => [.. items];

    /// <summary>A field of each object in a list.</summary>
    public static List<object?> Column(object? list, string key) => ((List<object?>)list!).Select(o => ((JsObject)o!).Get(key)).ToList();
}

/// <summary>
/// Clears the environment variables the routes read (RUNLIGHT_TOKEN, RUNLIGHT_SECRET, CRON_SECRET,
/// RUNLIGHT_OBSERVE_KEY, NODE_ENV) for a test and puts them back after, as the PHP's Player::clearEnv does.
/// </summary>
public abstract class RoutesTestCase : IAsyncLifetime
{
    private static readonly string[] Names = ["RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV"];
    private readonly Dictionary<string, string?> _saved = [];

    public virtual ValueTask InitializeAsync()
    {
        foreach (string name in Names)
        {
            _saved[name] = Environment.GetEnvironmentVariable(name);
            Environment.SetEnvironmentVariable(name, null);
        }
        return ValueTask.CompletedTask;
    }

    public virtual async ValueTask DisposeAsync()
    {
        foreach (var (name, value) in _saved)
        {
            Environment.SetEnvironmentVariable(name, value);
        }
        await Databases.CleanupAsync();
    }

    /// <summary>Date.UTC with months counted from 1.</summary>
    protected static long Utc(int y, int m, int d, int h = 0, int i = 0, int s = 0) => Time.Utc(y, m - 1, d, h, i, s);
}
