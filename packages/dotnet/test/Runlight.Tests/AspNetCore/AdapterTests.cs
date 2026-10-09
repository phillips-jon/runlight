using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Runlight.AspNetCore;
using Xunit;
using Response = Runlight.Http.Response;

namespace Runlight.Tests.AspNetCore;

/// <summary>
/// Runlight.AspNetCore: MapRunlight and UseRunlight through ASP.NET Core's in-memory test server, and the request
/// and answer as they cross a real Kestrel socket.
/// </summary>
public sealed class AdapterTests : IAsyncLifetime
{
    private const string Chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";
    private const string GptBot = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";

    /// <summary>The Kestrel tests' port, in the range kept for this port's servers (5300 to 5349).</summary>
    private const int KestrelPort = 5317;

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    private static async Task<Runlight> RunlightAsync() => new(new RunlightOptions
    {
        Store = await Databases.FreshAsync("sqlite"),
        Site = new SiteOptions { Name = "Example", Hostnames = ["example.com"] },
    });

    /// <summary>An app on the test server: Runlight mapped or as middleware, and a page of the app's own.</summary>
    private static async Task<WebApplication> AppAsync(Runlight rl, bool middleware, RoutesOptions? options = null)
    {
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseTestServer();
        builder.Services.AddSingleton(rl);
        WebApplication app = builder.Build();
        options ??= new RoutesOptions { Token = "tok" };
        if (middleware)
        {
            app.UseRunlight(options);
        }
        else
        {
            app.MapRunlight(options);
        }
        app.MapGet("/", () => "the app's home");
        app.MapGet("/blog/{slug}", (string slug) => "post " + slug);
        await app.StartAsync();
        return app;
    }

    private static HttpRequestMessage Message(HttpMethod method, string path, string? body = null, string? host = null, params (string Name, string Value)[] headers)
    {
        var message = new HttpRequestMessage(method, "http://example.com" + path);
        if (body != null)
        {
            message.Content = new StringContent(body, Encoding.UTF8);
            message.Content.Headers.ContentType = null;
        }
        if (host != null)
        {
            message.Headers.Host = host;
        }
        foreach (var (name, value) in headers)
        {
            if (!message.Headers.TryAddWithoutValidation(name, value))
            {
                message.Content!.Headers.TryAddWithoutValidation(name, value);
            }
        }
        return message;
    }

    private static async Task<JsObject> JsonAsync(HttpResponseMessage answer) => (JsObject)Json.Parse(await answer.Content.ReadAsStringAsync())!;

    /// <summary>Waits for something that happens after the answer is sent, with a generous bound.</summary>
    private static async Task EventuallyAsync(Func<Task<bool>> done)
    {
        for (int i = 0; i < 200; i++)
        {
            if (await done())
            {
                return;
            }
            await Task.Delay(25);
        }
        Assert.Fail("it never happened");
    }

    public static TheoryData<bool> Ways() => [false, true];

    [Theory]
    [MemberData(nameof(Ways))]
    public async Task The_tracker_the_api_short_links_and_link_domains_answer_and_the_app_keeps_the_rest(bool middleware)
    {
        var rl = await RunlightAsync();
        await using var app = await AppAsync(rl, middleware);
        HttpClient client = app.GetTestClient();

        var script = await client.SendAsync(Message(HttpMethod.Get, "/runlight/s.js"));
        Assert.Equal(HttpStatusCode.OK, script.StatusCode);
        Assert.Contains("javascript", script.Content.Headers.ContentType?.ToString() ?? "", StringComparison.Ordinal);
        Assert.Contains("sendBeacon", await script.Content.ReadAsStringAsync(), StringComparison.Ordinal);

        var hit = await client.SendAsync(Message(HttpMethod.Post, "/runlight/e", Json.Stringify(new JsObject { ["k"] = "pageview", ["u"] = "https://example.com/post", ["i"] = "pv1" }), null, ("user-agent", Chrome), ("x-forwarded-for", "203.0.113.9")));
        Assert.Equal(HttpStatusCode.Accepted, hit.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(Message(HttpMethod.Get, "/runlight/api/stats?period=today"))).StatusCode);
        var stats = await JsonAsync(await client.SendAsync(Message(HttpMethod.Get, "/runlight/api/stats?period=today", null, null, ("authorization", "Bearer tok"))));
        Assert.Equal(1.0, stats.Obj("stats")!.Num("pageviews"));

