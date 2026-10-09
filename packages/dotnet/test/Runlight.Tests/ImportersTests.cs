using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Importers;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// Ports ImportersTest.php: replays the importer scenarios in fixtures/outbound.json (the cases of
/// importers.test.ts and more). Each importer, run step by step against the same answers, must send
/// the TypeScript SDK's exact requests, wait as long between retries, ask about the same known links,
/// and hand back the same steps, cursors included. Also the pure CSV pieces of VisitsImportTest.php.
/// </summary>
public sealed class ImportersTests
{
    public static TheoryData<string> Scenarios()
    {
        var data = new TheoryData<string>();
        foreach (JsObject s in MailTests.Fixture.Arr("importers")!)
        {
            data.Add(s.Str("name")!);
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(Scenarios))]
    public async Task Scenario_matches_TypeScript(string name)
    {
        var scenario = MailTests.Fixture.Arr("importers")!.Cast<JsObject>().First(s => s.Str("name") == name);
        long now = MailTests.Fixture.Long("now");
        var routes = scenario.Arr("routes")!.Cast<JsObject>().ToList();
        var left = routes.Select(r => r.Has("times") ? r.Long("times") : long.MaxValue).ToArray();
        var fetcher = new FakeFetcher((url, _) =>
        {
            for (int i = 0; i < routes.Count; i++)
            {
                var route = routes[i];
                if (left[i] <= 0 || !Regex.IsMatch(url, route.Str("pattern")!, RegexOptions.CultureInvariant))
                {
                    continue;
                }
                left[i]--;
                if (route.Bool("unreachable"))
                {
                    throw new FetchException("fetch failed");
                }
                var headers = new Headers { ["content-type"] = "application/json" };
                foreach (var (k, v) in route.Obj("headers") ?? [])
                {
                    headers.Set(k, Js.String(v));
                }
                return new Response(Json.Stringify(route.Get("body")), route.Has("status") ? (int)route.Long("status") : 200, headers);
            }
            return new Response("{}", 404);
        });
        var waits = new List<object?>();
        var http = new Importers.Http(fetcher, (ms, _) =>
        {
            waits.Add(ms);
            return Task.CompletedTask;
        });
        Func<long> clock = () => now;
        IImporter importer = scenario.Str("source") switch
        {
            "bitly" => new Bitly(http, clock),
            "dub" => new Dub(http, clock),
            "rebrandly" => new Rebrandly(http, clock),
            "shortio" => new Shortio(http, clock),
            "umami" => new Umami(http, clock),
            _ => throw new InvalidOperationException(scenario.Str("source")),
        };
        var knownList = scenario.Arr("known")!;
        var knownCalls = new List<object?>();
        Task<bool> Known(string sourceId, string? slug, string? url)
        {
            knownCalls.Add(Js.List(sourceId, slug, url));
            return Task.FromResult(knownList.Contains(sourceId) || knownList.Contains(slug + " " + url));
        }

        var expected = scenario.Arr("steps")!.Cast<JsObject>().ToList();
        string? cursor = expected.Count > 0 ? expected[0].Str("cursor") : null;
        for (int i = 0; i < expected.Count; i++)
        {
            var want = expected[i];
            Assert.True(J(want.Get("cursor")) == J(cursor), "step " + i + " starts from the same cursor");
            JsObject result;
            try
            {
                result = await importer.StepAsync(scenario.Obj("credentials")!, cursor, Known);
            }
            catch (ImportError error)
            {
                Assert.True(want.Has("error"), "step " + i + " should not fail: " + error.Message);
                var got = new JsObject { ["message"] = error.Message, ["code"] = error.Code, ["params"] = error.Params };
                if (error is HttpError h)
                {
                    got["status"] = (long)h.Status;
                }
                got["name"] = error.GetType().Name;
                Assert.Equal(J(want.Get("error")), J(got));
                continue;
            }
            Assert.False(want.Has("error"), "step " + i + " should fail");
            Assert.Equal(J(want.Get("result")), J(result));
            cursor = result.Get("cursor") as string;
        }

        var sent = MailTests.Sent(fetcher).Select(J).ToList();
        var requests = scenario.Arr("requests")!.Select(J).ToList();
        if (!scenario.Bool("ordered"))
        {
            // Umami asks for a link's events and sessions at once in TS; here one follows the other.
            sent.Sort(StringComparer.Ordinal);
            requests.Sort(StringComparer.Ordinal);
        }
        Assert.Equal(requests, sent);
        Assert.Equal(J(scenario.Get("waits")), J(waits));
        Assert.Equal(J(scenario.Get("knownCalls")), J(knownCalls));
    }

