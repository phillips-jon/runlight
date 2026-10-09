using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Tests.ConformanceRunner.Fake;
using Xunit;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>The runner itself, proved apart from the .NET core, as the PHP's PlayerTest proves its runner.</summary>
public sealed class PlayerTests
{
    private const string Key = "rl_ABCDEFGHJKMNPQRSTVWXYZ12";
    private const string Hex24 = "0123456789abcdef01234567";
    private const string Hex32 = "0123456789abcdef0123456789abcdef";
    private const string Secret = "JBSWY3DPEHPK3PXP";
    private const long Start = 1_700_000_000_000;

    [Fact]
    public void The_format_is_the_one_this_runner_reads()
    {
        string hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Scenarios.File().Str("description")!)));
        Assert.True(
            Player.FormatSha256 == hash,
            "conformance/http.json describes its format differently now. Read the change, port it to Player, then update FormatSha256.");
    }

    public static TheoryData<string> ScenarioNames() => [.. Scenarios.All().Select(s => s.Str("name")!)];

    /// <summary>
    /// A fake that answers every step with the expected answer, its placeholders filled with fresh values,
    /// must come out of the runner as exactly the expected answers again.
    /// </summary>
    [Theory]
    [MemberData(nameof(ScenarioNames))]
    public async Task Replays_every_scenario_through_a_fake(string name)
    {
        var scenario = Scenarios.Named(name);
        ReplayTarget? fake = null;
        var saved = SetEnv();
        List<JsObject> answers;
        try
        {
            answers = await new Player().PlayAsync(scenario, options => fake = new ReplayTarget(scenario, options), "a store");
            foreach (string env in Player.Env)
            {
                Assert.Equal("from-outside", Environment.GetEnvironmentVariable(env));
            }
        }
        finally
        {
            Player.RestoreEnv(saved);
        }
        ConformanceTests.AssertAnswers(scenario, answers);
        Assert.Equal(scenario.Arr("steps")!.Count, fake!.Idled);
        Assert.Equal("a store", fake.Options.Store);
    }

    [Fact]
    public void Maps_the_scenario_options()
    {
        var scenario = (JsObject)Json.Parse("{\"site\":{\"hostnames\":[\"a.com\"],\"timezone\":\"UTC\"},\"token\":null,\"options\":{\"secret\":\"s\",\"rateLimit\":false,\"accounts\":true,\"origin\":\"https://o.example\",\"observeKey\":\"k\",\"cronSecret\":\"c\"}}")!;
        Assert.Equal("{\"site\":{\"hostnames\":[\"a.com\"],\"timezone\":\"UTC\"},\"secret\":\"s\",\"rateLimit\":false}", Json.Stringify(Player.RunlightOptions(scenario)));
        Assert.Equal("{\"token\":null,\"observeKey\":\"k\",\"cronSecret\":\"c\",\"accounts\":true,\"origin\":\"https://o.example\"}", Json.Stringify(Player.RoutesOptions(scenario)));

        scenario = (JsObject)Json.Parse("{\"site\":{\"hostnames\":[],\"timezone\":\"UTC\"},\"sites\":[{\"id\":\"a\",\"hostnames\":[\"a.com\"],\"timezone\":\"Europe/Paris\",\"name\":\"A\"}],\"token\":\"\"}")!;
        Assert.Equal("{\"sites\":[{\"id\":\"a\",\"hostnames\":[\"a.com\"],\"timezone\":\"Europe/Paris\",\"name\":\"A\"}]}", Json.Stringify(Player.RunlightOptions(scenario)));
        Assert.Equal("{\"token\":\"\",\"observeKey\":\"\",\"cronSecret\":\"\"}", Json.Stringify(Player.RoutesOptions(scenario)));

        scenario = (JsObject)Json.Parse("{\"site\":{\"hostnames\":[],\"timezone\":\"UTC\"},\"sites\":[],\"token\":\"t\",\"options\":{\"managedSites\":true,\"rateLimit\":4}}")!;
        Assert.Equal("{\"managedSites\":true,\"rateLimit\":4}", Json.Stringify(Player.RunlightOptions(scenario)));
    }

    [Fact]
    public void Core_options_follow_the_scenario()
    {
        Func<long> now = () => 5;
        var fetcher = new UpstreamFetcher([]);
        var options = new PlayOptions(
            (JsObject)Json.Parse("{\"sites\":[{\"id\":\"a\",\"hostnames\":[\"a.com\"],\"timezone\":\"Europe/Paris\",\"name\":\"A\"}],\"secret\":\"s\",\"rateLimit\":false}")!,
            (JsObject)Json.Parse("{\"token\":null,\"observeKey\":\"\",\"cronSecret\":\"c\",\"accounts\":true,\"origin\":\"https://o.example\"}")!,
            null,
            now,
            fetcher);
        var r = CoreTarget.Runlight(options);
        Assert.Equal(["a.com"], r.Sites![0].Hostnames!);
        Assert.Equal("Europe/Paris", r.Sites[0].Timezone);
        Assert.Null(r.Site);
        Assert.Null(r.RateLimit);
        Assert.Equal("s", r.Secret);
        Assert.Same(fetcher, r.Fetcher);
        var routes = CoreTarget.Routes(options.Routes);
        Assert.True(routes.TokenGiven);
        Assert.Null(routes.Token);
        Assert.Equal("", routes.ObserveKey);
        Assert.Equal("c", routes.CronSecret);
        Assert.True(routes.Accounts);
        Assert.Equal("https://o.example", routes.Origin);
        Assert.Equal(4, CoreTarget.Runlight(options with { Runlight = (JsObject)Json.Parse("{\"managedSites\":true,\"rateLimit\":4}")! }).RateLimit);
        Assert.Equal(120, CoreTarget.Runlight(options with { Runlight = (JsObject)Json.Parse("{\"site\":{\"hostnames\":[]}}")! }).RateLimit);
    }

    [Fact]
    public async Task Sends_and_keeps_what_the_TypeScript_runner_does()
    {
        var scenario = (JsObject)Json.Parse("""
            {
              "name": "the runner",
              "site": {"hostnames": ["example.com"], "timezone": "UTC"},
              "start": 1700000000000,
              "token": "t",
              "upstream": [
                {"url": "https://api.example.com/json", "method": "POST", "body": {"ok": true}},
                {"url": "https://api.example.com/", "status": 201, "body": "plain", "headers": {"x-up": "1"}}
              ],
              "steps": [
                {"method": "POST", "path": "/login", "form": {"email": "a b@x.com", "next": "/runlight/?a=1&b=2"},
                 "capture": {"tok": "token", "id": "nested.list.0.id", "etag": "header:etag", "code": "header:location~code=([a-f0-9]+)",
                   "cookies": "header:set-cookie", "sec": "secret", "raw": "text~\"id\":\"(\\w+)\"", "missing": "nested.nothing.deep",
                   "count": "nested.count", "flag": "nested.flag", "arr": "nested.arr", "obj": "nested", "nomatch": "text~(zzz)"}},
                {"advance": 30000, "method": "put", "path": "/x/{{id}}?c={{code}}",
                 "headers": {"Authorization": "Bearer {{tok}}", "X-Otp": "{{totp:sec}}", "X-All": "{{missing}}|{{count}}|{{flag}}|{{arr}}|{{obj}}|{{unknown}}|{{nomatch}}|{{raw}}"},
                 "body": {"a": "{{etag}}", "n": 1.5, "o": {}, "l": [], "t": "{{totp:sec}}"}},
                {"method": "GET", "path": "/go/x", "to": "links", "host": "s.example.com", "jar": "other"},
                {"method": "GET", "path": "/.well-known/x", "absolute": true, "jar": false, "capture": {"unsub": "fetched~/unsubscribe/([a-f0-9]{32})"}},
                {"method": "GET", "path": "/r/{{unsub}}", "to": "linkDomain", "headers": {"Cookie": "mine=1"}},
                {"method": "POST", "path": "/raw", "body": "{{tok}} as text", "headers": {"content-type": "text/csv"}, "look": ["a,b", "zzz"]},
                {"method": "GET", "path": "/export"},
                {"method": "GET", "path": "/null"}
              ]
            }
            """)!;
        UpstreamFetcher? fetcher = null;
        Func<long>? now = null;
        static Headers H(params (string Name, string Value)[] pairs)
        {
            var headers = new Headers();
            foreach (var (name, value) in pairs)
            {
                headers.Append(name, value);
            }
            return headers;
        }
        var script = new List<Func<Request, string, Task<Response?>>>
        {
            (r, _) =>
            {
                Assert.Equal("https://example.com/runlight/login", r.Url);
                Assert.Equal("POST", r.Method);
                Assert.Equal("email=a+b%40x.com&next=%2Frunlight%2F%3Fa%3D1%26b%3D2", r.Text());
                Assert.Equal("application/x-www-form-urlencoded", r.Headers.Get("content-type"));
                Assert.Null(r.Headers.Get("cookie"));
                Assert.Equal(Start, now!());
                foreach (string name in Player.Env)
                {
                    Assert.Null(Env.Get(name));
                }
                var body = new JsObject
                {
                    ["token"] = Key,
                    ["secret"] = Secret,
                    ["id"] = Hex24,
                    ["nested"] = new JsObject { ["list"] = new List<object?> { new JsObject { ["id"] = "x1" } }, ["count"] = 3L, ["flag"] = true, ["arr"] = new List<object?> { 1L, null, "b" } },
                };
                return Task.FromResult<Response?>(new Response(Json.Stringify(body), 200, H(
                    ("content-type", "application/json; charset=utf-8"),
                    ("etag", "W/\"1\""),
                    ("location", "/cb?code=deadbeef&state=" + Hex32),
                    ("set-cookie", "sid=abc; Path=/; HttpOnly"),
                    ("set-cookie", "old=; Max-Age=0"),
                    ("set-cookie", "keep=k1"),
                    ("cache-control", "no-store"),
                    ("x-other", "not compared"))));
            },
            async (r, _) =>
            {
                Assert.Equal("https://example.com/runlight/x/x1?c=deadbeef", r.Url);
                Assert.Equal("PUT", r.Method);
                Assert.Equal(Start + 30_000, now!());
                string code = Crypto.Totp(Secret, (Start + 30_000) / 30_000);
                Assert.Equal("Bearer " + Key, r.Headers.Get("authorization"));
                Assert.Equal(code, r.Headers.Get("x-otp"));
                Assert.Equal("|3|true|1,,b|[object Object]|||" + Hex24, r.Headers.Get("x-all"));
                Assert.Equal("sid=abc; keep=k1", r.Headers.Get("cookie"));
                Assert.Equal(Player.TextBodyType, r.Headers.Get("content-type"));
                Assert.Equal("{\"a\":\"W/\\\"1\\\"\",\"n\":1.5,\"o\":{},\"l\":[],\"t\":\"" + code + "\"}", r.Text());

                var json = await fetcher!.FetchAsync("https://api.example.com/json", new FetchInit
                {
                    Method = "post",
                    Headers = H(("Content-Type", "application/json"), ("X-B", "2"), ("a-first", "1")),
                    BodyText = "{\"q\":\"" + Key + "\"}",
                });
                Assert.Equal((200, "application/json", "{\"ok\":true}"), (json.Status, json.Headers.Get("content-type"), json.Text()));
                var plain = await fetcher.FetchAsync("https://api.example.com/json");
                Assert.Equal((201, (string?)null, "1", "plain"), (plain.Status, plain.Headers.Get("content-type"), plain.Headers.Get("x-up"), plain.Text()));
                var error = await Assert.ThrowsAsync<FetchException>(() => fetcher.FetchAsync("https://nowhere.example/", new FetchInit { Method = "DELETE" }));
                Assert.Equal("fetch failed", error.Message);
                return new Response("", 204, H(("set-cookie", "sid=gone; Max-Age=0")));
            },
            (r, to) =>
            {
                Assert.Equal("links", to);
                Assert.Equal("https://s.example.com/go/x", r.Url);
                Assert.Null(r.Headers.Get("cookie"));
                return Task.FromResult<Response?>(new Response("", 302, H(("location", "https://shop.example.com/?ref=" + Key), ("set-cookie", "o=1"))));
            },
            async (r, _) =>
            {
                Assert.Equal("https://example.com/.well-known/x", r.Url);
                Assert.Null(r.Headers.Get("cookie"));
                await fetcher!.FetchAsync("https://api.example.com/mail", new FetchInit { Method = "POST", Headers = H(("content-type", "application/json")), BodyText = "{\"link\":\"https://stats.example.com/unsubscribe/" + Hex32 + "\"}" });
                await fetcher.FetchAsync("https://api.example.com/form", new FetchInit { Method = "POST", Headers = H(("content-type", "application/x-www-form-urlencoded")), BodyText = "a=1&b=x+y&a=2" });
                return new Response("<p>hi</p>", 200, H(("content-type", "text/html")));
            },
            (r, to) =>
            {
                Assert.Equal("linkDomain", to);
                Assert.Equal("https://example.com/r/" + Hex32, r.Url);
                Assert.Equal("mine=1", r.Headers.Get("cookie"));
                return Task.FromResult<Response?>(null);
            },
            (r, _) =>
            {
                Assert.Equal(Key + " as text", r.Text());
                Assert.Equal("text/csv", r.Headers.Get("content-type"));
                Assert.Equal("keep=k1", r.Headers.Get("cookie"));
                return Task.FromResult<Response?>(new Response("a,b\n1," + Key, 200, H(("content-type", "text/csv; charset=utf-8"))));
            },
            (_, _) => Task.FromResult<Response?>(new Response(
                TestZip.Zip([("a.csv", "x," + Hex32), ("b.txt", (char)0xFEFF + "plain")]),
                200,
                H(("content-type", "application/zip"), ("content-disposition", "attachment; filename=\"export.zip\"")))),
            (_, _) => Task.FromResult<Response?>(new Response("null", 200)),
        };
        var target = new ScriptedTarget(script);
        var answers = await new Player().PlayAsync(scenario, options =>
        {
            fetcher = options.Fetcher;
            now = options.Now;
            return target;
        });

        var expected = Json.Parse("""
            [
              {"status": 200, "headers": {"content-type": "application/json", "cache-control": "no-store", "location": "/cb?code=<value>&state=<hex>",
                "set-cookie": ["sid=<value>; Path=/; HttpOnly", "old=; Max-Age=0", "keep=<value>"]},
               "body": {"token": "<token>", "secret": "<secret>", "id": "<id>", "nested": {"list": [{"id": "x1"}], "count": 3, "flag": true, "arr": [1, null, "b"]}}},
              {"status": 204, "headers": {"set-cookie": ["sid=<value>; Max-Age=0"]}, "fetched": [
                {"method": "POST", "url": "https://api.example.com/json", "headers": {"a-first": "1", "content-type": "application/json", "x-b": "2"}, "body": {"q": "<q>"}},
                {"method": "GET", "url": "https://api.example.com/json"},
                {"method": "DELETE", "url": "https://nowhere.example/"}
              ]},
              {"status": 302, "headers": {"location": "https://shop.example.com/?ref=<key>", "set-cookie": ["o=<value>"]}},
              {"status": 200, "headers": {"content-type": "text/html"}, "fetched": [
                {"method": "POST", "url": "https://api.example.com/mail", "headers": {"content-type": "application/json"}, "body": {"link": "https://stats.example.com/unsubscribe/<hex>"}},
                {"method": "POST", "url": "https://api.example.com/form", "headers": {"content-type": "application/x-www-form-urlencoded"}, "body": {"a": "2", "b": "x y"}}
              ]},
              {"pass": true},
              {"status": 200, "headers": {"content-type": "text/csv"}, "text": "a,b\n1,<key>", "found": [true, false]},
              {"status": 200, "headers": {"content-type": "application/zip", "content-disposition": "attachment; filename=\"export.zip\""},
               "files": [{"name": "a.csv", "text": "x,<hex>"}, {"name": "b.txt", "text": "plain"}]},
              {"status": 200, "body": null}
            ]
            """);
        Assert.Equal(Normalizer.Canonical(expected), Normalizer.Canonical(answers.Cast<object?>().ToList()));
        Assert.Equal(8, target.Idled);
    }

    [Fact]
    public async Task Names_the_step_that_threw()
    {
        var scenario = (JsObject)Json.Parse("{\"name\":\"broken\",\"site\":{\"hostnames\":[],\"timezone\":\"UTC\"},\"start\":0,\"token\":\"\",\"steps\":[{\"method\":\"GET\",\"path\":\"/a\"},{\"method\":\"POST\",\"path\":\"/b\"}]}")!;
        var target = new ScriptedTarget(
        [
            (_, _) => Task.FromResult<Response?>(new Response("", 200)),
            (_, _) => throw new ArgumentException("boom"),
        ]);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new Player().PlayAsync(scenario, _ => target));
        Assert.Equal("broken: step 2, POST /b: boom", error.Message);
    }

    [Fact]
    public async Task Upstream_answers()
    {
        var upstream = ((List<object?>)Json.Parse("[{\"url\":\"https://a.example/null\",\"body\":null},{\"url\":\"https://a.example/list\",\"body\":[1],\"headers\":{\"Content-Type\":\"text/plain\"}},{\"url\":\"https://a.example/big\",\"body\":\"0123456789\"},{\"url\":\"https://a.example/empty\",\"method\":\"\"}]")!).Cast<JsObject>().ToList();
        var fetcher = new UpstreamFetcher(upstream);
        var nothing = await fetcher.FetchAsync("https://a.example/null");
        Assert.Equal(("application/json", "null"), (nothing.Headers.Get("content-type"), nothing.Text()));
        // Spread over {"content-type": ...}, a differently spelled name is a second value, as new Headers() makes it.
        Assert.Equal("application/json, text/plain", (await fetcher.FetchAsync("https://a.example/list")).Headers.Get("content-type"));
        Assert.Equal("01234", (await fetcher.FetchAsync("https://a.example/big", new FetchInit { MaxBytes = 5, Truncate = true })).Text());
        await Assert.ThrowsAsync<BodyTooLongException>(() => fetcher.FetchAsync("https://a.example/big", new FetchInit { MaxBytes = 5 }));
        var empty = await fetcher.FetchAsync("https://a.example/empty", new FetchInit { Method = "PATCH" });
        Assert.Equal((200, "", (string?)null), (empty.Status, empty.Text(), empty.Headers.Get("content-type")));
        Assert.Equal(5, fetcher.Take().Count);
        Assert.Empty(fetcher.Take());
    }

    [Fact]
    public void Capture_helpers()
    {
        object? parsed = Json.Parse("{\"a\":{\"b\":[{\"c\":\"x\"},0,\"\"]},\"n\":1.0,\"f\":0.5,\"big\":1e21}");
        Assert.Equal("x", Player.JsString(Player.Dig(parsed, "a.b.0.c")));
        Assert.Equal("0", Player.JsString(Player.Dig(parsed, "a.b.1")));
        Assert.Equal("", Player.JsString(Player.Dig(parsed, "a.b.1.c")));
        Assert.Equal("", Player.JsString(Player.Dig(parsed, "a.b.01")));
        Assert.Equal("1", Player.JsString(Player.Dig(parsed, "n")));
        Assert.Equal("0.5", Player.JsString(Player.Dig(parsed, "f")));
        Assert.Equal("1e+21", Player.JsString(Player.Dig(parsed, "big")));
        Assert.Equal("[object Object],0,", Player.JsString(Player.Dig(parsed, "a.b")));
        Assert.Equal("", Player.JsString(Player.Dig(null, "a")));
        Assert.Equal("abc", Player.FirstGroup("state=([a-f0-9]+)", "x?state=abc&y"));
        Assert.Equal("", Player.FirstGroup("state=([a-f0-9]+)", "nothing"));
        Assert.Equal("", Player.FirstGroup("(x)?y", "y"));
        Assert.Equal("/assets/app.1f.css", Player.FirstGroup("href=\"/runlight(/assets/app\\.[a-f0-9]+\\.css)\"", "<link href=\"/runlight/assets/app.1f.css\">"));
    }

    /// <summary>Sets every variable the player clears, so a test can see them cleared and put back.</summary>
    private static Dictionary<string, string?> SetEnv()
    {
        var saved = Player.ClearEnv();
        foreach (string name in Player.Env)
        {
            Environment.SetEnvironmentVariable(name, "from-outside");
        }
        return saved;
    }
}
