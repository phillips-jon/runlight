using System;
using System.Buffers.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Store;

namespace Runlight;

/// <summary>
/// Connecting another Runlight to this one (a hub) without copying a token:
/// this server registers itself with the install's OAuth server, sends the
/// owner to that install's consent page, and on the way back swaps the code
/// for a manage token, limited there to the one site the owner picked.
///
/// A pending attempt is kept in settings as <c>connect:&lt;state&gt;</c>: the install's <c>url</c>, the
/// <c>client</c> id it gave, the PKCE <c>verifier</c>, the <c>redirect</c> address, its <c>token</c> endpoint, and
/// when it <c>expires</c>.
///
/// What TypeScript reads from the Runlight comes in as parameters: its <c>store</c>, its <c>fetcher</c> (for
/// fetch), its clock <c>now</c>, and, to finish, its <c>addSite</c>.
/// </summary>
public static class Connect
{
    private const long PendingMs = 15 * 60_000;

    /// <summary>The most an install's answer while connecting may weigh; a real one is under a kilobyte.</summary>
    private const long MaxBytes = 64 * 1024;

    private static readonly Regex State = new("^[a-f0-9]{32}\\z", RegexOptions.CultureInvariant);

    private static readonly Regex TrailingSlashes = new("/+\\z", RegexOptions.CultureInvariant);

    /// <summary>The install's address as its dashboard is, without a trailing slash.</summary>
    /// <param name="value">The address as the owner typed it.</param>
    /// <param name="local">Whether an install may be at http://localhost or http://127.0.0.1.</param>
    /// <exception cref="ConnectError">With code "url" when it is not one.</exception>
    public static string InstallUrl(object? value, bool local = false)
    {
        string url = TrailingSlashes.Replace(Js.Trim(Js.String(value is null or Undefined ? "" : value)), "");
        // The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
        if (!Safefetch.InstallAddress(url, local) || !Url.CanParse(url))
        {
            throw new ConnectError("Enter the install's address, like https://example.com/runlight", "url");
        }
        return url;
    }

    /// <summary>A saved attempt, or null when it cannot be read or has no time it runs out, which counts as expired.</summary>
    private static JsObject? PendingFrom(string? value, long now) =>
        Json.TryParse(value ?? "", out object? parsed) && parsed is JsObject pending && Json.TryNumberOf(pending.Get("expires"), out double expires) && expires >= now
            ? pending
            : null;

