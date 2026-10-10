using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Core;

/// <summary>Tests of the Runlight core that run on every database at hand (see <see cref="Databases"/>).</summary>
public abstract class CoreTestCase : IAsyncLifetime
{
    public const long DAY = Harness.DAY;
    public const long HOUR = Harness.HOUR;
    public const long MIN = Harness.MIN;

    public virtual ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public virtual async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    /// <summary>Date.UTC with months counted from 1.</summary>
    protected static long Utc(int y, int m, int d, int h = 0, int i = 0, int s = 0) => Time.Utc(y, m - 1, d, h, i, s);

    /// <summary>Date.parse of an ISO time.</summary>
    protected static long At(string iso) => DateTimeOffset.Parse(iso, System.Globalization.CultureInfo.InvariantCulture).ToUnixTimeMilliseconds();

    /// <summary>JSON with every object's keys sorted, to compare as PHPUnit's assertEquals does, where key order does not count.</summary>
    protected static string Loose(object? value) => Json.Stringify(Sort(value));

    private static object? Sort(object? value) => value switch
    {
        JsObject o => JsObject.From(o.OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => new KeyValuePair<string, object?>(e.Key, Sort(e.Value)))),
        List<object?> list => list.Select(Sort).ToList(),
        System.Collections.IEnumerable items and not string => items.Cast<object?>().Select(Sort).ToList(),
        _ => value,
    };

    /// <summary>The SettingsError (or other error) a call throws.</summary>
    protected static async Task<T> Refused<T>(Func<Task> fn, string code)
        where T : Exception
    {
        var e = await Assert.ThrowsAsync<T>(fn);
        Assert.Equal(code, (string)e.GetType().GetProperty("Code")!.GetValue(e)!);
        return e;
    }
}

/// <summary>
/// A Runlight on a fresh database with a clock the test moves, as helpers.ts's setup() is. Tracker hits go
/// straight to CollectAsync, and reports are read from the store, so nothing here needs the routes.
/// </summary>
public sealed class Harness
{
    public const string ChromeMac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
    public const string SafariIphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    public const long DAY = 86_400_000;
    public const long HOUR = 3_600_000;
    public const long MIN = 60_000;

    /// <summary>Date.UTC(2026, 9, 6, 12), where the TS tests start the clock.</summary>
    public const long START = 1_791_288_000_000;

    private Harness(Runlight rl) => Rl = rl;

    public Runlight Rl { get; private set; }

    public long Now { get; set; } = START;

    /// <summary>A Runlight on a fresh store of a kind, with the options given.</summary>
    public static async Task<Harness> CreateAsync(string kind, SiteOptions? site = null, IReadOnlyList<SiteOptions>? sites = null, bool managedSites = false, IFetcher? fetcher = null, string? secret = null, Func<string, JsObject?>? geo = null, double? rateLimit = 120) =>
        Create(await Databases.FreshAsync(kind), site, sites, managedSites, fetcher, secret, geo, rateLimit);

    /// <summary>A Runlight on the store given, with the options given.</summary>
    public static Harness Create(SqlStore store, SiteOptions? site = null, IReadOnlyList<SiteOptions>? sites = null, bool managedSites = false, IFetcher? fetcher = null, string? secret = null, Func<string, JsObject?>? geo = null, double? rateLimit = 120)
    {
        var t = new Harness(null!);
        t.Rl = new Runlight(new RunlightOptions
        {
            Store = store,
            Now = () => t.Now,
            Site = site,
            Sites = sites,
            ManagedSites = managedSites,
            Fetcher = fetcher,
            Secret = secret,
            Geo = geo,
            RateLimit = rateLimit,
        });
        return t;
    }

    public SqlStore Store => Rl.Store;

    public void Advance(long ms) => Now += ms;

    /// <summary>A tracker hit, as the routes pass it to CollectAsync.</summary>
    public Task SendAsync(JsObject body, string? ua = null, string? ip = null, Dictionary<string, string>? headers = null) =>
        Rl.CollectAsync(Hit("https://example.com/runlight/e", body, ua, ip, headers));

