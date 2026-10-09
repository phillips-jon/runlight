using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Http;

/// <summary>Fetches with <see cref="HttpClient"/>, following redirects itself so a pinned address holds for the first hop.</summary>
public sealed class HttpClientFetcher : IFetcher, IDisposable
{
    private static readonly HttpRequestOptionsKey<List<string>> PinsKey = new("runlight.resolve");
    private readonly HttpClient _client;

    public HttpClientFetcher()
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(15),
            UseCookies = false,
            ConnectCallback = ConnectAsync,
        };
        _client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public void Dispose() => _client.Dispose();

    private static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken cancellationToken)
    {
        string host = context.DnsEndPoint.Host;
        int port = context.DnsEndPoint.Port;
        EndPoint target = context.DnsEndPoint;
        if (context.InitialRequestMessage.Options.TryGetValue(PinsKey, out var pins))
        {
            foreach (string pin in pins)
            {
                // host:port:address, the address perhaps in brackets.
                int first = pin.IndexOf(':', StringComparison.Ordinal);
                if (first < 0)
                {
                    continue;
                }
                int second = pin.IndexOf(':', first + 1);
                if (second < 0)
                {
                    continue;
                }
                string pinHost = pin[..first];
                string pinPort = pin[(first + 1)..second];
                string address = pin[(second + 1)..].Trim('[', ']');
                if (string.Equals(pinHost, host, StringComparison.OrdinalIgnoreCase) && pinPort == port.ToString(System.Globalization.CultureInfo.InvariantCulture)
                    && IPAddress.TryParse(address, out var ip))
                {
                    target = new IPEndPoint(ip, port);
                    break;
                }
            }
        }
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(target, cancellationToken).ConfigureAwait(false);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    public async Task<Response> FetchAsync(string url, FetchInit? init = null, CancellationToken cancellationToken = default)
    {
        init ??= new FetchInit();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(init.TimeoutMs);
        string method = init.Method.ToUpperInvariant();
        string current = url;
        byte[]? body = init.Body;
        try
        {
            for (int hop = 0; ; hop++)
            {
                var scheme = new Uri(current).Scheme;
                if (scheme != "http" && scheme != "https")
                {
                    throw new FetchException("fetch failed: unsupported protocol");
                }
                using var message = new HttpRequestMessage(new HttpMethod(method), current);
                if (hop == 0 && init.Resolve.Count > 0)
                {
                    message.Options.Set(PinsKey, init.Resolve);
                }
                if (body != null && method != "GET" && method != "HEAD")
                {
                    message.Content = new ByteArrayContent(body);
                }
                foreach (var e in init.Headers.All())
                {
                    foreach (string v in e.Value)
                    {
                        if (!message.Headers.TryAddWithoutValidation(e.Key, v))
                        {
                            message.Content ??= new ByteArrayContent([]);
                            message.Content.Headers.TryAddWithoutValidation(e.Key, v);
                        }
                    }
                }
                using var answer = await _client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
                int status = (int)answer.StatusCode;
                if (init.Redirect != "manual" && status is 301 or 302 or 303 or 307 or 308 && answer.Headers.Location != null)
                {
                    if (hop >= 20)
                    {
                        throw new FetchException("fetch failed: redirect count exceeded");
                    }
                    current = new Uri(new Uri(current), answer.Headers.Location).AbsoluteUri;
                    if (status == 303 || ((status == 301 || status == 302) && method == "POST"))
                    {
                        method = method == "HEAD" ? "HEAD" : "GET";
                        body = null;
                    }
                    continue;
                }
                var headers = new Headers();
                foreach (var h in answer.Headers)
                {
                    foreach (string v in h.Value)
                    {
                        headers.Append(h.Key, v);
                    }
                }
                foreach (var h in answer.Content.Headers)
                {
                    foreach (string v in h.Value)
                    {
                        headers.Append(h.Key, v);
                    }
                }
                byte[] received = await ReadAsync(answer, init, timeout.Token).ConfigureAwait(false);
                return new Response(received, status, headers);
            }
        }
        catch (OperationCanceledException e) when (!cancellationToken.IsCancellationRequested)
        {
            throw new FetchException("The operation was aborted due to timeout", true, e);
        }
        catch (HttpRequestException e)
        {
            throw new FetchException("fetch failed", false, e);
        }
        catch (UriFormatException e)
        {
            throw new FetchException("fetch failed", false, e);
        }
    }

    private static async Task<byte[]> ReadAsync(HttpResponseMessage answer, FetchInit init, CancellationToken cancellationToken)
    {
        var stream = await answer.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using (stream.ConfigureAwait(false))
        {
            using var output = new MemoryStream();
            var buffer = new byte[16384];
            while (true)
            {
                int n = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (n == 0)
                {
                    return output.ToArray();
                }
                if (init.MaxBytes is long max && output.Length + n > max)
                {
                    if (init.Truncate)
                    {
                        output.Write(buffer, 0, (int)(max - output.Length));
                        return output.ToArray();
                    }
                    throw new BodyTooLongException("Body over " + max.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes");
                }
                output.Write(buffer, 0, n);
            }
        }
    }
}
