using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Data;

namespace Runlight.Mail;

/// <summary>
/// A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
/// relays), with AUTH PLAIN, over System.Net.Sockets.
/// </summary>
public static partial class Smtp
{
    /// <summary>Each reply must come within this long.</summary>
    private const int ReplyTimeoutMs = 20_000;

    [GeneratedRegex("^([^\\n\\r\\u2028\\u2029]*)<([^\\n\\r\\u2028\\u2029]+)>\\z", RegexOptions.CultureInvariant)]
    private static partial Regex NamedAddress();

    private static string EncodeWord(string text) =>
        text.All(c => c >= 0x20 && c <= 0x7e) ? text : "=?UTF-8?B?" + Convert.ToBase64String(Js.Utf8(text)) + "?=";

    /// <summary>Base64 in lines of 76, each ending in CRLF, as <c>.replace(/.{1,76}/g, "$&amp;\r\n")</c> writes it.</summary>
    private static string Wrap(string text)
    {
        var b = new StringBuilder(text.Length + (text.Length / 76 * 2) + 2);
        for (int i = 0; i < text.Length; i += 76)
        {
            b.Append(text, i, Math.Min(76, text.Length - i)).Append("\r\n");
        }
        return b.ToString();
    }

    /// <summary>The message as MIME: text and HTML alternatives, both base64. Public for its test.</summary>
    /// <param name="m">The message.</param>
    /// <param name="from">The From address, with its name.</param>
    /// <param name="now">Milliseconds; the clock when null.</param>
    /// <param name="uuid">Stands in for crypto.randomUUID() in tests.</param>
    public static string Mime(JsObject m, string from, long? now = null, Func<string>? uuid = null)
    {
        uuid ??= () => Guid.NewGuid().ToString("D", CultureInfo.InvariantCulture);
        long ms = now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        string boundary = "rl-" + uuid();
        string[] at = Js.String(m.Get("from")).Split('@');
        string domain = at.Length > 1 ? at[1] : "runlight.local";
        var named = NamedAddress().Match(from);
        string fromHeader = named.Success ? EncodeWord(Js.Trim(named.Groups[1].Value)) + " <" + named.Groups[2].Value + ">" : from;
        var headers = new List<string>
        {
            "From: " + fromHeader,
            "To: " + Js.String(m.Get("to")),
            "Subject: " + EncodeWord(Js.String(m.Get("subject"))),
            // Date's toUTCString(), with +0000 for GMT.
            "Date: " + DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("ddd, dd MMM yyyy HH:mm:ss", CultureInfo.InvariantCulture) + " +0000",
            "Message-ID: <" + uuid() + "@" + domain + ">",
            "MIME-Version: 1.0",
        };
        foreach (var (k, v) in m.Obj("headers") ?? [])
        {
            headers.Add(k + ": " + Js.String(v).Replace("\r", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal));
        }
        headers.Add("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"");
        return string.Join("\r\n",
            string.Join("\r\n", headers),
            "",
            "--" + boundary,
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            Wrap(Convert.ToBase64String(Js.Utf8(Js.String(m.Get("text"))))),
            "--" + boundary,
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            Wrap(Convert.ToBase64String(Js.Utf8(Js.String(m.Get("html"))))),
            "--" + boundary + "--",
            "");
    }

    /// <summary>
    /// Sends one message. Each reply must come within 20 s, and the whole send
    /// within the deadline (60 s), so a server that trickles a line now and then
    /// cannot hold the scheduled check that sends reports. Its deadline is a
    /// parameter for its test, as are the clock and UUIDs the MIME is written with.
    /// </summary>
    /// <param name="config">host, port, security, username, and password.</param>
    /// <param name="m">The message.</param>
    /// <param name="from">The From address, with its name.</param>
    /// <param name="deadline">The whole send's limit, in milliseconds.</param>
    /// <param name="now">Milliseconds for the Date header; the clock when null.</param>
    /// <param name="uuid">Stands in for crypto.randomUUID() in tests.</param>
    /// <param name="cancellationToken">Stops the send.</param>
    public static async Task SendAsync(JsObject config, JsObject m, string from, int deadline = 60_000, long? now = null, Func<string>? uuid = null, CancellationToken cancellationToken = default)
    {
        string host = Js.Trim(Js.String(config.Get("host")));
        string security = config.Str("security") is { Length: > 0 } s ? s : "starttls";
        double number = Js.Number(config.Get("port") is { } p ? Js.String(p) : "");
        int port = double.IsNaN(number) || number == 0 ? (security == "tls" ? 465 : 587) : (int)Js.ToLong(number);
        string late = "SMTP: " + host + ":" + Js.Str(port) + " took longer than " + Json.Number(Js.Round(deadline / 1000.0)) + " s";
        using var session = new SmtpSession(host, port, SmtpSession.After(deadline), late);
        await ConverseAsync(session, config, m, from, security, now, uuid, cancellationToken).ConfigureAwait(false);
    }

    private static async Task ConverseAsync(SmtpSession s, JsObject config, JsObject m, string from, string security, long? now, Func<string>? uuid, CancellationToken ct)
    {
        await s.ConnectAsync(security == "tls", ReplyTimeoutMs, ct).ConfigureAwait(false);
        async Task<(int Code, string Text)> Expect(int[] codes, string what)
        {
            var reply = (await s.NextAsync(ReplyTimeoutMs, false, ct).ConfigureAwait(false))!.Value;
            if (!codes.Contains(reply.Code))
            {
                throw new MailError(Js.Slice("SMTP " + what + ": " + Js.Str(reply.Code) + " " + reply.Text, 0, 300));
            }
            return reply;
        }
        await Expect([220], "greeting").ConfigureAwait(false);
        string[] parts = from.Split('@');
        string name = parts.Length > 1 && parts[1].EndsWith('>') ? parts[1][..^1] : (parts.Length > 1 ? parts[1] : "");
        name = name.Length > 0 ? name : "localhost";
        await s.WriteAsync("EHLO " + name, ct).ConfigureAwait(false);
        var ehlo = await Expect([250], "EHLO").ConfigureAwait(false);
        if (security == "starttls")
        {
            if (!JsPattern.AsciiLower(ehlo.Text).Contains("starttls", StringComparison.Ordinal))
            {
                throw new MailError("SMTP: the server does not offer STARTTLS; pick tls or none", "smtp_starttls", []);
            }
            await s.WriteAsync("STARTTLS", ct).ConfigureAwait(false);
            await Expect([220], "STARTTLS").ConfigureAwait(false);
            await s.StartTlsAsync(ct).ConfigureAwait(false);
            await s.WriteAsync("EHLO " + name, ct).ConfigureAwait(false);
            await Expect([250], "EHLO").ConfigureAwait(false);
        }
        string username = config.Str("username") ?? "";
        if (username.Length > 0)
        {
            string password = config.Str("password") ?? "";
            await s.WriteAsync("AUTH PLAIN " + Convert.ToBase64String(Js.Utf8("\0" + username + "\0" + password)), ct).ConfigureAwait(false);
            await Expect([235], "sign-in").ConfigureAwait(false);
        }
        await s.WriteAsync("MAIL FROM:<" + Js.String(m.Get("from")) + ">", ct).ConfigureAwait(false);
        await Expect([250], "MAIL FROM").ConfigureAwait(false);
        await s.WriteAsync("RCPT TO:<" + Js.String(m.Get("to")) + ">", ct).ConfigureAwait(false);
        await Expect([250, 251], "RCPT TO").ConfigureAwait(false);
        await s.WriteAsync("DATA", ct).ConfigureAwait(false);
        await Expect([354], "DATA").ConfigureAwait(false);
        // A line starting with a dot gets a second one, so it is not read as the end.
        await s.WriteRawAsync(Mime(m, from, now, uuid).Replace("\r\n.", "\r\n..", StringComparison.Ordinal) + "\r\n.\r\n", ct).ConfigureAwait(false);
        await Expect([250], "message").ConfigureAwait(false);
        await s.WriteAsync("QUIT", ct).ConfigureAwait(false);
        // Wait for the goodbye, but never fail a sent message over it.
        try
        {
            await s.NextAsync(2000, true, ct).ConfigureAwait(false);
        }
        catch (MailError error) when (error.Code != "mail_slow")
        {
        }
    }
}