        // A short link at /go on the app's own domain, then on a link domain of its own.
        var json = new[] { ("authorization", "Bearer tok"), ("content-type", "application/json") };
        Assert.Equal(HttpStatusCode.Created, (await client.SendAsync(Message(HttpMethod.Post, "/runlight/api/link-domains", Json.Stringify(new JsObject { ["domain"] = "go.example.net" }), null, json))).StatusCode);
        Assert.Equal(HttpStatusCode.Created, (await client.SendAsync(Message(HttpMethod.Post, "/runlight/api/links", Json.Stringify(new JsObject { ["url"] = "https://example.com/launch", ["slug"] = "launch", ["domain"] = "go.example.net" }), null, json))).StatusCode);
        var go = await client.SendAsync(Message(HttpMethod.Get, "/go/launch"));
        Assert.Equal(HttpStatusCode.Found, go.StatusCode);
        Assert.Equal("https://example.com/launch", go.Headers.Location?.ToString());
        var linked = await client.SendAsync(Message(HttpMethod.Get, "/launch", null, "go.example.net"));
        Assert.Equal(HttpStatusCode.Found, linked.StatusCode);
        Assert.Equal("https://example.com/launch", linked.Headers.Location?.ToString());
        Assert.Equal(HttpStatusCode.NotFound, (await client.SendAsync(Message(HttpMethod.Get, "/", null, "go.example.net"))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Message(HttpMethod.Get, "/runlight/s.js", null, "go.example.net"))).StatusCode);

        // The app's own pages are the app's, and an AI agent fetching one is counted on the way past.
        Assert.Equal("the app's home", await client.GetStringAsync("http://example.com/"));
        var post = await client.SendAsync(Message(HttpMethod.Get, "/blog/hello", null, null, ("user-agent", GptBot)));
        Assert.Equal("post hello", await post.Content.ReadAsStringAsync());
        var fetches = await rl.Store.Db.AllAsync("SELECT path, name FROM rl_events WHERE kind = 'fetch'");
        Assert.Equal("/blog/hello", Assert.Single(fetches).Str("path"));
        Assert.Equal("GPTBot", fetches[0].Str("name"));
    }

    [Theory]
    [MemberData(nameof(Ways))]
    public async Task Work_left_after_answering_runs_once_the_answer_is_sent_and_a_body_past_its_limit_is_a_413(bool middleware)
    {
        var rl = await RunlightAsync();
        await using var app = await AppAsync(rl, middleware);
        HttpClient client = app.GetTestClient();
        bool ran = false;
        rl.Later(() =>
        {
            ran = true;
            return Task.CompletedTask;
        });
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Message(HttpMethod.Get, "/runlight/s.js"))).StatusCode);
        await EventuallyAsync(() => Task.FromResult(ran));

        var big = await client.SendAsync(Message(HttpMethod.Post, "/runlight/e", new string('x', RunlightHttp.MaxCollectBody + 1), null, ("user-agent", Chrome)));
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, big.StatusCode);
        Assert.Equal("{\"error\":\"That request is too large\"}", await big.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task The_base_path_moves_the_routes_and_open_routes_take_the_apps_authorization()
    {
        var rl = await RunlightAsync();
        await using var app = await AppAsync(rl, false, new RoutesOptions { BasePath = "/stats/", Token = null });
        HttpClient client = app.GetTestClient();
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Message(HttpMethod.Get, "/stats/s.js"))).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Message(HttpMethod.Get, "/stats/api/sites"))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.SendAsync(Message(HttpMethod.Get, "/runlight/s.js"))).StatusCode);

        var endpoints = app.Services.GetRequiredService<EndpointDataSource>().Endpoints;
        var dashboard = endpoints.Single(e => e.DisplayName?.Contains("/stats/{**", StringComparison.Ordinal) == true);
        Assert.Null(dashboard.Metadata.GetMetadata<Microsoft.AspNetCore.Authorization.IAllowAnonymous>());
        var links = endpoints.Single(e => e.DisplayName?.Contains("/go/{slug}", StringComparison.Ordinal) == true);
        Assert.NotNull(links.Metadata.GetMetadata<Microsoft.AspNetCore.Authorization.IAllowAnonymous>());
    }

    [Fact]
    public async Task A_request_reaches_kestrel_as_sent_and_a_streamed_answer_goes_out_as_it_is_written()
    {
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(k => k.Listen(IPAddress.Loopback, KestrelPort));
        await using WebApplication app = builder.Build();
        app.Map("/echo/{**rest}", Serve((request, ip, _) => Task.FromResult(Response.JsonOf(new JsObject
        {
            ["url"] = request.Url,
            ["method"] = request.Method,
            ["ip"] = ip,
            ["type"] = request.Headers.Get("content-type"),
            ["body"] = request.Text(),
            ["cookie"] = request.Headers.Get("cookie"),
        }))));
        app.Map("/stream", Serve((_, _, _) => Task.FromResult(new Response(async (stream, ct) =>
        {
            await stream.WriteAsync(Encoding.UTF8.GetBytes("first,"), ct);
            await stream.FlushAsync(ct);
            await stream.WriteAsync(Encoding.UTF8.GetBytes("second"), ct);
        }, 200, new Http.Headers { ["content-type"] = "text/plain" }))));
        app.Map("/broken", Serve((_, _, _) => Task.FromResult(new Response((_, _) => throw new InvalidOperationException("no body")))));
        app.Map("/cookies", Serve((_, _, _) =>
        {
            var headers = new Http.Headers();
            headers.Append("set-cookie", "a=1; Path=/");
            headers.Append("set-cookie", "b=2; Path=/");
            return Task.FromResult(new Response("ok", 200, headers));
        }));
        await app.StartAsync();
        try
        {
            // The target as sent, its encoding kept and its dot segments resolved as new URL resolves them; the scheme from X-Forwarded-Proto.
            string raw = await RawAsync("POST /echo/%C3%A9/./x?q=a%20b HTTP/1.1\r\nHost: stats.example.com\r\nX-Forwarded-Proto: https\r\nCookie: a=1\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
            Assert.StartsWith("HTTP/1.1 200", raw, StringComparison.Ordinal);
            var echoed = (JsObject)Json.Parse(raw[(raw.IndexOf("\r\n\r\n", StringComparison.Ordinal) + 4)..])!;
            Assert.Equal("https://stats.example.com/echo/%C3%A9/x?q=a%20b", echoed.Str("url"));
            Assert.Equal("POST", echoed.Str("method"));
            Assert.Equal("127.0.0.1", echoed.Str("ip"));
            Assert.Equal("text/plain;charset=UTF-8", echoed.Str("type"));
            Assert.Equal("hello", echoed.Str("body"));
            Assert.Equal("a=1", echoed.Str("cookie"));
            Assert.Contains("Content-Length: ", raw, StringComparison.Ordinal);

            using var client = new HttpClient();
            var streamed = await client.GetAsync("http://127.0.0.1:" + KestrelPort + "/stream");
            Assert.Equal("first,second", await streamed.Content.ReadAsStringAsync());
            Assert.True(streamed.Headers.TransferEncodingChunked);

            Assert.Equal(HttpStatusCode.InternalServerError, (await client.GetAsync("http://127.0.0.1:" + KestrelPort + "/broken")).StatusCode);

            var cookies = await client.GetAsync("http://127.0.0.1:" + KestrelPort + "/cookies");
            Assert.Equal(["a=1; Path=/", "b=2; Path=/"], cookies.Headers.GetValues("Set-Cookie"));

            string head = await RawAsync("HEAD /echo/x HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            Assert.StartsWith("HTTP/1.1 200", head, StringComparison.Ordinal);
            Assert.EndsWith("\r\n\r\n", head, StringComparison.Ordinal);
        }
        finally
        {
            await app.StopAsync();
        }
    }

    private static RequestDelegate Serve(RequestHandler handler) => context => RunlightHttp.ServeAsync(context, handler);

    /// <summary>Sends bytes as they are over a socket and reads the whole answer, as HttpClient would not send them.</summary>
    private static async Task<string> RawAsync(string request)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, KestrelPort);
        NetworkStream stream = tcp.GetStream();
        await stream.WriteAsync(Encoding.Latin1.GetBytes(request));
        using var reader = new StreamReader(stream, Encoding.UTF8);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        return await reader.ReadToEndAsync(cts.Token);
    }
}
