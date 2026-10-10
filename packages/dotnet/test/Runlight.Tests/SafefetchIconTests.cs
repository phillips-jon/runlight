using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>
/// Ports safefetch.test.ts, replays the address checks and icon links in fixtures/outbound.json,
/// and covers each hop's checks and a site icon's fetches with their caps.
/// </summary>
public sealed class SafefetchIconTests
{
    /// <summary>A DNS stand-in.</summary>
    private static Func<string, Task<IReadOnlyList<string>>> Dns(Dictionary<string, string[]> names) =>
        name => Task.FromResult<IReadOnlyList<string>>(names.TryGetValue(name, out var found) ? found : []);

    private static PublicFetchInit Init(Func<string, Task<IReadOnlyList<string>>>? lookup = null, int redirects = 0) =>
        new() { TimeoutMs = 2000, Lookup = lookup, Redirects = redirects };

    private static Headers H(string name, string value) => new() { [name] = value };

    [Fact]
    public void Only_addresses_on_the_public_internet_count_as_public()
    {
        foreach (string ip in new[] { "93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "2a00:1450:4001:82a::200e" })
        {
            Assert.True(Safefetch.PublicAddress(ip), ip);
        }
        foreach (string ip in new[]
        {
            "127.0.0.1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
            "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:169.254.169.254", "64:ff9b::a00:1",
            "2002:a00:1::", "2001:db8::1", "2001:0:4136:e378::1", "[::1]", "not an address", "1.2.3", "1.2.3.256",
        })
        {
            Assert.False(Safefetch.PublicAddress(ip), ip);
        }
    }

    [Fact]
    public void Address_checks_match_TypeScript()
    {
        var failures = new List<string>();
        foreach (JsObject c in Load("outbound").Arr("ips")!)
        {
            if (Safefetch.PublicAddress(c.Str("ip")!) != c.Bool("public"))
            {
                failures.Add(c.Str("ip")!);
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public async Task A_public_fetch_never_reaches_the_installs_own_network_however_the_address_is_written()
    {
        // Something listening locally, which none of these may reach.
        using var inside = new TcpListener(IPAddress.Loopback, 0);
        inside.Start();
        int port = ((IPEndPoint)inside.LocalEndpoint).Port;
        using var fetcher = new HttpClientFetcher();
        try
        {
            foreach (string url in new[] { $"http://127.0.0.1:{port}/", $"https://127.0.0.1:{port}/", $"https://[::1]:{port}/", $"https://[::ffff:127.0.0.1]:{port}/", $"https://localhost:{port}/", $"https://LOCALHOST.:{port}/", $"https://app.localhost:{port}/" })
            {
                await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.PublicFetchAsync(url, Init(), fetcher));
            }
            Assert.False(inside.Pending(), "nothing connected");
            Assert.True(await Safefetch.ResolvesPrivatelyAsync("localhost"));
            Assert.False(await Safefetch.ResolvesPrivatelyAsync("name.that.does.not.resolve.invalid"));
            Assert.Empty(await Safefetch.PublicAddressesAsync("name.that.does.not.resolve.invalid"));
            Assert.Equal(["8.8.8.8"], await Safefetch.PublicAddressesAsync("8.8.8.8"));
            Assert.Empty(await Safefetch.PublicAddressesAsync("localhost"));
        }
        finally
        {
            inside.Stop();
        }
    }

    [Fact]
    public async Task The_checked_addresses_are_pinned()
    {
        var fetcher = new FakeFetcher((_, _) => new Response("ok"));
        var init = Init(Dns(new() { ["example.com"] = ["93.184.215.14", "2606:4700::1111"] }));
        init.Headers = H("user-agent", "Runlight");
        init.MaxBytes = 10;
        var answer = await Safefetch.PublicFetchAsync("https://Example.com/icon", init, fetcher);
        Assert.Equal("ok", answer.Text());
        var seen = fetcher.Requests[0];
        Assert.Equal(["example.com:443:93.184.215.14,[2606:4700::1111]"], seen.Init.Resolve);
        Assert.Equal("manual", seen.Init.Redirect);
        Assert.Equal(10, seen.Init.MaxBytes);
        Assert.Equal(("GET", "https://example.com/icon", "{\"user-agent\":\"Runlight\"}"), (seen.Method, seen.Url, J(seen.Headers)));

        var literal = new FakeFetcher((_, _) => new Response("ok"));
        await Safefetch.PublicFetchAsync("https://93.184.215.14:8443/", Init(Dns([])), literal);
        Assert.Empty(literal.Requests[0].Init.Resolve); // an address needs no pin
    }

    [Fact]
    public async Task A_name_with_any_private_address_is_refused()
    {
        var fetcher = new FakeFetcher((_, _) => new Response("ok"));
        foreach (var (name, addresses) in new[] { ("inside.example", new[] { "10.0.0.5" }), ("mixed.example", new[] { "93.184.215.14", "169.254.169.254" }), ("mapped.example", new[] { "::ffff:127.0.0.1" }) })
        {
            var error = await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.PublicFetchAsync($"https://{name}/", Init(Dns(new() { [name] = addresses })), fetcher));
            Assert.Equal(name + " is not a public address", error.Message);
        }
        Assert.Empty(fetcher.Requests);
        await Assert.ThrowsAsync<FetchException>(() => Safefetch.PublicFetchAsync("https://nowhere.example/", Init(Dns([])), fetcher));
    }

    [Fact]
    public async Task Redirects_are_followed_by_hand_under_the_same_rules()
    {
        var dns = Dns(new() { ["a.example"] = ["93.184.215.14"], ["b.example"] = ["1.1.1.1"], ["inside.example"] = ["192.168.0.2"] });
        static FakeFetcher Hops(params Response[] answers)
        {
            var queue = new Queue<Response>(answers);
            return new FakeFetcher((_, _) => queue.TryDequeue(out var next) ? next : new Response("end"));
        }

        var fetcher = Hops(Response.Redirect("/next", 301), Response.Redirect("https://b.example/last", 302), new Response("done"));
        var answer = await Safefetch.PublicFetchAsync("https://a.example/", Init(dns, 3), fetcher);
        Assert.Equal("done", answer.Text());
        Assert.Equal(["https://a.example/", "https://a.example/next", "https://b.example/last"], fetcher.Requests.Select(r => r.Url));
        Assert.Equal(["b.example:443:1.1.1.1"], fetcher.Requests[2].Init.Resolve);

        fetcher = Hops(Response.Redirect("https://b.example/", 302));
        Assert.Equal(302, (await Safefetch.PublicFetchAsync("https://a.example/", Init(dns), fetcher)).Status); // a redirect past the last comes back as it is

        foreach (var (location, what) in new[] { ("https://10.0.0.1/", "10.0.0.1"), ("https://inside.example/", "inside.example"), ("http://b.example/", "http://b.example/"), ("https://[fe80::1]/", "fe80::1") })
        {
            var error = await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.PublicFetchAsync("https://a.example/", Init(dns, 3), Hops(Response.Redirect(location))));
            Assert.Equal(what + " is not a public address", error.Message);
        }
    }

    [Fact]
    public async Task An_install_is_fetched_only_on_the_public_internet_or_as_http_on_this_machine_when_allowed()
    {
        var fetcher = new FakeFetcher((_, _) => new Response("ok"));
        var post = new PublicFetchInit { TimeoutMs = 2000, Method = "POST", BodyText = "{}", Headers = H("content-type", "application/json") };
        Assert.Equal("ok", (await Safefetch.InstallFetchAsync("https://hub.example/x", post, false, fetcher)).Text());
        Assert.Equal("POST", fetcher.Requests[0].Method);
        Assert.Equal("{}", fetcher.Requests[0].Body);
        Assert.Equal(["hub.example:443:93.184.215.14"], fetcher.Requests[0].Init.Resolve);
        // Trying things out on one machine: plain http to localhost and 127.0.0.1, only when allowed.
        foreach (string local in new[] { "http://localhost:4100/runlight", "http://127.0.0.1/api" })
        {
            Assert.True(Safefetch.InstallAddress(local, true));
            Assert.False(Safefetch.InstallAddress(local, false));
            Assert.Equal("ok", (await Safefetch.InstallFetchAsync(local, Init(), true, fetcher)).Text());
            await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.InstallFetchAsync(local, Init(), false, fetcher));
        }
        Assert.Empty(fetcher.Requests[2].Init.Resolve); // a local address is not pinned
        foreach (string refused in new[] { "http://hub.example/", "https://localhost/", "https://127.0.0.1/", "http://169.254.169.254/latest/meta-data", "http://10.0.0.1/", "http://localhost.evil.example/" })
        {
            await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.InstallFetchAsync(refused, Init(), true, fetcher));
        }
        fetcher.Dns = _ => ["10.0.0.5"];
        await Assert.ThrowsAsync<PrivateAddressError>(() => Safefetch.InstallFetchAsync("https://inside.example/", Init(), false, fetcher)); // a name for a private address
        Assert.Equal(3, fetcher.Requests.Count); // nothing refused was sent

        var redirected = new FakeFetcher((_, _) => Response.Redirect("http://169.254.169.254/latest/meta-data", 302));
        Assert.Equal(302, (await Safefetch.InstallFetchAsync("https://hub.example/", Init(redirects: 5), false, redirected)).Status); // a redirect comes back as it is, never followed
        Assert.Single(redirected.Requests);
        var posted = new FakeFetcher((_, _) => Response.Redirect("/elsewhere", 307));
        Assert.Equal(307, (await Safefetch.PublicFetchAsync("https://hub.example/", new PublicFetchInit { TimeoutMs = 2000, Method = "POST", Redirects = 3 }, posted)).Status); // only a GET follows redirects
    }

