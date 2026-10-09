using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Mail;

/// <summary>
/// Sends mail through the service a site picked. A message is a <see cref="JsObject"/> shaped as TS's
/// Message: <c>to</c>, <c>from</c>, <c>fromName</c> (optional), <c>subject</c>, <c>html</c>, <c>text</c>,
/// and <c>headers</c> (optional extra headers, such as List-Unsubscribe, an object of strings). A config
/// is <c>service</c> plus its fields, every value a string, as typed in the dashboard.
/// </summary>
public static partial class Transports
{
    [GeneratedRegex("<Message>([^<]{1,200})</Message>", RegexOptions.CultureInvariant)]
    private static partial Regex XmlMessage();

    [GeneratedRegex("^http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?(/|\\z)", RegexOptions.CultureInvariant)]
    private static partial Regex LocalWebhook();

    /// <summary>Every service Runlight can send through, and what each needs. A fresh copy each time.</summary>
    public static List<JsObject> Services =>
    [
        Service("ses", "Amazon SES",
            Field("region", "Region", placeholder: "us-east-1"),
            Field("accessKeyId", "Access key ID"),
            Field("secretAccessKey", "Secret access key", secret: true)),
        Service("resend", "Resend", Field("apiKey", "API key", secret: true, placeholder: "re_...")),
        Service("postmark", "Postmark",
            Field("serverToken", "Server API token", secret: true),
            Field("stream", "Message stream", optional: true, placeholder: "outbound")),
        Service("sendgrid", "SendGrid", Field("apiKey", "API key", secret: true, placeholder: "SG....")),
        Service("mailgun", "Mailgun",
            Field("domain", "Sending domain", placeholder: "mg.example.com"),
            Field("apiKey", "API key", secret: true),
            Field("region", "Region", options: ["us", "eu"])),
        Service("brevo", "Brevo", Field("apiKey", "API key", secret: true, placeholder: "xkeysib-...")),
        Service("mailjet", "Mailjet",
            Field("apiKey", "API key"),
            Field("secretKey", "Secret key", secret: true)),
        Service("mailersend", "MailerSend", Field("apiKey", "API token", secret: true, placeholder: "mlsn....")),
        Service("sparkpost", "SparkPost",
            Field("apiKey", "API key", secret: true),
            Field("region", "Region", options: ["us", "eu"])),
        Service("smtp", "SMTP",
            Field("host", "Host", placeholder: "smtp.example.com"),
            Field("port", "Port", placeholder: "587"),
            Field("security", "Security", options: ["starttls", "tls", "none"]),
            Field("username", "Username", optional: true),
            Field("password", "Password", secret: true, optional: true)),
        Service("webhook", "Webhook",
            Field("url", "URL", placeholder: "https://example.com/hooks/mail"),
            Field("secret", "Signing secret", secret: true, optional: true)),
    ];

    private static JsObject Service(string id, string name, params JsObject[] fields) =>
        new() { ["id"] = id, ["name"] = name, ["fields"] = fields.Cast<object?>().ToList() };

    /// <summary>A field, its keys in the order the TS literal writes them.</summary>
    private static JsObject Field(string name, string label, bool secret = false, bool optional = false, string? placeholder = null, string[]? options = null)
    {
        var f = new JsObject { ["name"] = name, ["label"] = label };
        if (secret)
        {
            f["secret"] = true;
        }
        if (optional)
        {
            f["optional"] = true;
        }
        if (placeholder != null)
        {
            f["placeholder"] = placeholder;
        }
        if (options != null)
        {
            f["options"] = options.Cast<object?>().ToList();
        }
        return f;
    }

    /// <summary>The From address, with the sender's name when there is one.</summary>
    public static string Address(JsObject m)
    {
        string name = m.Str("fromName") ?? "";
        string from = Js.String(m.Get("from"));
        if (name.Length == 0)
        {
            return from;
        }
        var b = new StringBuilder(name.Length);
        foreach (char c in name)
        {
            if (c is not ('"' or '\\' or '\r' or '\n'))
            {
                b.Append(c);
            }
        }
        return b + " <" + from + ">";
    }

    /// <summary>
    /// The error a mail service explains itself with, from its JSON or XML reply,
    /// and never the raw body: a reply is shown to the dashboard, so an address
    /// that is not a mail service must not be able to put its page there.
    /// </summary>
    public static string ServiceMessage(string reply)
    {
        // JSON.parse fails, or reading a field of null does, and either way the XML form is tried.
        if (!Json.TryParse(reply, out object? parsed) || parsed == null)
        {
            var match = XmlMessage().Match(reply);
            return match.Success ? Js.Trim(match.Groups[1].Value) : "";
        }
        foreach (string name in MessageFields)
        {
            string text = First(parsed is JsObject o ? o.Prop(name) : Undefined.Value);
            if (text.Length > 0)
            {
                return Js.Slice(text, 0, 200);
            }
        }
        return "";
    }

