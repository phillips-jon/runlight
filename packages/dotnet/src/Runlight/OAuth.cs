using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Store;

namespace Runlight;

/// <summary>
/// What OAuth needs from the Runlight and its routes, as delegates the core supplies: the store, the clock, the
/// sites, the client's address, and who is asking.
/// </summary>
public sealed class OAuthContext
{
    public required SqlStore Store { get; init; }

    /// <summary>The base path the routes answer at.</summary>
    public required string Base { get; init; }

    /// <summary>The clock, in epoch milliseconds (the Runlight's now).</summary>
    public required Func<long> Now { get; init; }

    /// <summary>The Runlight's init(): the tables made and the sites ready.</summary>
    public required Func<CancellationToken, Task> Init { get; init; }

    /// <summary>The Runlight's clientIp(request, context), given the connection's address (the context's ip, or null).</summary>
    public required Func<Request, string?, string> ClientIp { get; init; }

    /// <summary>The Runlight's sites(): each with at least id and name.</summary>
    public required Func<CancellationToken, Task<List<JsObject>>> Sites { get; init; }

    /// <summary>The Runlight's site(id): the site, or null when there is none by that id.</summary>
    public required Func<string, CancellationToken, Task<JsObject?>> Site { get; init; }

    /// <summary>Whether the Runlight's remote(id) is not null: a site served by another install.</summary>
    public required Func<string, CancellationToken, Task<bool>> IsRemote { get; init; }

    /// <summary>Whether the request comes from someone who may connect apps.</summary>
    public required Func<Request, CancellationToken, Task<bool>> IsOwner { get; init; }

    /// <summary>The app's sign-in page, when it has one.</summary>
    public string? SignIn { get; init; }

    /// <summary>Whether the request comes from someone signed in who may only read.</summary>
    public Func<Request, CancellationToken, Task<bool>>? IsReader { get; init; }

    /// <summary>The id of the account signed in, when accounts are on.</summary>
    public Func<Request, CancellationToken, Task<string?>>? AccountOf { get; init; }

    /// <summary>Notes who made a token; false takes it back (accounts' tokenMade).</summary>
    public Func<JsObject, string, CancellationToken, Task<bool>>? TokenMade { get; init; }
}

/// <summary>
/// OAuth for the MCP server, so apps that connect only through OAuth (the Claude and ChatGPT web connectors) can
/// reach it. Runlight is both the resource and the authorization server.
/// </summary>
/// <remarks>
/// /.well-known/oauth-protected-resource names the MCP endpoint and this server.
/// /.well-known/oauth-authorization-server lists the endpoints below.
/// POST /oauth/register lets a client register itself (public clients, no secret).
/// /oauth/authorize asks the signed-in owner to allow the client, every site or one.
/// POST /oauth/token swaps the one-time code, checked with PKCE, for a token.
///
/// The token is an ordinary API token, so it appears in Settings, API and AI, beside the others, and deleting it
/// there disconnects the app. It reads stats, or with the "manage" scope (asked for by a Runlight hub) it also
/// changes one site's settings.
/// </remarks>
public static class OAuth
{
    public const long CodeMs = 5 * 60_000;

    /// <summary>An app stored before client ids were signed, which never finished connecting within a day, is removed.</summary>
    public const long UnusedClientMs = 86_400_000;

    /// <summary>Registrations one address may make a minute.</summary>
    public const int RegistrationsPerMinute = 10;

    /// <summary>The longest client id, which carries the app's name and redirect addresses.</summary>
    public const int MaxClientId = 2048;

    /// <summary>
    /// Where the per-address count of registrations is kept. TypeScript keeps it in memory per install; here, as in
    /// PHP, it lives in the install's settings, keyed by a hash of the address, so every process shares it.
    /// </summary>
    private const string Registrations = "oauth-registrations";

    private const string Space = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF";

    private static readonly KeyValuePair<string, string>[] Cors =
    [
        new("access-control-allow-origin", "*"),
        new("access-control-allow-headers", "authorization, content-type, mcp-protocol-version"),
        new("access-control-allow-methods", "GET, POST, OPTIONS"),
    ];