    [Fact]
    public async Task Running_out_of_time_says_so()
    {
        var dns = Dns(new() { ["a.example"] = ["1.1.1.1"] });
        var fetcher = new FakeFetcher((Func<string, FetchInit, Response>)((_, _) => throw new FetchException("Operation timed out", true)));
        var error = await Assert.ThrowsAsync<FetchException>(() => Safefetch.PublicFetchAsync("https://a.example/", Init(dns), fetcher));
        Assert.True(error.TimedOut);
        Assert.Equal("The operation was aborted due to timeout", error.Message);
        var refused = new FakeFetcher((Func<string, FetchInit, Response>)((_, _) => throw new FetchException("Connection refused")));
        error = await Assert.ThrowsAsync<FetchException>(() => Safefetch.PublicFetchAsync("https://a.example/", Init(dns), refused));
        Assert.Equal("Connection refused", error.Message);
    }

    [Fact]
    public void Icon_links_match_TypeScript()
    {
        foreach (JsObject c in Load("outbound").Arr("icons")!)
        {
            Assert.Equal(J(c.Get("links")), J(Icon.IconLinks(c.Str("html")!, c.Str("base")!).Cast<object?>().ToList()));
        }
    }

    [Fact]
    public async Task The_best_linked_icon_is_fetched_with_its_caps()
    {
        // An address as the origin, so no name is looked up.
        const string origin = "https://93.184.215.14";
        var fetcher = new FakeFetcher((url, _) => url switch
        {
            "https://93.184.215.14/" => new Response("<link rel=\"apple-touch-icon\" href=\"/touch.png\"><link rel=\"icon\" href=\"/i.svg\">", 200, H("content-type", "text/html; charset=utf-8")),
            "https://93.184.215.14/touch.png" => new Response("<html>", 200, H("content-type", "text/html")),
            "https://93.184.215.14/i.svg" => new Response("<svg/>", 200, H("content-type", "Image/SVG+xml; charset=utf-8")),
            _ => new Response("", 404),
        });
        const long now = 1_791_471_600_000;
        var icon = await Icon.FetchIconAsync(origin, now, fetcher);
        Assert.NotNull(icon);
        Assert.Equal(("<svg/>", "image/svg+xml"), (Js.Decode(icon.Body), icon.Type));
        Assert.Equal(["https://93.184.215.14/", "https://93.184.215.14/touch.png", "https://93.184.215.14/i.svg"], fetcher.Requests.Select(r => r.Url));
        Assert.Equal((200_000L, true), (fetcher.Requests[0].Init.MaxBytes, fetcher.Requests[0].Init.Truncate));
        Assert.Equal(262_144L, fetcher.Requests[1].Init.MaxBytes);
        Assert.False(fetcher.Requests[1].Init.Truncate, "an image must arrive whole");
        Assert.Equal("Runlight (+https://runlight.sh)", fetcher.Requests[0].Headers.Str("user-agent"));
        Assert.True(fetcher.Requests[0].TimeoutMs <= 4000);

        // Cached for a day.
        Assert.Same(icon, await Icon.FetchIconAsync(origin, now + 86_399_000, fetcher));
        Assert.Equal(3, fetcher.Requests.Count);
        await Icon.FetchIconAsync(origin, now + 86_400_000, fetcher);
        Assert.Equal(6, fetcher.Requests.Count); // and looked up again after it
    }

