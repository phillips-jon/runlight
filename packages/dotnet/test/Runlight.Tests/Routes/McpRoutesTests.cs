using System;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Routes.Make;

namespace Runlight.Tests.Routes;

/// <summary>
/// mcp.test.ts, ported as the PHP's tests/Routes/McpTest.php: API tokens and the MCP server through the routes, on
/// every store.
/// </summary>
public sealed class McpRoutesTests : RoutesTestCase
{
    private const string ChromeMac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

    private readonly long _now = Utc(2026, 10, 6, 12);

    /// <summary>A Runlight on a fresh store of this kind, its routes with the token "secret", and a way to send tracker hits.</summary>
    private async Task<(global::Runlight.Routes Routes, Func<JsObject, string, Task> Send)> MakeAsync(string kind)
    {
        var rl = await RunlightAsync(store: await Databases.FreshAsync(kind), sites: [Site("a", "Site A", ["a.com"], "UTC"), Site("b", "Site B", ["b.com"], "UTC")], now: () => _now);
        var routes = rl.Routes(new RoutesOptions { Token = "secret" });
        async Task Send(JsObject body, string ip = "203.0.113.1")
        {
            var answer = await routes.HandleAsync(new Request("https://example.com/runlight/e", "POST", H(("user-agent", ChromeMac), ("x-forwarded-for", ip), ("content-type", "text/plain;charset=UTF-8")), Json.Stringify(body)));
            if (answer.Status != 202)
            {
                throw new InvalidOperationException("collect answered " + answer.Status);
            }
        }
        return (routes, Send);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Api_tokens_read_cannot_write_can_be_limited_to_a_site_and_stop_at_revocation(string kind)
    {
        var (routes, send) = await MakeAsync(kind);
        async Task<(int Status, JsObject Body)> Make(JsObject body)
        {
            var answer = await routes.HandleAsync(Owner("/runlight/api/tokens", "POST", body));
            return (answer.Status, Obj(answer));
        }
        Assert.Equal(400, (await Make(new JsObject { ["name"] = "" })).Status);
        Assert.Equal(404, (await Make(new JsObject { ["name"] = "X", ["site"] = "nope" })).Status);
        var all = await Make(new JsObject { ["name"] = "Claude" });
        Assert.Equal(201, all.Status);
        string allSecret = all.Body.Str("secret")!;
        Assert.Matches("^rl_[a-f0-9]{40}$", allSecret);
        Assert.Equal(allSecret[^4..], all.Body.Obj("token")!.Str("hint"));
        var one = (await Make(new JsObject { ["name"] = "Client B", ["site"] = "b" })).Body;

        var listedAnswer = await routes.HandleAsync(Owner("/runlight/api/tokens"));
        var listed = Obj(listedAnswer);
        Assert.Equal(["Claude", "Client B"], Column(listed.Get("tokens"), "name").Cast<string>().Order(StringComparer.Ordinal));
        Assert.DoesNotContain(allSecret, listedAnswer.Text(), StringComparison.Ordinal); // a token is shown once, never listed
        Assert.False(((JsObject)listed.Arr("tokens")![0]!).Has("hash")); // nor its hash

        await send(new JsObject { ["k"] = "pageview", ["u"] = "https://a.com/", ["i"] = "p1" }, "203.0.113.1");
        await send(new JsObject { ["k"] = "pageview", ["u"] = "https://b.com/", ["i"] = "p2" }, "203.0.113.2");

        Task<Response> As(string path, string secret, string method = "GET", object? body = null) => routes.HandleAsync(Owner("/runlight" + path, method, body, secret));
        var stats = await As("/api/stats?site=a&period=today", allSecret);
        Assert.Equal(200, stats.Status);
        Assert.Equal(1, Obj(stats).Obj("stats")!.Num("visitors"));
        Assert.Equal(200, (await As("/api/links?site=a", allSecret)).Status); // links can be read

        // Nothing that writes, and nothing that manages access.
        Assert.Equal(403, (await As("/api/goals?site=a", allSecret, "POST", new JsObject { ["name"] = "G", ["kind"] = "page", ["match"] = "/" })).Status);
        Assert.Equal(403, (await As("/api/links?site=a", allSecret, "POST", new JsObject { ["url"] = "https://x.com" })).Status);
        Assert.Equal(401, (await As("/api/tokens", allSecret)).Status); // a token cannot list tokens
        Assert.Equal(401, (await As("/api/shares?site=a", allSecret)).Status);
        Assert.Equal(401, (await As("/api/mail", allSecret)).Status);

        // A site's token sees only that site.
        string oneSecret = one.Str("secret")!;
        Assert.Equal("[\"b\"]", Json.Stringify(Column(Obj(await As("/api/sites", oneSecret)).Get("sites"), "id")));
        Assert.Equal("b", Obj(await As("/api/stats?period=today", oneSecret)).Str("site")); // and defaults to it
        Assert.Equal(404, (await As("/api/stats?site=a", oneSecret)).Status);
        Assert.Equal(404, (await As("/api/links?site=a", oneSecret)).Status);

        var used = Obj(await routes.HandleAsync(Owner("/runlight/api/tokens")));
        foreach (var token in used.Arr("tokens")!.Cast<JsObject>())
        {
            if (token.Str("name") == "Claude")
            {
                Assert.Equal(_now, token.Long("lastUsedAt"));
            }
        }

        string id = all.Body.Obj("token")!.Str("id")!;
        Assert.Equal(403, (await As("/api/tokens/" + id, allSecret, "DELETE")).Status); // a token cannot revoke
        Assert.Equal(200, (await routes.HandleAsync(Owner("/runlight/api/tokens/" + id, "DELETE"))).Status);
        Assert.Equal(404, (await routes.HandleAsync(Owner("/runlight/api/tokens/" + id, "DELETE"))).Status);
        Assert.Equal(401, (await As("/api/stats?site=a", allSecret)).Status); // revoked at once
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task The_mcp_server_answers_initialize_lists_its_tools_and_calls_them_with_the_tokens_reach(string kind)
    {
        var (routes, send) = await MakeAsync(kind);
        string secret = Obj(await routes.HandleAsync(Owner("/runlight/api/tokens", "POST", new JsObject { ["name"] = "B only", ["site"] = "b" }))).Str("secret")!;
        await send(new JsObject { ["k"] = "pageview", ["u"] = "https://b.com/pricing", ["r"] = "https://news.ycombinator.com/", ["i"] = "p1" }, "203.0.113.1");
        await send(new JsObject { ["k"] = "pageview", ["u"] = "https://a.com/", ["i"] = "p2" }, "203.0.113.1");

        long id = 0;
        async Task<(int Status, Headers Headers, JsObject? Body)> Rpc(string method, object? parameters = null, string? auth = null)
        {
            var message = new JsObject { ["jsonrpc"] = "2.0", ["id"] = ++id, ["method"] = method };
            if (parameters != null)
            {
                message["params"] = parameters;
            }
            var answer = await routes.HandleAsync(new Request("https://example.com/runlight/mcp", "POST", H(("authorization", "Bearer " + (auth ?? secret)), ("content-type", "application/json"), ("accept", "application/json, text/event-stream")), Json.Stringify(message)));
            return (answer.Status, answer.Headers, answer.Status == 202 ? null : Obj(answer));
        }

        var refused = await Rpc("initialize", new JsObject(), "rl_" + new string('0', 40));
        Assert.Equal(401, refused.Status);
        Assert.Matches("^Bearer", refused.Headers.Get("www-authenticate") ?? "");
        Assert.Equal(405, (await routes.HandleAsync(Owner("/runlight/mcp"))).Status); // no event stream

        var init = await Rpc("initialize", new JsObject { ["protocolVersion"] = "2025-06-18", ["capabilities"] = new JsObject(), ["clientInfo"] = new JsObject { ["name"] = "test", ["version"] = "1" } });
        var result = init.Body!.Obj("result")!;
        Assert.Equal("2025-06-18", result.Str("protocolVersion"));
        Assert.Equal("runlight", result.Obj("serverInfo")!.Str("name"));
        Assert.True(result.Obj("capabilities")!.Has("tools"));
        Assert.Equal("2025-11-25", (await Rpc("initialize", new JsObject { ["protocolVersion"] = "1999-01-01" })).Body!.Obj("result")!.Str("protocolVersion")); // an unknown version gets the newest

        var note = await routes.HandleAsync(new Request("https://example.com/runlight/mcp", "POST", H(("authorization", "Bearer " + secret), ("content-type", "application/json")), Json.Stringify(new JsObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" })));
        Assert.Equal(202, note.Status);

        var listed = await Rpc("tools/list");
        var tools = listed.Body!.Obj("result")!.Arr("tools")!.Cast<JsObject>().ToList();
        Assert.Equal(Mcp.Tools.Select(t => t.Name), tools.Select(t => t.Str("name")));
        foreach (var tool in tools)
        {
            Assert.True(tool.Obj("annotations")!.Bool("readOnlyHint"));
        }

        async Task<JsObject> Call(string name, JsObject? args = null)
        {
            var called = (await Rpc("tools/call", new JsObject { ["name"] = name, ["arguments"] = args ?? new JsObject() })).Body!.Obj("result")!;
            called["data"] = called.Bool("isError") ? null : Json.Parse(((JsObject)called.Arr("content")![0]!).Str("text")!);
            return called;
        }
        Assert.Equal("[\"b\"]", Json.Stringify(Column((await Call("list_sites")).Obj("data")!.Get("sites"), "id")));
        var stats = await Call("get_stats", new JsObject { ["period"] = "today" });
        Assert.Equal("b", stats.Obj("data")!.Str("site"));
        Assert.Equal(1, stats.Obj("data")!.Obj("stats")!.Num("pageviews"));
        Assert.True((await Call("get_stats", new JsObject { ["site"] = "a" })).Bool("isError")); // another site is out of reach
        var sources = await Call("get_breakdown", new JsObject { ["period"] = "today", ["dimension"] = "source", ["limit"] = 500L });
        Assert.Equal("Hacker News", ((JsObject)sources.Obj("data")!.Arr("rows")![0]!).Str("value"));
        Assert.Equal(0, (await Call("get_stats", new JsObject { ["period"] = "today", ["filters"] = L("page:is:/nowhere") })).Obj("data")!.Obj("stats")!.Num("pageviews"));
        var bad = await Call("get_stats", new JsObject { ["filters"] = L("nonsense") });
        Assert.True(bad.Bool("isError"));
        Assert.Matches("Bad filter", ((JsObject)bad.Arr("content")![0]!).Str("text")!);
        var times = await Call("get_visit_times", new JsObject { ["period"] = "today" });
        Assert.Equal(7, times.Obj("data")!.Arr("grid")!.Count);
        Assert.False(times.Obj("data")!.Has("cells")); // trimmed to what an assistant needs
        Assert.Empty((await Call("list_goals", new JsObject { ["period"] = "today" })).Obj("data")!.Arr("goals")!);
        Assert.True((await Call("get_goal", new JsObject { ["goal_id"] = new string('f', 24) })).Bool("isError"));
        Assert.False((await Call("list_links")).Has("isError"));
        Assert.False((await Call("get_realtime")).Has("isError"));

        Assert.Equal(-32602, (await Rpc("tools/call", new JsObject { ["name"] = "drop_tables" })).Body!.Obj("error")!.Num("code"));
        Assert.Equal(-32601, (await Rpc("resources/list")).Body!.Obj("error")!.Num("code"));
        Assert.Equal("{}", Json.Stringify((await Rpc("ping")).Body!.Get("result")));

        // The owner's own token works too, across every site.
        var everySite = await Rpc("tools/call", new JsObject { ["name"] = "list_sites", ["arguments"] = new JsObject() }, "secret");
        var text = ((JsObject)everySite.Body!.Obj("result")!.Arr("content")![0]!).Str("text")!;
        Assert.Equal("[\"a\",\"b\"]", Json.Stringify(Column(((JsObject)Json.Parse(text)!).Get("sites"), "id")));
    }
}
