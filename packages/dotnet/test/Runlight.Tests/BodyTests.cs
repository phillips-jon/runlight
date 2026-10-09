using System;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using Runlight.Http;
using Xunit;

namespace Runlight.Tests;

/// <summary>Capped reads: Body's checks, and the fetcher's MaxBytes, Truncate, and Resolve against a real server.</summary>
public sealed class BodyTests : IAsyncLifetime
{
    private TcpListener? _server;
    private Task? _loop;
    private int _port;

    /// <summary>A small HTTP/1.1 server: /bytes?n= answers n bytes of "a" as HTML, anything else its Host header.</summary>
    public ValueTask InitializeAsync()
    {
        _server = new TcpListener(IPAddress.Loopback, 0);
        _server.Start();
        _port = ((IPEndPoint)_server.LocalEndpoint).Port;
        _loop = Task.Run(async () =>
        {
            for (; ; )
            {
                TcpClient client;
                try
                {
                    client = await _server.AcceptTcpClientAsync();
                }
                catch (Exception)
                {
                    return;
                }
                _ = Task.Run(() => AnswerAsync(client));
            }
        });
        return ValueTask.CompletedTask;
    }

    private static async Task AnswerAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var head = new StringBuilder();
                var one = new byte[1];
                while (!head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal) && await stream.ReadAsync(one) == 1)
                {
                    head.Append((char)one[0]);
                }
                string[] lines = head.ToString().Split("\r\n");
                string target = lines[0].Split(' ')[1];
                string host = lines.Skip(1).Select(l => l.Split(':', 2)).Where(p => p.Length == 2 && p[0].Trim().Equals("host", StringComparison.OrdinalIgnoreCase)).Select(p => p[1].Trim()).FirstOrDefault() ?? "";
                byte[] body;
                string type = "text/plain";
                if (target.StartsWith("/bytes?n=", StringComparison.Ordinal))
                {
                    body = Encoding.ASCII.GetBytes(new string('a', int.Parse(target["/bytes?n=".Length..], CultureInfo.InvariantCulture)));
                    type = "text/html; charset=utf-8";
                }
                else
                {
                    body = Encoding.ASCII.GetBytes("host " + host);
                }
                await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n"));
                await stream.WriteAsync(body);
            }
            catch (Exception)
            {
                // A client that stopped reading part way.
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _server!.Stop();
        await _loop!;
    }

    [Fact]
    public async Task Text_is_read_up_to_the_cap()
    {
        Assert.Equal("hello", await Body.ReadTextCappedAsync(new Response("hello"), 5));
        Assert.Equal("{\"a\":1}", Json.Stringify(await Body.ReadJsonCappedAsync(new Response("{\"a\":1}"), 100)));
        Assert.Equal("a" + (char)0xFFFD + "b", await Body.ReadTextCappedAsync(new Response([(byte)'a', 0xff, (byte)'b']), 10)); // as TextDecoder reads bytes that are not UTF-8
        Assert.Equal("x", await Body.ReadTextCappedAsync(new Response([0xEF, 0xBB, 0xBF, (byte)'x']), 10));
        var error = await Assert.ThrowsAsync<BodyTooLongException>(() => Body.ReadTextCappedAsync(new Response("hello"), 4));
        Assert.Equal("Body over 4 bytes", error.Message);
    }

    [Fact]
    public async Task A_declared_length_over_the_cap_is_refused_unread()
    {
        await Assert.ThrowsAsync<BodyTooLongException>(() => Body.ReadTextCappedAsync(new Response("", 200, new Headers { ["content-length"] = "1000" }), 10));
    }

    [Fact]
    public async Task The_fetcher_stops_reading_past_max_bytes()
    {
        using var fetcher = new HttpClientFetcher();
        string url = $"http://127.0.0.1:{_port}/bytes?n=300000";
        Assert.Equal(300_000, (await (await fetcher.FetchAsync(url, new FetchInit { MaxBytes = 300_000 })).BytesAsync()).Length);
        var error = await Assert.ThrowsAsync<BodyTooLongException>(() => fetcher.FetchAsync(url, new FetchInit { MaxBytes = 100_000 }));
        Assert.Equal("Body over 100000 bytes", error.Message);
        var start = await fetcher.FetchAsync(url, new FetchInit { MaxBytes = 100_000, Truncate = true });
        Assert.Equal(200, start.Status);
        Assert.Equal(new string('a', 100_000), await start.TextAsync()); // with truncate, the start comes back
        Assert.Equal("text/html", start.Headers.Get("content-type")!.Split(';')[0]);
    }

    [Fact]
    public async Task The_fetcher_connects_to_the_pinned_address()
    {
        using var fetcher = new HttpClientFetcher();
        var answer = await fetcher.FetchAsync($"http://pinned.invalid:{_port}/", new FetchInit { Resolve = [$"pinned.invalid:{_port}:127.0.0.1"] });
        Assert.Equal($"host pinned.invalid:{_port}", await answer.TextAsync());
    }

    [Fact]
    public async Task The_fetcher_connects_to_a_pin_of_several_addresses()
    {
        // Safefetch pins every address a name gives, as curl's resolve takes them.
        using var fetcher = new HttpClientFetcher();
        var answer = await fetcher.FetchAsync($"http://pinned.invalid:{_port}/", new FetchInit { Resolve = [$"pinned.invalid:{_port}:127.0.0.1,[::1]"] });
        Assert.Equal($"host pinned.invalid:{_port}", await answer.TextAsync());
    }
}