    /// <summary>Attempts nobody came back from are removed, so they do not pile up in settings.</summary>
    private static async Task ClearExpiredAsync(SqlStore store, Func<long> now, CancellationToken cancellationToken)
    {
        foreach (var row in await store.SettingsStartingWithAsync("connect:", cancellationToken).ConfigureAwait(false))
        {
            if (PendingFrom(row.Str("value"), now()) == null)
            {
                await store.SetSettingAsync(row.Str("key")!, null, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>The PKCE challenge for a verifier: SHA-256, base64url without padding (oauth.ts's s256).</summary>
    private static string S256(string verifier) => Base64Url.EncodeToString(SHA256.HashData(Js.Utf8(verifier)));

    /// <summary>
    /// The fetch, or null when no answer came back, as <c>fetch(...).catch(() =&gt; null)</c>. Only the
    /// public internet is asked, or an install on this machine when allowed (<see cref="Safefetch.InstallFetchAsync"/>),
    /// and a long answer counts as none.
    /// </summary>
    private static async Task<(Response Answer, byte[] Body)?> TryFetchAsync(IFetcher fetcher, string url, PublicFetchInit init, bool local, CancellationToken cancellationToken)
    {
        try
        {
            init.MaxBytes = MaxBytes;
            var answer = await Safefetch.InstallFetchAsync(url, init, local, fetcher, cancellationToken).ConfigureAwait(false);
            return (answer, await answer.BytesAsync(cancellationToken).ConfigureAwait(false));
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>A JSON body, or null when it is not JSON, as <c>answer.json().catch(() =&gt; null)</c>.</summary>
    private static object? JsonOf(byte[] body) => Js.ParseJson(body, out object? value) ? value : null;

    /// <summary>value?.[key].</summary>
    private static object? Prop(object? value, string key) => value is null or Undefined ? Undefined.Value : Js.Get(value, key);

    /// <summary>Starts connecting: returns the address of the install's consent page.</summary>
    /// <param name="store">The Runlight's store.</param>
    /// <param name="fetcher">The Runlight's fetcher.</param>
    /// <param name="now">The Runlight's clock, in milliseconds.</param>
    /// <param name="input">The install's address as the owner typed it.</param>
    /// <param name="back">Where the consent page sends the owner back to.</param>
    /// <param name="site">Which of its sites to offer first, or "".</param>
    /// <param name="local">The Runlight's LocalInstalls: whether an install may be at http://localhost or http://127.0.0.1.</param>
    /// <param name="cancellationToken">Stops the requests.</param>
    /// <exception cref="ConnectError">With a code saying what went wrong.</exception>
    public static async Task<string> StartConnectAsync(SqlStore store, IFetcher fetcher, Func<long> now, object? input, string back, string site = "", bool local = false, CancellationToken cancellationToken = default)
    {
        string url = InstallUrl(input, local);
        string host = new Url(url).Host;
        var answer = await TryFetchAsync(fetcher, url + "/.well-known/oauth-authorization-server", new PublicFetchInit { TimeoutMs = 10_000 }, local, cancellationToken).ConfigureAwait(false)
            ?? throw new ConnectError("Could not reach " + url, "unreachable", new JsObject { ["host"] = host });
        object? meta = answer.Answer.Ok ? JsonOf(answer.Body) : null;
        if (!Js.Truthy(Prop(meta, "authorization_endpoint")) || !Js.Truthy(Prop(meta, "token_endpoint")) || !Js.Truthy(Prop(meta, "registration_endpoint")))
        {
            throw new ConnectError(url + " did not answer like a Runlight install", "not_runlight", new JsObject { ["url"] = url });
        }
        // Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
        string origin = new Url(url).Origin;
        foreach (string name in new[] { "authorization_endpoint", "token_endpoint", "registration_endpoint" })
        {
            var parsed = Url.Parse(Js.String(Js.Get(meta, name)));
            if (parsed == null || parsed.Origin != origin)
            {
                throw new ConnectError(url + " named endpoints on another address", "endpoints", new JsObject { ["url"] = url });
            }
        }
        if (Js.Get(meta, "scopes_supported") is not List<object?> scopes || !scopes.Exists(s => s is "manage"))
        {
            throw new ConnectError(url + " runs an older Runlight. Update it, or connect it with an API token from its Settings.", "old", new JsObject { ["url"] = url });
        }

        var registered = await TryFetchAsync(fetcher, Js.String(Js.Get(meta, "registration_endpoint")), new PublicFetchInit
        {
            Method = "POST",
            Headers = new Headers { ["content-type"] = "application/json" },
            BodyText = Json.Stringify(new JsObject { ["client_name"] = "Runlight at " + new Url(back).Host, ["redirect_uris"] = new List<object?> { back } }),
            TimeoutMs = 10_000,
        }, local, cancellationToken).ConfigureAwait(false)
            ?? throw new ConnectError("Could not reach " + url, "unreachable", new JsObject { ["host"] = host });
        object? client = JsonOf(registered.Body);
        object? clientId = Prop(client, "client_id");
        if (!registered.Answer.Ok || !Js.Truthy(clientId))
        {
            // Say why, in the install's own words when it gives them.
            object? description = Prop(client, "error_description");
            string reason = Js.Truthy(description)
                ? Js.Slice(Js.String(description), 0, 200) + "."
                : registered.Answer.Status == 400 ? "This server's address must use https." : "It answered " + Js.Str(registered.Answer.Status) + ".";
            throw new ConnectError(url + " would not let this server connect. " + reason, "register", new JsObject { ["url"] = url, ["reason"] = reason });
        }
        await ClearExpiredAsync(store, now, cancellationToken).ConfigureAwait(false);

        string state = Hash.RandomId(16);
        string verifier = Hash.RandomId(32) + Hash.RandomId(32);
        var pending = new JsObject
        {
            ["url"] = url,
            ["client"] = clientId,
            ["verifier"] = verifier,
            ["redirect"] = back,
            ["token"] = Js.Get(meta, "token_endpoint"),
            ["expires"] = now() + PendingMs,
        };
        await store.SetSettingAsync("connect:" + state, Json.Stringify(pending), cancellationToken).ConfigureAwait(false);
        var to = new Url(Js.String(Js.Get(meta, "authorization_endpoint")));
        var query = new SearchParams
        {
            { "response_type", "code" },
            { "client_id", Js.String(clientId) },
            { "redirect_uri", back },
            { "code_challenge", S256(verifier) },
            { "code_challenge_method", "S256" },
            { "scope", "manage" },
            { "state", state },
        };
        // Which of its sites to offer first, when connecting again for a site already here.
        if (site.Length > 0)
        {
            query.Append("site", site);
        }
        to.SetSearch(query.ToString());
        return to.Href;
    }

    /// <summary>Finishes connecting when the owner comes back from the consent page. Returns the site's id here.</summary>
    /// <param name="store">The Runlight's store.</param>
    /// <param name="fetcher">The Runlight's fetcher.</param>
    /// <param name="now">The Runlight's clock, in milliseconds.</param>
    /// <param name="addSite">The Runlight's addSite: takes { remote: { url, token, site } } and answers the site added, with its id.</param>
    /// <param name="parameters">The query the consent page sent the owner back with.</param>
    /// <param name="local">The Runlight's LocalInstalls.</param>
    /// <param name="cancellationToken">Stops the requests.</param>
    /// <exception cref="ConnectError">With a code saying what went wrong.</exception>
    public static async Task<string> FinishConnectAsync(SqlStore store, IFetcher fetcher, Func<long> now, Func<JsObject, Task<JsObject>> addSite, SearchParams parameters, bool local = false, CancellationToken cancellationToken = default)
    {
        string state = parameters.Get("state") ?? "";
        string key = "connect:" + state;
        string? stored = State.IsMatch(state) ? await store.SettingAsync(key, cancellationToken).ConfigureAwait(false) : null;
        // Each attempt works once.
        if (!string.IsNullOrEmpty(stored))
        {
            await store.SetSettingAsync(key, null, cancellationToken).ConfigureAwait(false);
        }
        var pending = !string.IsNullOrEmpty(stored) ? PendingFrom(stored, now()) : null;
        if (pending == null)
        {
            throw new ConnectError("That connection took too long or was already used. Start again.", "expired");
        }
        if (parameters.Get("error") == "access_denied")
        {
            throw new ConnectError("The connection was not allowed.", "denied");
        }
        if (Js.Truthy(parameters.Get("error")))
        {
            throw new ConnectError(parameters.Get("error_description") ?? parameters.Get("error")!, "refused");
        }

        var answer = await TryFetchAsync(fetcher, Js.String(pending.Prop("token")), new PublicFetchInit
        {
            Method = "POST",
            Headers = new Headers { ["content-type"] = "application/x-www-form-urlencoded" },
            BodyText = new SearchParams
            {
                { "grant_type", "authorization_code" },
                { "code", parameters.Get("code") ?? "" },
                { "client_id", Js.String(pending.Prop("client")) },
                { "redirect_uri", Js.String(pending.Prop("redirect")) },
                { "code_verifier", Js.String(pending.Prop("verifier")) },
            }.ToString(),
            TimeoutMs = 10_000,
        }, local, cancellationToken).ConfigureAwait(false);
        object? granted = answer is { Answer.Ok: true } ? JsonOf(answer.Value.Body) : null;
        object? token = Prop(granted, "access_token");
        if (!Js.Truthy(token))
        {
            throw new ConnectError(new Url(Js.String(pending.Prop("url"))).Host + " did not give this server a token. Start again.", "token");
        }
        var site = await addSite(new JsObject
        {
            ["remote"] = new JsObject { ["url"] = pending.Prop("url"), ["token"] = token, ["site"] = Prop(granted, "site") },
        }).ConfigureAwait(false);
        return Js.String(site.Prop("id"));
    }
}
