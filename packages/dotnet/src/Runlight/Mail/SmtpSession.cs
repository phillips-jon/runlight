using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Mail;

/// <summary>
/// One SMTP connection for <see cref="Smtp.SendAsync"/>: the socket, the replies read from it
/// (multi-line included, one at a time), and the whole send's deadline, which every wait is held to.
/// </summary>
internal sealed class SmtpSession(string host, int port, long deadline, string lateMessage) : IDisposable
{
    private readonly List<byte> _buffer = [];
    private readonly List<string> _lines = [];
    private readonly byte[] _chunk = new byte[8192];
    private Socket? _socket;
    private Stream? _stream;
    // A read still waiting for bytes after a wait ran out; the next wait picks it up.
    private Task<int>? _pending;

    /// <summary>A Stopwatch timestamp this many milliseconds from now.</summary>
    internal static long After(double ms) => Stopwatch.GetTimestamp() + (long)(ms * Stopwatch.Frequency / 1000);

    private static double Until(long timestamp) => (timestamp - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency;

    private MailError Late()
    {
        Close();
        return new MailError(lateMessage, "mail_slow", new JsObject { ["host"] = host + ":" + Js.Str(port) });
    }

    /// <summary>Milliseconds left before the deadline.</summary>
    private double Left() => Until(deadline);

    private static MailError Closed() => new("SMTP: the server closed the connection");

    public async Task ConnectAsync(bool tls, int timeoutMs, CancellationToken cancellationToken)
    {
        double wait = Math.Min(timeoutMs, Left());
        if (wait <= 0)
        {
            throw Late();
        }
        string where = host + ":" + Js.Str(port);
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromMilliseconds(Math.Ceiling(wait)));
        string? detail = null;
        try
        {
            await socket.ConnectAsync(host, port, cts.Token).ConfigureAwait(false);
            _socket = socket;
            _stream = new NetworkStream(socket, ownsSocket: true);
            if (tls)
            {
                var ssl = new SslStream(_stream, leaveInnerStreamOpen: false);
                _stream = ssl;
                await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = host }, cts.Token).ConfigureAwait(false);
            }
            return;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            detail = wait >= timeoutMs ? "timed out" : "connection failed";
        }
        catch (SocketException error)
        {
            detail = error.Message.Length > 0 ? error.Message : "connection failed";
        }
        catch (Exception error) when (error is AuthenticationException or IOException)
        {
            detail = error.Message.Length > 0 ? error.Message : "connection failed";
        }
        Close();
        socket.Dispose();
        if (Left() <= 0)
        {
            throw Late();
        }
        throw new MailError("SMTP: could not connect to " + where + ": " + detail, "mail_unreachable", new JsObject { ["host"] = where, ["detail"] = detail });
    }

    public Task WriteAsync(string line, CancellationToken cancellationToken) => WriteRawAsync(line + "\r\n", cancellationToken);

    public async Task WriteRawAsync(string data, CancellationToken cancellationToken)
    {
        if (_stream == null)
        {
            throw Closed();
        }
        double wait = Left();
        if (wait <= 0)
        {
            throw Late();
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromMilliseconds(Math.Ceiling(wait)));
        try
        {
            await _stream.WriteAsync(Js.Utf8(data), cts.Token).ConfigureAwait(false);
            await _stream.FlushAsync(cts.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException || (error is OperationCanceledException && !cancellationToken.IsCancellationRequested))
        {
            if (Left() <= 0)
            {
                throw Late();
            }
            Close();
            throw Closed();
        }
    }

    /// <summary>
    /// The next whole reply. Throws when none comes within <paramref name="timeoutMs"/> (or, with
    /// <paramref name="quiet"/>, gives null then), and a mail_slow error once the deadline passes.
    /// </summary>
    public async Task<(int Code, string Text)?> NextAsync(int timeoutMs, bool quiet, CancellationToken cancellationToken)
    {
        long idleUntil = After(timeoutMs);
        for (; ; )
        {
            int at;
            while ((at = CrLf()) >= 0)
            {
                byte[] line = _buffer.GetRange(0, at).ToArray();
                _buffer.RemoveRange(0, at + 2);
                _lines.Add(line.Length > 4 ? Js.Decode(line.AsSpan(4)) : "");
                if (line.Length < 4 || line[3] != (byte)'-')
                {
                    int head = Math.Min(3, line.Length);
                    int code = head > 0 ? 0 : -1;
                    for (int i = 0; i < head; i++)
                    {
                        if (line[i] < '0' || line[i] > '9')
                        {
                            code = -1;
                            break;
                        }
                        code = code * 10 + (line[i] - '0');
                    }
                    string text = string.Join(' ', _lines);
                    _lines.Clear();
                    return (code, text);
                }
                // Activity resets the idle timer, as Node's socket timeout does.
                idleUntil = After(timeoutMs);
            }
            if (_stream == null)
            {
                throw Closed();
            }
            double deadlineLeft = Left();
            if (deadlineLeft <= 0)
            {
                throw Late();
            }
            double idleLeft = Until(idleUntil);
            if (idleLeft <= 0)
            {
                if (quiet)
                {
                    return null;
                }
                Close();
                throw new MailError("SMTP: timed out");
            }
            double wait = Math.Min(deadlineLeft, idleLeft);
            _pending ??= _stream.ReadAsync(_chunk, 0, _chunk.Length, CancellationToken.None);
            using (var delayCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                var delay = Task.Delay(TimeSpan.FromMilliseconds(Math.Ceiling(wait)), delayCts.Token);
                var done = await Task.WhenAny(_pending, delay).ConfigureAwait(false);
                await delayCts.CancelAsync().ConfigureAwait(false);
                if (done != _pending)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    // Nothing came in the time left; the checks above decide what that means.
                    continue;
                }
            }
            var read = _pending;
            _pending = null;
            int n;
            try
            {
                n = await read.ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException)
            {
                Close();
                throw Closed();
            }
            if (n == 0)
            {
                Close();
                throw Closed();
            }
            _buffer.AddRange(_chunk.AsSpan(0, n));
            idleUntil = After(timeoutMs);
        }
    }

    private int CrLf()
    {
        for (int i = 0; i + 1 < _buffer.Count; i++)
        {
            if (_buffer[i] == '\r' && _buffer[i + 1] == '\n')
            {
                return i;
            }
        }
        return -1;
    }

    /// <summary>Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader would.</summary>
    public async Task StartTlsAsync(CancellationToken cancellationToken)
    {
        _buffer.Clear();
        _lines.Clear();
        double wait = Left();
        if (wait <= 0)
        {
            throw Late();
        }
        if (_stream == null)
        {
            throw Closed();
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromMilliseconds(Math.Ceiling(wait)));
        var ssl = new SslStream(_stream, leaveInnerStreamOpen: false);
        _stream = ssl;
        try
        {
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = host }, cts.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is AuthenticationException or IOException or SocketException || (error is OperationCanceledException && !cancellationToken.IsCancellationRequested))
        {
            if (Left() <= 0)
            {
                throw Late();
            }
            Close();
            throw new MailError("SMTP: TLS failed: " + (error.Message.Length > 0 ? error.Message : "handshake failed"));
        }
    }

    public void Close()
    {
        if (_pending != null)
        {
            // The read ends with the socket; its failure is expected and not worth a report.
            _pending.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            _pending = null;
        }
        _stream?.Dispose();
        _stream = null;
        _socket?.Dispose();
        _socket = null;
    }

    public void Dispose() => Close();
}
