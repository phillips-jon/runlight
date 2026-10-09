using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Mail;

/// <summary>
/// Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
/// AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
/// </summary>
public static partial class Ses
{
    [GeneratedRegex("^[a-z]{2}(-[a-z]+)+-[0-9]\\z", RegexOptions.CultureInvariant)]
    private static partial Regex RegionPattern();

    /// <summary>Signs a request; public for its test against AWS's published example.</summary>
    /// <param name="method">The HTTP method.</param>
    /// <param name="url">The whole URL.</param>
    /// <param name="body">The body as text.</param>
    /// <param name="region">The AWS region.</param>
    /// <param name="service">The AWS service, such as "ses".</param>
    /// <param name="accessKeyId">The access key ID.</param>
    /// <param name="secretAccessKey">The secret access key.</param>
    /// <param name="now">The time to sign at, in milliseconds.</param>
    /// <param name="headers">The headers to sign, names as given.</param>
    /// <returns>The headers with host, x-amz-date, and authorization added.</returns>
    public static JsObject SignV4(string method, string url, string body, string region, string service, string accessKeyId, string secretAccessKey, long now, JsObject headers)
    {
        var parsed = new Url(url);
        string amzDate = DateTimeOffset.FromUnixTimeMilliseconds(now).UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        string day = amzDate[..8];
        string payloadHash = Hash.Sha256(body);
        var all = headers.Clone();
        all["host"] = parsed.Host;
        all["x-amz-date"] = amzDate;
        var names = all.Keys.Select(h => Js.Lower(h)).ToList();
        names.Sort(StringComparer.Ordinal);
        var lower = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in all)
        {
            lower[Js.Lower(k)] = CollapseSpace(Js.Trim(Js.String(v)));
        }
        string path = string.Join('/', parsed.Pathname.Split('/').Select(p => Js.EncodeURIComponent(Js.DecodeURIComponent(p) ?? p)));
        // A stable sort on the name alone, as Array.prototype.sort is.
        var pairs = parsed.SearchParams.OrderBy(p => p.Key, StringComparer.Ordinal).ToList();
        string canonical = string.Join('\n',
            method,
            path.Length > 0 ? path : "/",
            string.Join('&', pairs.Select(p => Js.EncodeURIComponent(p.Key) + "=" + Js.EncodeURIComponent(p.Value))),
            string.Concat(names.Select(n => n + ":" + lower[n] + "\n")),
            string.Join(';', names),
            payloadHash);
        string scope = day + "/" + region + "/" + service + "/aws4_request";
        string toSign = string.Join('\n', "AWS4-HMAC-SHA256", amzDate, scope, Hash.Sha256(canonical));
        byte[] key = HMACSHA256.HashData(Js.Utf8("AWS4" + secretAccessKey), Js.Utf8(day));
        key = HMACSHA256.HashData(key, Js.Utf8(region));
        key = HMACSHA256.HashData(key, Js.Utf8(service));
        key = HMACSHA256.HashData(key, Js.Utf8("aws4_request"));
        string signature = Convert.ToHexStringLower(HMACSHA256.HashData(key, Js.Utf8(toSign)));
        all["authorization"] = "AWS4-HMAC-SHA256 Credential=" + accessKeyId + "/" + scope + ", SignedHeaders=" + string.Join(';', names) + ", Signature=" + signature;
        return all;
    }

    /// <summary>JavaScript's <c>.replace(/\s+/g, " ")</c>.</summary>
    private static string CollapseSpace(string text)
    {
        var b = new StringBuilder(text.Length);
        bool space = false;
        foreach (char c in text)
        {
            if (Js.IsSpace(c))
            {
                if (!space)
                {
                    b.Append(' ');
                }
                space = true;
            }
            else
            {
                b.Append(c);
                space = false;
            }
        }
        return b.ToString();
    }

    /// <summary>Sends one message through Amazon SES.</summary>
    /// <param name="config">region, accessKeyId, and secretAccessKey.</param>
    /// <param name="m">The message.</param>
    /// <param name="from">The From address, with its name.</param>
    /// <param name="fetcher">Where the request goes.</param>
    /// <param name="now">Milliseconds; the clock when null.</param>
    /// <param name="cancellationToken">Stops the send.</param>
    public static async Task SendAsync(JsObject config, JsObject m, string from, IFetcher fetcher, long? now = null, CancellationToken cancellationToken = default)
    {
        string region = Js.Trim(Js.String(config.Get("region")));
        if (!RegionPattern().IsMatch(region))
        {
            throw new MailError("That is not an AWS region, like us-east-1", "mail_region", []);
        }
        string url = "https://email." + region + ".amazonaws.com/v2/email/outbound-emails";
        var headerList = new List<object?>();
        foreach (var (name, value) in m.Obj("headers") ?? [])
        {
            headerList.Add(new JsObject { ["Name"] = name, ["Value"] = value });
        }
        string body = Json.Stringify(new JsObject
        {
            ["FromEmailAddress"] = from,
            ["Destination"] = new JsObject { ["ToAddresses"] = Js.List(m.Get("to")) },
            ["Content"] = new JsObject
            {
                ["Simple"] = new JsObject
                {
                    ["Subject"] = new JsObject { ["Data"] = m.Get("subject"), ["Charset"] = "UTF-8" },
                    ["Body"] = new JsObject
                    {
                        ["Html"] = new JsObject { ["Data"] = m.Get("html"), ["Charset"] = "UTF-8" },
                        ["Text"] = new JsObject { ["Data"] = m.Get("text"), ["Charset"] = "UTF-8" },
                    },
                    ["Headers"] = headerList,
                },
            },
        });
        var signed = SignV4(
            "POST",
            url,
            body,
            region,
            "ses",
            Js.Trim(Js.String(config.Get("accessKeyId"))),
            Js.Trim(Js.String(config.Get("secretAccessKey"))),
            now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            new JsObject { ["content-type"] = "application/json" });
        signed.Remove("host");
        var headers = new Headers();
        foreach (var (k, v) in signed)
        {
            headers.Set(k, Js.String(v));
        }
        Response response;
        try
        {
            response = await fetcher.FetchAsync(url, new FetchInit { Method = "POST", Headers = headers, BodyText = body, TimeoutMs = 20_000 }, cancellationToken).ConfigureAwait(false);
        }
        catch (FetchException error)
        {
            throw new MailError("Could not reach Amazon SES: " + error.Message, "mail_unreachable", new JsObject { ["host"] = "Amazon SES", ["detail"] = error.Message });
        }
        if (!response.Ok)
        {
            string message = Transports.ServiceMessage(await response.TextAsync(cancellationToken).ConfigureAwait(false));
            string status = Js.Str(response.Status);
            throw new MailError(
                "Amazon SES answered " + status + (message.Length > 0 ? ": " + message : ""),
                "mail_refused",
                new JsObject { ["host"] = "Amazon SES", ["detail"] = status + (message.Length > 0 ? " " + message : "") });
        }
    }
}