    [Fact]
    public async Task Favicon_is_the_fallback_and_no_icon_is_remembered_for_an_hour()
    {
        const string origin = "https://1.1.1.1";
        var fetcher = new FakeFetcher((url, _) => url == "https://1.1.1.1/favicon.ico" ? new Response("", 200, H("content-type", "image/x-icon")) : new Response("nope", 500));
        const long now = 1_791_471_600_000;
        Assert.Null(await Icon.FetchIconAsync(origin, now, fetcher)); // an empty image is no icon
        Assert.Equal(["https://1.1.1.1/", "https://1.1.1.1/favicon.ico"], fetcher.Requests.Select(r => r.Url));
        Assert.Null(await Icon.FetchIconAsync(origin, now + 3_599_000, fetcher));
        Assert.Equal(2, fetcher.Requests.Count);
        await Icon.FetchIconAsync(origin, now + 3_600_000, fetcher);
        Assert.Equal(4, fetcher.Requests.Count);
    }

    [Fact]
    public async Task A_private_origin_is_never_fetched()
    {
        var fetcher = new FakeFetcher((_, _) => new Response("x", 200, H("content-type", "image/png")));
        Assert.Null(await Icon.FetchIconAsync("https://192.168.1.1", 0, fetcher));
        Assert.Empty(fetcher.Requests);
    }

    [Fact]
    public void Rate_limit_counts_each_address_per_minute()
    {
        long now = 60_000;
        var limit = new RateLimit(2, () => now);
        Assert.True(limit.Allow("203.0.113.1"));
        Assert.True(limit.Allow("203.0.113.1"));
        Assert.False(limit.Allow("203.0.113.1"));
        Assert.True(limit.Allow("203.0.113.2"));
        Assert.True(limit.Allow(""), "no address is not limited");
        now += 60_000;
        Assert.True(limit.Allow("203.0.113.1"), "a new minute starts afresh");
    }
}