    [Fact]
    public void Dates_parse_as_JavaScript_parses_them()
    {
        Assert.Equal(1767225600000, Importers.Http.ParseDate("2026-01-01T00:00:00Z"));
        Assert.Equal(1767225600000, Importers.Http.ParseDate("2026-01-01T00:00:00+0000"));
        Assert.Equal(1767225600000, Importers.Http.ParseDate("2026-01-01"));
        Assert.Equal(1767225600500, Importers.Http.ParseDate("2026-01-01T02:00:00.5+02:00"));
        // Local time, in the process's zone.
        double local = 1767225600000 - TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(1767225600000)).TotalMilliseconds;
        Assert.Equal(local, Importers.Http.ParseDate("2026-01-01T00:00:00"));
        Assert.Equal(0, Importers.Http.ParseDate("1970-01-01T00:00:00.000Z"));
        Assert.True(double.IsNaN(Importers.Http.ParseDate("nope")));
        Assert.True(double.IsNaN(Importers.Http.ParseDate("2026-02-30")));
        Assert.True(double.IsNaN(Importers.Http.ParseDate(null)));
        Assert.Equal("2026-03-02T00:00:00.000Z", Importers.Http.IsoString(1772409600000));
        Assert.Equal("1969-12-31T23:59:59.999Z", Importers.Http.IsoString(-1));
        Assert.Equal("+275760-09-13T00:00:00.000Z", Importers.Http.IsoString(8.64e15));
        Assert.Equal("-000001-01-01T00:00:00.000Z", Importers.Http.IsoString(Importers.Http.ParseDate("-000001-01-01T00:00:00Z")));
        Assert.Throws<ArgumentOutOfRangeException>(() => Importers.Http.IsoString(double.NaN));
    }

    /// <summary>Names JavaScript objects carry on their prototype are just names, as edges.test.ts checks in the SDK.</summary>
    [Fact]
    public async Task Names_like_object_properties_are_just_names()
    {
        var runlight = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite") });
        foreach (string source in new[] { "constructor", "toString", "__proto__", "hasOwnProperty" })
        {
            var e = await Assert.ThrowsAsync<ImportError>(() => Importers.Index.ImportStepAsync(runlight, "default", source, new JsObject(), null, 0));
            Assert.Equal("import_source", e.Code);
        }
        Assert.Equal(["Constructor", "__proto__", "ToString"], new[] { "constructor", "__proto__", "toString" }.Select(Write.Browser));
        Assert.Equal(["constructor", "toString"], new[] { "constructor", "toString" }.Select(Write.System));
        Assert.Equal(["", ""], new[] { "constructor", "valueOf" }.Select(Write.Device));
    }

    [Fact]
    public void JavaScript_values_read_as_they_do()
    {
        Assert.Equal([false, false, false, true, true, false, true], new object?[] { null, "", 0L, "0", new List<object?>(), double.NaN, 0.5 }.Select(Js.Truthy));
        Assert.Equal(["7", "7", "null", "undefined", "a,b", "1e+21"], new object?[] { 7L, 7.0, null, Undefined.Value, Js.List("a", "b"), 1e21 }.Select(Js.String));
        Assert.Equal([0.0, 2.0, 1.5, 31.0], new object?[] { null, " 2 ", "1.5", "0x1f" }.Select(Js.Number));
        Assert.True(double.IsNaN(Js.Number("soon")));
        Assert.Equal("a%20b%2Fc!'()*~", Js.EncodeURIComponent("a b/c!'()*~"));
        Assert.Equal("{\"a\":1}", J(Importers.Http.Defined(new JsObject { ["a"] = 1L, ["b"] = Undefined.Value })));
        Assert.Same(Undefined.Value, Importers.Http.Field(null, "x"));
        Assert.Null(Importers.Http.Field(new JsObject { ["x"] = null }, "x"));
        Assert.Equal("y", Importers.Http.Coalesce(Undefined.Value, "y"));
    }

    [Fact]
    public void Csv_times_and_formats()
    {
        Assert.Equal("umami", CsvVisits.CsvFormat(["created_at", "url_path", "session_id"]));
        Assert.Equal("runlight", CsvVisits.CsvFormat(["time", "url"]));
        Assert.Null(CsvVisits.CsvFormat(["date", "visitors"]));
        double iso = Importers.Http.ParseDate("2026-03-01T10:00:00Z");
        Assert.Equal(iso, CsvVisits.RowTime(new JsObject { ["time"] = "2026-03-01 10:00:00" }, "runlight"));
        Assert.Equal(iso, CsvVisits.RowTime(new JsObject { ["time"] = "2026-03-01T12:00:00+02:00" }, "runlight"));
        Assert.Equal(iso, CsvVisits.RowTime(new JsObject { ["time"] = Js.String(iso / 1000) }, "runlight"));
        Assert.Equal(iso, CsvVisits.RowTime(new JsObject { ["time"] = Js.String(iso) }, "runlight"));
        Assert.Equal(iso, CsvVisits.RowTime(new JsObject { ["created_at"] = "2026-03-01 10:00:00" }, "umami"));
        Assert.True(double.IsNaN(CsvVisits.RowTime(new JsObject { ["time"] = "" }, "runlight")));
        Assert.True(double.IsNaN(CsvVisits.RowTime(new JsObject { ["time"] = "yesterday" }, "runlight")));
    }

    [Fact]
    public void Csv_rows_become_hits()
    {
        var hit = CsvVisits.CsvHit(new JsObject { ["time"] = "2026-03-01 10:00:00", ["url"] = "example.com/a?utm_source=x", ["referrer"] = "news.ycombinator.com", ["event"] = "Signup" }, "runlight")!.Value;
        Assert.Equal("csv", hit.Ns);
        Assert.Equal(
            "{\"ts\":1772359200000,\"key\":\"row:[[\\\"event\\\",\\\"Signup\\\"],[\\\"referrer\\\",\\\"news.ycombinator.com\\\"],[\\\"time\\\",\\\"2026-03-01 10:00:00\\\"],[\\\"url\\\",\\\"example.com/a?utm_source=x\\\"]]\",\"kind\":\"event\",\"hostname\":\"example.com\",\"path\":\"/a\",\"query\":\"utm_source=x\",\"referrer\":\"https://news.ycombinator.com\",\"title\":\"\",\"name\":\"Signup\",\"country\":\"\",\"region\":\"\",\"city\":\"\",\"browser\":\"\",\"os\":\"\",\"device\":\"\",\"screen\":\"\",\"language\":\"\"}",
            J(hit.Hit));
        var umami = CsvVisits.CsvHit(new JsObject { ["created_at"] = "2026-03-01 10:00:00", ["url_path"] = "", ["website_id"] = "w1", ["session_id"] = "s1", ["referrer_domain"] = "a.com", ["referrer_query"] = "?q=1", ["event_type"] = "2", ["event_name"] = "go" }, "umami")!.Value;
        Assert.Equal("umami-visits:w1", umami.Ns);
        Assert.Equal("/", umami.Hit.Str("path"));
        Assert.Equal("https://a.com/?q=1", umami.Hit.Str("referrer"));
        Assert.Equal("event", umami.Hit.Str("kind"));
        Assert.Null(CsvVisits.CsvHit(new JsObject { ["created_at"] = "2026-03-01 10:00:00", ["url_path"] = "/", ["event_type"] = "3" }, "umami"));
        Assert.Null(CsvVisits.CsvHit(new JsObject { ["time"] = "never", ["path"] = "/" }, "runlight"));
    }
}