    private static readonly string[] MessageFields = ["message", "Message", "error", "errors", "ErrorMessage"];

    private static string First(object? v) => v switch
    {
        string s => s,
        List<object?> list => First(list.Count > 0 ? list[0] : Undefined.Value),
        JsObject o => First(o.Prop("message")),
        _ => "",
    };

    /// <summary>POSTs to a service, with the errors the dashboard shows.</summary>
    private static async Task PostAsync(IFetcher fetcher, string url, JsObject headers, string body, bool explains, CancellationToken cancellationToken)
    {
        var h = new Headers();
        foreach (var (k, v) in headers)
        {
            h.Set(k, Js.String(v));
        }
        Response response;
        try
        {
            response = await fetcher.FetchAsync(url, new FetchInit { Method = "POST", Headers = h, BodyText = body, TimeoutMs = 20_000 }, cancellationToken).ConfigureAwait(false);
        }
        catch (FetchException error)
        {
            string host = new Url(url).Host;
            throw new MailError("Could not reach " + host + ": " + error.Message, "mail_unreachable", new JsObject { ["host"] = host, ["detail"] = error.Message });
        }
        if (response.Ok)
        {
            return;
        }
        string message = explains ? ServiceMessage(await response.TextAsync(cancellationToken).ConfigureAwait(false)) : "";
        string at = new Url(url).Host;
        string status = Js.Str(response.Status);
        throw new MailError(
            at + " answered " + status + (message.Length > 0 ? ": " + message : ""),
            "mail_refused",
            new JsObject { ["host"] = at, ["detail"] = status + (message.Length > 0 ? " " + message : "") });
    }

    private static JsObject JsonHeaders(JsObject? headers = null)
    {
        var all = new JsObject { ["content-type"] = "application/json" };
        foreach (var (k, v) in headers ?? [])
        {
            all[k] = v;
        }
        return all;
    }

    /// <summary>Basic auth over the UTF-8 bytes, so a key with any character is sent.</summary>
    private static string Basic(string user, string pass) => "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + pass));

    /// <summary>Checks a config has what its service needs, before anything is saved or sent.</summary>
    public static void CheckConfig(JsObject config)
    {
        object? id = config.Get("service");
        var service = Services.FirstOrDefault(s => Equals(s.Get("id"), id)) ?? throw new MailError("Pick a mail service", "mail_service", []);
        foreach (var f in service.Arr("fields")!.Cast<JsObject>())
        {
            string name = f.Str("name")!;
            string? value = config.Get(name) is { } v ? Js.String(v) : null;
            if (!f.Bool("optional") && (value == null || Js.Trim(value).Length == 0))
            {
                throw new MailError("Enter the " + Js.Lower(f.Str("label")!), "mail_field", new JsObject { ["field"] = name });
            }
            if (f.Arr("options") is { } options && !string.IsNullOrEmpty(value) && !options.Contains(value))
            {
                string list = string.Join(", ", options);
                throw new MailError(f.Str("label") + " must be one of " + list, "mail_option", new JsObject { ["field"] = name, ["options"] = list });
            }
        }
        string url = config.Get("url") is { } u ? Js.String(u) : "";
        if (Js.String(id) == "webhook" && !url.StartsWith("https://", StringComparison.Ordinal) && !LocalWebhook().IsMatch(url))
        {
            throw new MailError("The webhook URL must use https", "mail_https", []);
        }
        if (Js.String(id) == "webhook" && !Url.CanParse(url))
        {
            throw new MailError("Enter the webhook's whole URL, like https://example.com/hooks/mail", "mail_url", []);
        }
        // A port a socket can connect to, read with Number() as the SMTP client reads it.
        double port = Js.Number(config.Get("port") ?? Undefined.Value);
        if (Js.String(id) == "smtp" && !(Math.Floor(port) == port && port >= 1 && port <= 65535))
        {
            throw new MailError("The port must be a whole number from 1 to 65535", "mail_port", []);
        }
    }