    private static readonly Regex StoredId = new("^[a-f0-9]{32}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex SignedId = new("^([A-Za-z0-9_-]{1,2000})\\.([a-f0-9]{64})\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Https = new("^https://[^/]+", RegexOptions.CultureInvariant);
    private static readonly Regex Loopback = new("^http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?/", RegexOptions.CultureInvariant);
    private static readonly Regex Challenge = new("^[A-Za-z0-9_-]{43,128}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Spaces = new("[" + Space + "]+", RegexOptions.CultureInvariant);

    private static string Base64url(string text) => Crypto.Base64url(Js.Utf8(text));

    /// <summary>The key client ids are signed with, made on first use and kept in the database for every process.</summary>
    private static async Task<string> ClientKeyAsync(OAuthContext ctx, CancellationToken cancellationToken)
    {
        string? saved = await ctx.Store.SettingAsync("oauth-key", cancellationToken).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(saved))
        {
            return saved;
        }
        string made = Hash.RandomId(32);
        await ctx.Store.SetSettingAsync("oauth-key", made, cancellationToken).ConfigureAwait(false);
        return made;
    }

    /// <summary>
    /// The app a client id names, and where to note that it connected. A new id carries the app's name and
    /// addresses, signed, so registering stores nothing and a flood of registrations fills nothing. Ids from before
    /// that were stored.
    /// </summary>
    private static async Task<(JsObject Client, string UsedKey)?> ClientForAsync(OAuthContext ctx, string id, CancellationToken cancellationToken)
    {
        if (StoredId.IsMatch(id))
        {
            string? stored = await ctx.Store.SettingAsync("oauth-client:" + id, cancellationToken).ConfigureAwait(false);
            return !string.IsNullOrEmpty(stored) ? ((JsObject)Json.Parse(stored)!, "oauth-client:" + id) : null;
        }
        var parts = SignedId.Match(id);
        if (!parts.Success || id.Length > MaxClientId)
        {
            return null;
        }
        string key = await ClientKeyAsync(ctx, cancellationToken).ConfigureAwait(false);
        if (!ConstantTimeEqual(parts.Groups[2].Value, Hash.Hmac(key, parts.Groups[1].Value)))
        {
            return null;
        }
        var meta = (JsObject)Json.Parse(Js.Decode(Crypto.FromBase64url(parts.Groups[1].Value)))!;
        string usedKey = "oauth-used:" + Hash.Sha256(id);
        string? used = await ctx.Store.SettingAsync(usedKey, cancellationToken).ConfigureAwait(false);
        var client = new JsObject { ["name"] = meta.Get("n"), ["redirects"] = meta.Get("r"), ["createdAt"] = meta.Get("t") };
        if (!string.IsNullOrEmpty(used))
        {
            client.Set("usedAt", Js.Number(used));
        }
        return (client, usedKey);
    }

    private static bool ConstantTimeEqual(string a, string b) => a.Length == b.Length && Crypto.SameText(a, b);

    private static string Esc(string value) => Pages.Esc(value);

    private static Response JsonAnswer(object? body, int status = 200)
    {
        var headers = new Headers { ["content-type"] = "application/json; charset=utf-8", ["cache-control"] = "no-store" };
        foreach (var e in Cors)
        {
            headers.Set(e.Key, e.Value);
        }
        return new Response(Json.Stringify(body), status, headers);
    }

    private static Response OauthError(string error, string description, int status = 400) =>
        JsonAnswer(new JsObject { ["error"] = error, ["error_description"] = description }, status);

    /// <summary>base64url of SHA-256, as PKCE's S256 method compares.</summary>
    public static string S256(string verifier) => Crypto.Base64url(Crypto.Sha256(verifier));

    /// <summary>Redirect addresses a client may register: https, or a local app's own loopback address.</summary>
    private static bool AllowedRedirect(string value) => Https.IsMatch(value) || Loopback.IsMatch(value);

    /// <summary>The URL that a 401 from the MCP endpoint points clients at, to start OAuth.</summary>
    public static string ResourceMetadataUrl(string origin, string basePath) => origin + basePath + "/.well-known/oauth-protected-resource";

    private static List<object?> Strings(params string[] values) => [.. values];

    /// <summary>
    /// Answers the OAuth paths, or returns null for anything else. <paramref name="path"/> is relative to the routes'
    /// base; the two well-known documents are also answered at the site's root (<c>/.well-known/...</c>) for clients
    /// that look there. <paramref name="ip"/> is the context's address (the connection's).
    /// </summary>
    public static async Task<Response?> OAuthResponseAsync(OAuthContext ctx, Request request, string path, Url url, string? ip = null, CancellationToken cancellationToken = default)
    {
        string basePath = ctx.Base;
        string issuer = url.Origin + basePath;
        string known = path;
        if (request.Method == "OPTIONS" && (known.StartsWith("/.well-known/oauth-", StringComparison.Ordinal) || known.StartsWith("/.well-known/openid-configuration", StringComparison.Ordinal) || path.StartsWith("/oauth/", StringComparison.Ordinal)))
        {
            return new Response("", 204, new Headers(Cors));
        }

        if (known.StartsWith("/.well-known/oauth-protected-resource", StringComparison.Ordinal))
        {
            return JsonAnswer(new JsObject
            {
                ["resource"] = issuer + "/mcp",
                ["authorization_servers"] = Strings(issuer),
                ["scopes_supported"] = Strings("read", "manage"),
                ["bearer_methods_supported"] = Strings("header"),
            });
        }
        if (known.StartsWith("/.well-known/oauth-authorization-server", StringComparison.Ordinal) || known.StartsWith("/.well-known/openid-configuration", StringComparison.Ordinal))
        {
            return JsonAnswer(new JsObject
            {
                ["issuer"] = issuer,
                ["authorization_endpoint"] = issuer + "/oauth/authorize",
                ["token_endpoint"] = issuer + "/oauth/token",
                ["registration_endpoint"] = issuer + "/oauth/register",
                ["response_types_supported"] = Strings("code"),
                ["grant_types_supported"] = Strings("authorization_code"),
                ["code_challenge_methods_supported"] = Strings("S256"),
                ["token_endpoint_auth_methods_supported"] = Strings("none"),
                ["scopes_supported"] = Strings("read", "manage"),
            });
        }

        if (path == "/oauth/register" && request.Method == "POST")
        {
            await ctx.Init(cancellationToken).ConfigureAwait(false);
            if (!await AllowRegistrationAsync(ctx, ctx.ClientIp(request, ip), cancellationToken).ConfigureAwait(false))
            {
                return OauthError("invalid_client_metadata", "Too many registrations from this address. Wait a minute and try again.", 429);
            }
            object? body = Js.ParseJson(request.Text(), out object? parsed) ? parsed : null;
            object? uris = body != null && Js.IsObject(body) ? Js.Get(body, "redirect_uris") : null;
            var redirects = new List<string>();
            if (uris is List<object?> list)
            {
                redirects = list.Select(Js.String).Where(AllowedRedirect).Take(10).ToList();
            }
            if (redirects.Count == 0)
            {
                return OauthError("invalid_redirect_uri", "Register at least one https redirect address");
            }
            object? name = body != null && Js.IsObject(body) ? Js.Get(body, "client_name") : null;
            return await RegisterAsync(ctx, Js.String(name is null or Undefined ? "An app" : name), redirects, cancellationToken).ConfigureAwait(false);
        }

        if (path == "/oauth/authorize" && (request.Method == "GET" || request.Method == "POST"))
        {
            return await AuthorizeAsync(ctx, request, url, cancellationToken).ConfigureAwait(false);
        }

        if (path == "/oauth/token" && request.Method == "POST")
        {
            return await TokenAsync(ctx, request, cancellationToken).ConfigureAwait(false);
        }

        return null;
    }

    private static async Task<Response> AuthorizeAsync(OAuthContext ctx, Request request, Url url, CancellationToken cancellationToken)
    {
        string basePath = ctx.Base;
        await ctx.Init(cancellationToken).ConfigureAwait(false);
        var form = request.Method == "POST" ? new SearchParams(request.Text()) : url.SearchParams;
        string clientId = form.Get("client_id") ?? "";
        var client = (await ClientForAsync(ctx, clientId, cancellationToken).ConfigureAwait(false))?.Client;
        string redirect = form.Get("redirect_uri") ?? "";
        // Without a known client and one of its own addresses there is nowhere safe to send an answer.
        if (client == null || !(client.Get("redirects") is List<object?> registered && registered.Any(r => r is string s && s == redirect)))
        {
            return Page("This app is not registered", "<p>Start connecting again from the app.</p>", 400);
        }
        Response Back(params (string Key, string Value)[] parameters)
        {
            var to = new Url(redirect);
            var query = to.SearchParams;
            foreach (var (k, v) in parameters)
            {
                query.Set(k, v);
            }
            string? state = form.Get("state");
            if (!string.IsNullOrEmpty(state))
            {
                query.Set("state", state);
            }
            to.SetSearchParams(query);
            return new Response("", 303, new Headers { ["location"] = to.Href, ["cache-control"] = "no-store" });
        }
        // Anyone can register an app with any address, so until an owner has allowed it once, a request
        // it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
        Response Refuse(string error, string? description = null) => client.Has("usedAt") && Js.Truthy(client.Get("usedAt"))
            ? (description == null ? Back(("error", error)) : Back(("error", error), ("error_description", description)))
            : Page("This app asked in a way Runlight does not support", "<p>" + Esc(Js.String(client.Get("name"))) + " sent " + Esc(description ?? error) + ". Start connecting again from the app.</p>", 400);
        if (form.Get("response_type") != "code")
        {
            return Refuse("unsupported_response_type");
        }
        string challenge = form.Get("code_challenge") ?? "";
        if (form.Get("code_challenge_method") != "S256" || !Challenge.IsMatch(challenge))
        {
            return Refuse("invalid_request", "PKCE with S256 is required");
        }
        bool manage = Spaces.Split(form.Get("scope") ?? "").Contains("manage");
        string name = Js.String(client.Get("name"));

        if (!await ctx.IsOwner(request, cancellationToken).ConfigureAwait(false))
        {
            // Someone signed in who may only read would be sent to sign in again and again.
            if (ctx.IsReader != null && await ctx.IsReader(request, cancellationToken).ConfigureAwait(false))
            {
                return Page("Ask an owner to connect this", "<p>You are signed in as a viewer, and only an owner of this Runlight can connect " + Esc(name) + ".</p>", 403);
            }
            // The site stays, since on the way in it only says which one to offer first.
            var kept = new SearchParams();
            foreach (var pair in form)
            {
                if (pair.Key != "decision")
                {
                    kept.Append(pair.Key, pair.Value);
                }
            }
            string here = url.Pathname + "?" + kept.ToString();
            if (ctx.SignIn != null)
            {
                return new Response("", 303, new Headers { ["location"] = ctx.SignIn + "?next=" + Js.EncodeURIComponent(here), ["cache-control"] = "no-store" });
            }
            string home = basePath.Length > 0 ? basePath : "/";
            return Page("Sign in first", "<p>Open your Runlight dashboard at <a href=\"" + Esc(home) + "\">" + Esc(url.Host + home) + "</a> and sign in, then connect " + Esc(name) + " again.</p>", 401);
        }

        if (request.Method == "GET")
        {
            string hidden = "";
            foreach (string k in new[] { "response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource" })
            {
                string? v = form.Get(k);
                if (v != null)
                {
                    hidden += "<input type=\"hidden\" name=\"" + k + "\" value=\"" + Esc(v) + "\">";
                }
            }
            // The app names itself, so the page also shows where the answer goes, which it cannot fake.
            string sendsTo = "<p class=\"note\">Allowing sends you back to <strong>" + Esc(new Url(redirect).Host) + "</strong>. Only allow it if you started connecting there.</p>";
            var sites = await ctx.Sites(cancellationToken).ConfigureAwait(false);
            if (manage)
            {
                // Changing settings is for one site at a time, so there is no "every site" here.
                string wanted = form.Get("site") ?? "";
                string choices = "";
                foreach (var s in sites)
                {
                    string id = Js.String(s.Get("id"));
                    if (!await ctx.IsRemote(id, cancellationToken).ConfigureAwait(false))
                    {
                        choices += "<option value=\"" + Esc(id) + "\"" + (id == wanted ? " selected" : "") + ">" + Esc(Js.String(s.Get("name"))) + "</option>";
                    }
                }
                return Page(
                    "Connect " + Esc(name),
                    "<p><strong>" + Esc(name) + "</strong> wants to show this site" + (char)0x2019 + "s stats and change its settings, so you can manage it from there.</p>\n"
                    + "<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>\n"
                    + sendsTo + "\n"
                    + "<form method=\"post\" action=\"" + Esc(basePath) + "/oauth/authorize\">" + hidden + "\n"
                    + "<label>Site<select name=\"site\">" + choices + "</select></label>\n"
                    + "<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects " + Esc(name) + ".</p>\n"
                    + "<div class=\"buttons\"><button type=\"submit\" name=\"decision\" value=\"deny\" class=\"ghost\">Deny</button><button type=\"submit\" name=\"decision\" value=\"allow\">Allow</button></div></form>");
            }
            string options = "";
            foreach (var s in sites)
            {
                options += "<option value=\"" + Esc(Js.String(s.Get("id"))) + "\">" + Esc(Js.String(s.Get("name"))) + " only</option>";
            }
            return Page(
                "Connect " + Esc(name),
                "<p><strong>" + Esc(name) + "</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>\n"
                + sendsTo + "\n"
                + "<form method=\"post\" action=\"" + Esc(basePath) + "/oauth/authorize\">" + hidden + "\n"
                + "<label>Which sites it can read<select name=\"site\"><option value=\"\">Every site</option>" + (sites.Count > 1 ? options : "") + "</select></label>\n"
                + "<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>\n"
                + "<div class=\"buttons\"><button type=\"submit\" name=\"decision\" value=\"deny\" class=\"ghost\">Deny</button><button type=\"submit\" name=\"decision\" value=\"allow\">Allow</button></div></form>");
        }
        // The consent form posts here from this page only; a form from another site is refused.
        string? origin = request.Headers.Get("origin");
        if (!string.IsNullOrEmpty(origin) && origin != url.Origin)
        {
            return Page("This request came from another site", "<p>Start connecting again from the app.</p>", 403);
        }
        if (form.Get("decision") != "allow")
        {
            return Back(("error", "access_denied"));
        }
        string site = form.Get("site") ?? "";
        if (site.Length > 0 && await ctx.Site(site, cancellationToken).ConfigureAwait(false) == null)
        {
            return Back(("error", "invalid_request"), ("error_description", "Unknown site"));
        }
        if (manage && (site.Length == 0 || await ctx.IsRemote(site, cancellationToken).ConfigureAwait(false)))
        {
            return Back(("error", "invalid_request"), ("error_description", "Pick the site to manage"));
        }
        string code = Hash.RandomId(32);
        string? by = ctx.AccountOf != null ? await ctx.AccountOf(request, cancellationToken).ConfigureAwait(false) : null;
        var grant = new JsObject
        {
            ["client"] = clientId,
            ["redirect"] = redirect,
            ["challenge"] = challenge,
            ["site"] = site,
            ["scope"] = manage ? "manage" : "read",
            ["expires"] = ctx.Now() + CodeMs,
        };
        if (!string.IsNullOrEmpty(by))
        {
            grant.Set("by", by);
        }
        await ctx.Store.SetSettingAsync("oauth-code:" + Hash.Sha256(code), Json.Stringify(grant), cancellationToken).ConfigureAwait(false);
        return Back(("code", code));
    }

    private static async Task<Response> TokenAsync(OAuthContext ctx, Request request, CancellationToken cancellationToken)
    {
        await ctx.Init(cancellationToken).ConfigureAwait(false);
        string type = (request.Headers.Get("content-type") ?? "").Split(';')[0].Trim();
        var form = type == "application/json" ? JsonForm(request.Text()) : new SearchParams(request.Text());
        if (form.Get("grant_type") != "authorization_code")
        {
            return OauthError("unsupported_grant_type", "Only authorization_code is supported");
        }
        string key = "oauth-code:" + Hash.Sha256(form.Get("code") ?? "");
        string? stored = await ctx.Store.SettingAsync(key, cancellationToken).ConfigureAwait(false);
        // A code works once: it is gone before anything else is checked.
        if (!string.IsNullOrEmpty(stored))
        {
            await ctx.Store.SetSettingAsync(key, null, cancellationToken).ConfigureAwait(false);
        }
        var grant = !string.IsNullOrEmpty(stored) ? Json.Parse(stored) as JsObject : null;
        long now = ctx.Now();
        if (grant == null || grant.Num("expires") < now)
        {
            return OauthError("invalid_grant", "The code has expired or was already used");
        }
        if (grant.Str("client") != form.Get("client_id") || grant.Str("redirect") != form.Get("redirect_uri"))
        {
            return OauthError("invalid_grant", "The code was issued to another app");
        }
        if (S256(form.Get("code_verifier") ?? "") != grant.Str("challenge"))
        {
            return OauthError("invalid_grant", "The code verifier does not match");
        }
        // The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
        var found = await ClientForAsync(ctx, Js.String(grant.Get("client")), cancellationToken).ConfigureAwait(false);
        var client = found?.Client ?? new JsObject();
        if (found != null && !Js.Truthy(found.Value.Client.Get("usedAt")))
        {
            bool storedClient = found.Value.UsedKey.StartsWith("oauth-client:", StringComparison.Ordinal);
            var used = found.Value.Client.Clone();
            used.Set("usedAt", now);
            await ctx.Store.SetSettingAsync(found.Value.UsedKey, storedClient ? Json.Stringify(used) : Js.Str(now), cancellationToken).ConfigureAwait(false);
        }
        string secret = "rl_" + Hash.RandomId(20);
        string scope = grant.Str("scope") == "manage" ? "manage" : "read";
        string grantSite = Js.String(grant.Get("site"));
        var row = new JsObject
        {
            ["id"] = Hash.RandomId(),
            ["name"] = Js.Slice(Js.String(client.Get("name") ?? "An app") + " (OAuth)", 0, 100),
            ["site"] = grantSite,
            ["scope"] = scope,
            ["hash"] = Hash.Sha256(secret),
            ["hint"] = secret[^4..],
            ["createdAt"] = now,
            ["lastUsedAt"] = null,
        };
        await ctx.Store.InsertTokenAsync(row, cancellationToken).ConfigureAwait(false);
        // Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
        string by = grant.Str("by") ?? "";
        if (grant.Has("by") && by.Length > 0 && ctx.TokenMade != null && !await ctx.TokenMade(row, by, cancellationToken).ConfigureAwait(false))
        {
            await ctx.Store.DeleteTokenAsync(row.Str("id")!, cancellationToken).ConfigureAwait(false);
            return OauthError("invalid_grant", "Whoever allowed this app can no longer connect it");
        }
        // A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
        if (scope == "manage")
        {
            await ctx.Store.SetSettingAsync("token-origin:" + row.Str("id"), new Url(Js.String(grant.Get("redirect"))).Origin, cancellationToken).ConfigureAwait(false);
        }
        // site is not part of OAuth, but a hub needs to know which site it was given.
        var answer = new JsObject { ["access_token"] = secret, ["token_type"] = "Bearer", ["scope"] = scope };
        if (grantSite.Length > 0)
        {
            answer.Set("site", grantSite);
        }
        return JsonAnswer(answer);
    }

    /// <summary><c>new URLSearchParams(Object.entries(await request.json() ?? {}))</c>, each value as String() writes it.</summary>
    private static SearchParams JsonForm(string text)
    {
        var form = new SearchParams();
        if (!Js.ParseJson(text, out object? body) || body == null)
        {
            return form;
        }
        switch (body)
        {
            case JsObject o:
                foreach (var e in o)
                {
                    form.Append(e.Key, Js.String(e.Value));
                }
                break;
            case List<object?> list:
                for (int i = 0; i < list.Count; i++)
                {
                    form.Append(Js.Str(i), Js.String(list[i]));
                }
                break;
            case string s:
                {
                    // Object.entries of a string: one entry for each UTF-16 unit, keyed by its index.
                    int i = 0;
                    foreach (char c in s)
                    {
                        form.Append(Js.Str(i), c.ToString());
                        i++;
                    }
                    break;
                }
        }
        return form;
    }

    /// <summary>
    /// Counts a registration from an address and says whether it is under the limit for this minute. The count is
    /// kept in the install's settings, keyed by an HMAC of the address, so no address is ever stored.
    /// </summary>
    private static async Task<bool> AllowRegistrationAsync(OAuthContext ctx, string ip, CancellationToken cancellationToken)
    {
        // No address cannot be told apart, so it is not limited.
        if (ip.Length == 0)
        {
            return true;
        }
        long now = ctx.Now();
        long window = now / 60_000 - (now < 0 && now % 60_000 != 0 ? 1 : 0);
        string id = Hash.Hmac(await ClientKeyAsync(ctx, cancellationToken).ConfigureAwait(false), "register:" + ip)[..16];
        object? saved = Json.TryParse(await ctx.Store.SettingAsync(Registrations, cancellationToken).ConfigureAwait(false) ?? "");
        var counts = saved is JsObject o && Js.Num(o.Get("window")) == window && o.Get("counts") is JsObject c ? c : new JsObject();
        long count = Js.ToLong(Js.Number(counts.Get(id) ?? 0L)) + 1;
        counts.Set(id, count);
        await ctx.Store.SetSettingAsync(Registrations, Json.Stringify(new JsObject { ["window"] = window, ["counts"] = counts }), cancellationToken).ConfigureAwait(false);
        return count <= RegistrationsPerMinute;
    }

    /// <summary>Registers a client by signing its name and addresses into its id, so nothing is stored until an owner allows it and the app swaps its code.</summary>
    private static async Task<Response> RegisterAsync(OAuthContext ctx, string name, List<string> redirects, CancellationToken cancellationToken)
    {
        long now = ctx.Now();
        // Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
        foreach (var entry in await ctx.Store.SettingsStartingWithAsync("oauth-client:", cancellationToken).ConfigureAwait(false))
        {
            var client = (JsObject)Json.Parse(entry.Str("value")!)!;
            if (!Js.Truthy(client.Get("usedAt")) && now - Js.Number(client.Get("createdAt")) >= UnusedClientMs)
            {
                await ctx.Store.SetSettingAsync(entry.Str("key")!, null, cancellationToken).ConfigureAwait(false);
            }
        }
        foreach (var entry in await ctx.Store.SettingsStartingWithAsync("oauth-code:", cancellationToken).ConfigureAwait(false))
        {
            object? code = Json.TryParse(entry.Str("value")!);
            if (Js.Number(code is JsObject c ? c.Get("expires") ?? 0L : 0L) < now)
            {
                await ctx.Store.SetSettingAsync(entry.Str("key")!, null, cancellationToken).ConfigureAwait(false);
            }
        }
        string trimmed = Js.Slice(Js.Trim(name), 0, 80);
        string clientName = trimmed.Length > 0 ? trimmed : "An app";
        var uris = redirects.Select(r => (object?)r).ToList();
        string payload = Base64url(Json.Stringify(new JsObject { ["n"] = clientName, ["r"] = uris, ["t"] = now }));
        string id = payload + "." + Hash.Hmac(await ClientKeyAsync(ctx, cancellationToken).ConfigureAwait(false), payload);
        if (id.Length > MaxClientId)
        {
            return OauthError("invalid_client_metadata", "Register fewer or shorter redirect addresses");
        }
        return JsonAnswer(
            new JsObject
            {
                ["client_id"] = id,
                ["client_name"] = clientName,
                ["redirect_uris"] = uris,
                ["token_endpoint_auth_method"] = "none",
                ["grant_types"] = Strings("authorization_code"),
                ["response_types"] = Strings("code"),
            },
            201);
    }

    private static Response Page(string title, string body, int status = 200) => new(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>" + title + " | Runlight</title>\n"
        + "<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 6l4 4 4-4' fill='none' stroke='%238a8a93' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style></head><body><main><h1>"
        + title + "</h1>" + body + "</main></body></html>",
        status,
        new Headers
        {
            ["content-type"] = "text/html; charset=utf-8",
            ["cache-control"] = "no-store",
            // No form-action rule: browsers apply it to the redirect back to the app after Allow.
            ["content-security-policy"] = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
            ["x-frame-options"] = "DENY",
            // same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
            ["referrer-policy"] = "same-origin",
        });
}
