using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace Runlight.Tests;

/// <summary>
/// A fake SMTP server for the mail tests, as packages/php/tests/Support/smtp-server.php is, run in
/// this process on a port from 5300 to 5349. It serves one connection at a time, and after each
/// one hands back every byte the client sent.
/// </summary>
/// <remarks>
/// relay: answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS).
/// trickle: sends "220-still here" every 100 ms and never finishes its greeting.
/// </remarks>
public sealed class SmtpServer : IAsyncDisposable
{
    public const int FirstPort = 5300;
    public const int LastPort = 5349;

    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _stop = new();
    private readonly Channel<JsObject> _done = Channel.CreateUnbounded<JsObject>();
    private readonly Task _loop;
    private readonly string _mode;

    public SmtpServer(string mode = "relay")
    {
        _mode = mode;
        (_listener, Port) = Listen();
        _loop = Task.Run(ServeAsync);
    }

    public int Port { get; }

    /// <summary>A listener on the first free port of the range.</summary>
    public static (TcpListener Listener, int Port) Listen()
    {
        for (int port = FirstPort; port <= LastPort; port++)
        {
            var listener = new TcpListener(IPAddress.Loopback, port);
            try
            {
                listener.Start();
                return (listener, port);
            }
            catch (SocketException)
            {
                listener.Dispose();
            }
        }
        throw new InvalidOperationException("no free port from 5300 to 5349");
    }

    /// <summary>What the next finished connection received, waiting up to <paramref name="seconds"/> for it.</summary>
    public async Task<JsObject?> ConversationAsync(double seconds = 5)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try
        {
            return await _done.Reader.ReadAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private async Task ServeAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            Socket socket;
            try
            {
                socket = await _listener.AcceptSocketAsync(_stop.Token);
            }
            catch (Exception)
            {
                return;
            }
            using (socket)
            {
                var received = new List<byte>();
                JsObject result;
                try
                {
                    result = _mode == "trickle" ? await TrickleAsync(socket, received) : await RelayAsync(socket, received);
                }
                catch (Exception)
                {
                    result = new JsObject { ["received"] = Js.Decode(received.ToArray()) };
                }
                _done.Writer.TryWrite(result);
            }
        }
    }

    private async Task<JsObject> TrickleAsync(Socket socket, List<byte> received)
    {
        byte[] chunk = new byte[8192];
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                await socket.SendAsync(Encoding.ASCII.GetBytes("220-still here\r\n"), SocketFlags.None);
            }
            catch (SocketException)
            {
                break;
            }
            await Task.Delay(100);
            if (socket.Poll(0, SelectMode.SelectRead))
            {
                int n;
                try
                {
                    n = socket.Receive(chunk);
                }
                catch (SocketException)
                {
                    break;
                }
                if (n == 0)
                {
                    break;
                }
                received.AddRange(chunk.AsSpan(0, n));
            }
        }
        return new JsObject { ["received"] = Js.Decode(received.ToArray()), ["closed"] = true };
    }

    private async Task<JsObject> RelayAsync(Socket socket, List<byte> received)
    {
        async Task Send(string text) => await socket.SendAsync(Encoding.ASCII.GetBytes(text), SocketFlags.None);
        await Send("220 test ESMTP\r\n");
        byte[] chunk = new byte[8192];
        var buffer = new List<byte>();
        bool inData = false;
        bool open = true;
        while (open)
        {
            int n = await socket.ReceiveAsync(chunk, SocketFlags.None, _stop.Token);
            if (n == 0)
            {
                break;
            }
            received.AddRange(chunk.AsSpan(0, n));
            buffer.AddRange(chunk.AsSpan(0, n));
            int at;
            while ((at = IndexOfCrLf(buffer)) >= 0)
            {
                string line = Encoding.UTF8.GetString(buffer.GetRange(0, at).ToArray());
                buffer.RemoveRange(0, at + 2);
                if (inData)
                {
                    if (line == ".")
                    {
                        inData = false;
                        await Send("250 queued\r\n");
                    }
                    continue;
                }
                if (line.StartsWith("EHLO", StringComparison.Ordinal))
                {
                    await Send("250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n");
                }
                else if (line.StartsWith("AUTH PLAIN", StringComparison.Ordinal))
                {
                    string credentials = Encoding.UTF8.GetString(Convert.FromBase64String(line[11..]));
                    await Send(credentials == "\0jon\0pw" ? "235 ok\r\n" : "535 no\r\n");
                }
                else if (line == "DATA")
                {
                    inData = true;
                    await Send("354 go\r\n");
                }
                else if (line == "QUIT")
                {
                    await Send("221 bye\r\n");
                    open = false;
                    break;
                }
                else
                {
                    await Send("250 ok\r\n");
                }
            }
        }
        if (!open)
        {
            // Whatever the client still sends before it hangs up.
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
            wait.CancelAfter(TimeSpan.FromSeconds(1));
            try
            {
                int n;
                while ((n = await socket.ReceiveAsync(chunk, SocketFlags.None, wait.Token)) > 0)
                {
                    received.AddRange(chunk.AsSpan(0, n));
                }
            }
            catch (Exception)
            {
            }
        }
        return new JsObject { ["received"] = Js.Decode(received.ToArray()) };
    }

    private static int IndexOfCrLf(List<byte> buffer)
    {
        for (int i = 0; i + 1 < buffer.Count; i++)
        {
            if (buffer[i] == '\r' && buffer[i + 1] == '\n')
            {
                return i;
            }
        }
        return -1;
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        _listener.Stop();
        try
        {
            await _loop;
        }
        catch (Exception)
        {
        }
        _listener.Dispose();
        _stop.Dispose();
    }
}