    /// <summary>Sends one message through the configured service.</summary>
    /// <param name="config">The service and its fields.</param>
    /// <param name="m">The message.</param>
    /// <param name="fetcher">Where requests go; an <see cref="HttpClientFetcher"/> when null.</param>
    /// <param name="now">Milliseconds, for SES's signature and SMTP's Date; the clock when null.</param>
    /// <param name="cancellationToken">Stops the send.</param>
    public static async Task SendAsync(JsObject config, JsObject m, IFetcher? fetcher = null, long? now = null, CancellationToken cancellationToken = default)
    {
        CheckConfig(config);
        if (fetcher == null)
        {
            using var own = new HttpClientFetcher();
            await SendWithAsync(config, m, own, now, cancellationToken).ConfigureAwait(false);
            return;
        }
        await SendWithAsync(config, m, fetcher, now, cancellationToken).ConfigureAwait(false);
    }

    private static string S(JsObject o, string key) => Js.String(o.Get(key));

    private static async Task SendWithAsync(JsObject config, JsObject m, IFetcher fetcher, long? now, CancellationToken ct)
    {
        var headers = m.Obj("headers") ?? [];
        // Written as a JSON object even when empty, as TS's `m.headers ?? {}` is.
        var headersObject = headers.Clone();
        bool hasName = !string.IsNullOrEmpty(m.Str("fromName"));
        JsObject Named(string emailKey, string nameKey)
        {
            var o = new JsObject { [emailKey] = m.Get("from") };
            if (hasName)
            {
                o[nameKey] = m.Get("fromName");
            }
            return o;
        }
        switch (S(config, "service"))
        {
            case "resend":
                await PostAsync(fetcher, "https://api.resend.com/emails",
                    JsonHeaders(new JsObject { ["authorization"] = "Bearer " + S(config, "apiKey") }),
                    Json.Stringify(new JsObject
                    {
                        ["from"] = Address(m),
                        ["to"] = Js.List(m.Get("to")),
                        ["subject"] = m.Get("subject"),
                        ["html"] = m.Get("html"),
                        ["text"] = m.Get("text"),
                        ["headers"] = headersObject,
                    }),
                    true, ct).ConfigureAwait(false);
                return;
            case "postmark":
                {
                    var list = headers.Select(e => (object?)new JsObject { ["Name"] = e.Key, ["Value"] = e.Value }).ToList();
                    string stream = config.Str("stream") ?? "";
                    await PostAsync(fetcher, "https://api.postmarkapp.com/email",
                        JsonHeaders(new JsObject { ["accept"] = "application/json", ["x-postmark-server-token"] = S(config, "serverToken") }),
                        Json.Stringify(new JsObject
                        {
                            ["From"] = Address(m),
                            ["To"] = m.Get("to"),
                            ["Subject"] = m.Get("subject"),
                            ["HtmlBody"] = m.Get("html"),
                            ["TextBody"] = m.Get("text"),
                            ["MessageStream"] = stream.Length > 0 ? stream : "outbound",
                            ["Headers"] = list,
                        }),
                        true, ct).ConfigureAwait(false);
                    return;
                }
            case "sendgrid":
                await PostAsync(fetcher, "https://api.sendgrid.com/v3/mail/send",
                    JsonHeaders(new JsObject { ["authorization"] = "Bearer " + S(config, "apiKey") }),
                    Json.Stringify(new JsObject
                    {
                        ["personalizations"] = Js.List(new JsObject { ["to"] = Js.List(new JsObject { ["email"] = m.Get("to") }) }),
                        ["from"] = Named("email", "name"),
                        ["subject"] = m.Get("subject"),
                        ["content"] = Js.List(
                            new JsObject { ["type"] = "text/plain", ["value"] = m.Get("text") },
                            new JsObject { ["type"] = "text/html", ["value"] = m.Get("html") }),
                        ["headers"] = headersObject,
                    }),
                    true, ct).ConfigureAwait(false);
                return;
            case "mailgun":
                {
                    var form = new SearchParams(new KeyValuePair<string, string>[]
                    {
                        new("from", Address(m)),
                        new("to", S(m, "to")),
                        new("subject", S(m, "subject")),
                        new("html", S(m, "html")),
                        new("text", S(m, "text")),
                    });
                    foreach (var (k, v) in headers)
                    {
                        form.Set("h:" + k, Js.String(v));
                    }
                    string host = config.Str("region") == "eu" ? "api.eu.mailgun.net" : "api.mailgun.net";
                    await PostAsync(fetcher, "https://" + host + "/v3/" + Js.EncodeURIComponent(S(config, "domain")) + "/messages",
                        new JsObject { ["authorization"] = Basic("api", S(config, "apiKey")), ["content-type"] = "application/x-www-form-urlencoded" },
                        form.ToString(),
                        true, ct).ConfigureAwait(false);
                    return;
                }
            case "brevo":
                await PostAsync(fetcher, "https://api.brevo.com/v3/smtp/email",
                    JsonHeaders(new JsObject { ["api-key"] = S(config, "apiKey"), ["accept"] = "application/json" }),
                    Json.Stringify(new JsObject
                    {
                        ["sender"] = Named("email", "name"),
                        ["to"] = Js.List(new JsObject { ["email"] = m.Get("to") }),
                        ["subject"] = m.Get("subject"),
                        ["htmlContent"] = m.Get("html"),
                        ["textContent"] = m.Get("text"),
                        ["headers"] = headersObject,
                    }),
                    true, ct).ConfigureAwait(false);
                return;
            case "mailjet":
                await PostAsync(fetcher, "https://api.mailjet.com/v3.1/send",
                    JsonHeaders(new JsObject { ["authorization"] = Basic(S(config, "apiKey"), S(config, "secretKey")) }),
                    Json.Stringify(new JsObject
                    {
                        ["Messages"] = Js.List(new JsObject
                        {
                            ["From"] = Named("Email", "Name"),
                            ["To"] = Js.List(new JsObject { ["Email"] = m.Get("to") }),
                            ["Subject"] = m.Get("subject"),
                            ["TextPart"] = m.Get("text"),
                            ["HTMLPart"] = m.Get("html"),
                            ["Headers"] = headersObject,
                        }),
                    }),
                    true, ct).ConfigureAwait(false);
                return;
            case "mailersend":
                {
                    var list = headers.Select(e => (object?)new JsObject { ["name"] = e.Key, ["value"] = e.Value }).ToList();
                    var body = new JsObject
                    {
                        ["from"] = Named("email", "name"),
                        ["to"] = Js.List(new JsObject { ["email"] = m.Get("to") }),
                        ["subject"] = m.Get("subject"),
                        ["html"] = m.Get("html"),
                        ["text"] = m.Get("text"),
                    };
                    if (list.Count > 0)
                    {
                        body["headers"] = list;
                    }
                    await PostAsync(fetcher, "https://api.mailersend.com/v1/email",
                        JsonHeaders(new JsObject { ["authorization"] = "Bearer " + S(config, "apiKey") }),
                        Json.Stringify(body),
                        true, ct).ConfigureAwait(false);
                    return;
                }
            case "sparkpost":
                await PostAsync(fetcher, "https://" + (config.Str("region") == "eu" ? "api.eu.sparkpost.com" : "api.sparkpost.com") + "/api/v1/transmissions",
                    JsonHeaders(new JsObject { ["authorization"] = S(config, "apiKey") }),
                    Json.Stringify(new JsObject
                    {
                        ["recipients"] = Js.List(new JsObject { ["address"] = new JsObject { ["email"] = m.Get("to") } }),
                        ["content"] = new JsObject
                        {
                            ["from"] = hasName ? new JsObject { ["email"] = m.Get("from"), ["name"] = m.Get("fromName") } : m.Get("from"),
                            ["subject"] = m.Get("subject"),
                            ["html"] = m.Get("html"),
                            ["text"] = m.Get("text"),
                            ["headers"] = headersObject,
                        },
                    }),
                    true, ct).ConfigureAwait(false);
                return;
            case "ses":
                await Ses.SendAsync(config, m, Address(m), fetcher, now, ct).ConfigureAwait(false);
                return;
            case "smtp":
                await Smtp.SendAsync(config, m, Address(m), cancellationToken: ct).ConfigureAwait(false);
                return;
            case "webhook":
                {
                    string body = Json.Stringify(new JsObject
                    {
                        ["to"] = m.Get("to"),
                        ["from"] = m.Get("from"),
                        ["fromName"] = m.Get("fromName") ?? "",
                        ["subject"] = m.Get("subject"),
                        ["html"] = m.Get("html"),
                        ["text"] = m.Get("text"),
                        ["headers"] = headersObject,
                    });
                    string secret = config.Str("secret") ?? "";
                    var signature = secret.Length > 0 ? new JsObject { ["x-runlight-signature"] = "sha256=" + Hash.Hmac(secret, body) } : [];
                    // A webhook can be any address, so only its status comes back.
                    await PostAsync(fetcher, S(config, "url"), JsonHeaders(signature), body, false, ct).ConfigureAwait(false);
                    return;
                }
        }
        throw new MailError("Unknown mail service \"" + S(config, "service") + "\"", "mail_service", []);
    }
}