    public static Request Hit(string url, JsObject body, string? ua = null, string? ip = null, Dictionary<string, string>? headers = null)
    {
        var h = new Headers { ["user-agent"] = ua ?? ChromeMac, ["x-forwarded-for"] = ip ?? "203.0.113.1", ["content-type"] = "text/plain;charset=UTF-8" };
        foreach (var (k, v) in headers ?? [])
        {
            h.Set(k, v);
        }
        return new Request(url, "POST", h, Json.Stringify(body));
    }

    /// <summary>A query over local dates of a site, as the dashboard's from and to make one.</summary>
    public JsObject Query(string from, string to, string? site = null, params JsObject[] filters)
    {
        var row = Rl.Site(site)!;
        string tz = row.Str("timezone")!;
        return new JsObject
        {
            ["site"] = row.Get("id"),
            ["from"] = Time.StartOf(from, tz),
            ["to"] = Time.StartOf(Time.AddDays(to, 1), tz),
            ["filters"] = filters.Cast<object?>().ToList(),
        };
    }

    /// <summary>Today in the site's timezone, as period=today.</summary>
    public async Task<JsObject> TodayAsync(string? site = null)
    {
        await Rl.InitAsync();
        string day = Time.LocalDate(Now, Rl.Site(site)!.Str("timezone")!);
        return Query(day, day, site);
    }

    /// <summary>Everything, as period=all reads it, wide enough for any test.</summary>
    public async Task<JsObject> AllAsync(string? site = null)
    {
        await Rl.InitAsync();
        return new JsObject { ["site"] = Rl.Site(site)!.Get("id"), ["from"] = 0L, ["to"] = Now + DAY, ["filters"] = new List<object?>() };
    }

    public Task<JsObject> StatsAsync(JsObject query) => Store.StatsAsync(query);

    /// <summary>One field of each breakdown row.</summary>
    public async Task<List<object?>> ValuesAsync(JsObject query, string dimension, string field = "value", int limit = 10) =>
        (await Store.BreakdownAsync(query, dimension, limit, 0)).Select(r => r.Get(field)).ToList();

    /// <summary>The values of a breakdown as sorted strings.</summary>
    public async Task<List<string>> SortedAsync(JsObject query, string dimension) =>
        (await ValuesAsync(query, dimension)).Select(v => (string)v!).Order(StringComparer.Ordinal).ToList();

    public async Task<long> CountAsync(string sql, params object?[] args) => (long)Js.Number((await Store.Db.AllAsync(sql, args))[0].Get("n"));
}

/// <summary>
/// A fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve()
/// replaces globalThis.fetch. Each answer is a body to send as JSON, or a (status, body) pair.
/// </summary>
public sealed class Router(params (string Pattern, Func<Url, FetchInit, object?> Answer)[] routes) : IFetcher
{
    /// <summary>Stands in for DNS: every name is a public address unless a test says otherwise.</summary>
    public Func<string, IReadOnlyList<string>> Dns { get; set; } = _ => ["93.184.215.14"];

    public Task<IReadOnlyList<string>> LookupAsync(string name) => Task.FromResult(Dns(name));

    /// <summary>"METHOD host/path" of each request.</summary>
    public List<string> Calls { get; } = [];

    public List<(string Url, FetchInit Init)> Requests { get; } = [];

    public Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        init ??= new FetchInit();
        var u = new Url(url);
        Calls.Add(init.Method + " " + u.Host + u.Pathname);
        Requests.Add((url, init));
        foreach (var (pattern, answer) in routes)
        {
            if (Regex.IsMatch(u.Href, pattern))
            {
                object? result = answer(u, init);
                var (status, body) = result is ValueTuple<int, object?> pair ? pair : (200, result);
                return Task.FromResult(new Response(Json.Stringify(body), status, new Headers { ["content-type"] = "application/json" }));
            }
        }
        return Task.FromResult(new Response("{}", 404));
    }

    public static (string, Func<Url, FetchInit, object?>) R(string pattern, Func<object?> answer) => (pattern, (_, _) => answer());

    public static (string, Func<Url, FetchInit, object?>) R(string pattern, Func<Url, FetchInit, object?> answer) => (pattern, answer);
}
