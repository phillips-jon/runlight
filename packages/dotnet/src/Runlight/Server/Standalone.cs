using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Store;

namespace Runlight.Server;

/// <summary>What <see cref="Standalone"/> takes.</summary>
public sealed class StandaloneOptions
{
    public required SqlStore Store { get; init; }

    /// <summary>Signs sessions and encrypts saved keys. Keep it stable.</summary>
    public required string Secret { get; init; }

    /// <summary>
    /// Also accepted as a bearer token on the API, for scripts. When there is no <see cref="SetupCode"/>, the first
    /// account is made with it instead.
    /// </summary>
    public string? Token { get; init; }

    /// <summary>
    /// The dashboard's public address, such as https://stats.example.com. It can never become a link domain, short
    /// links never answer on it, and emails link to it whatever Host header a request carries.
    /// </summary>
    public string? Url { get; init; }

    public ProxyTrust TrustProxy { get; init; } = true;

    public Func<string, JsObject?>? Geo { get; init; }

    public bool GeoCredit { get; init; }

    public Func<long>? Now { get; init; }

    public IFetcher? Fetcher { get; init; }

    /// <summary>The one-time code that unlocks /setup while no account exists.</summary>
    public string? SetupCode { get; init; }

    /// <summary>Where <see cref="SetupCode"/> is written down, for the page that asks for it.</summary>
    public string? SetupWhere { get; init; }

    /// <summary>A bearer secret for POST /api/check, for a scheduler that calls it over HTTP.</summary>
    public string? CronSecret { get; init; }

    public string? ObserveKey { get; init; }
}

/// <summary>
/// The standalone server: Runlight's routes at the root of their own domain, behind a sign-in, with sites managed
/// in the dashboard and short links answered on any domain pointed at it. This is the port of
/// packages/server/src/server.ts, by way of the PHP package's; <see cref="Config"/> builds one from the environment
/// or a config.json, and <c>runlight serve</c> serves it on Kestrel.
/// </summary>
public sealed partial class Standalone : IAsyncDisposable
{
    /// <summary>The server's own pages, which answer as the server on every name it is reached at, a link domain too.</summary>
    public static readonly IReadOnlyList<string> ServerPaths = ["/login", "/logout", "/setup", "/invite", "/healthz", "/auth.css", "/auth.js", "/api", "/mcp", "/s.js", "/pick.js", "/e"];

    /// <summary>
    /// The most names remembered as the server's own. The first ones stay and later ones are not learned, so a
    /// server reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
    /// </summary>
    public const int MaxOwnHosts = 20;

    /// <summary>How often the server runs the scheduled check.</summary>
    public static readonly TimeSpan Every = TimeSpan.FromMinutes(5);

    private readonly SqlStore _store;
    private readonly string? _token;
    private readonly ProxyTrust _trustProxy;
    private readonly Url? _publicUrl;
    private readonly string? _publicHost;
    private readonly Func<long> _now;
    private IReadOnlyList<string>? _ownHosts;
    private CancellationTokenSource? _schedule;
    private Task? _scheduled;

    [GeneratedRegex("^/[^/]*\\z", RegexOptions.CultureInvariant)]
    private static partial Regex OneSegment();

    [GeneratedRegex("^/go/[^/]+/?\\z", RegexOptions.CultureInvariant)]
    private static partial Regex GoPath();

    public Standalone(StandaloneOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _store = options.Store;
        _now = options.Now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        _token = !string.IsNullOrEmpty(options.Token) ? options.Token : null;
        _trustProxy = options.TrustProxy;
        _publicUrl = !string.IsNullOrEmpty(options.Url) ? new Url(options.Url) : null;
        _publicHost = _publicUrl != null ? Routes.HostName(_publicUrl.Host) : null;

        var rl = Runlight = new Runlight(new RunlightOptions
        {
            Store = _store,
            ManagedSites = true,
            Secret = options.Secret,
            TrustProxy = _trustProxy,
            Now = _now,
            Geo = options.Geo,
            Fetcher = options.Fetcher,
        });

        // Accounts, shared with apps that turn them on. The first one is made with the one-time code, or with the
        // token when there is no code, and emails link to the public address, or else the first name the owner or
        // an admin signed in from.
        string? code = options.SetupCode;
        Web = new Web(new WebOptions
        {
            Store = _store,
            Secret = options.Secret,
            Base = "",
            Now = _now,
            FirstAccount = !string.IsNullOrEmpty(code) ? FirstAccount.Code(code) : (_token != null ? FirstAccount.Token(_token) : FirstAccount.Locked),
            Home = () => _publicUrl?.Origin ?? (_ownHosts is { Count: > 0 } known ? "https://" + known[0] : null),
            Forgot = "https://runlight.sh/docs/dotnet/#forgotten-passwords",
            SetupWhere = options.SetupWhere,
            MailSettings = ct => rl.MailSettingsAsync(ct),
            SendMail = (m, ct) => rl.SendMailAsync(m, ct),
            ClientIp = rl.ClientIp,
            Later = rl.Later,
        });
        Accounts = Web.Accounts;

        Routes = rl.Routes(new RoutesOptions
        {
            BasePath = "",
            // Without a secret of its own, the cron route is never needed: the server and `runlight cron` run the check themselves.
            CronSecret = !string.IsNullOrEmpty(options.CronSecret) ? options.CronSecret : Hash.RandomId(32),
            ObserveKey = options.ObserveKey ?? "",
            SignOut = "/logout",
            SignIn = "/login",
            GeoCredit = options.GeoCredit,
            AccountsWeb = Web,
            Authorize = AuthorizeAsync,
            OwnHosts = () => _ownHosts ?? [],
            Origin = _publicUrl?.Origin,
        });
    }

    public Runlight Runlight { get; }

    public Accounts.Accounts Accounts { get; }

    public Web Web { get; }

    public Routes Routes { get; }

    private async Task<object> AuthorizeAsync(Request request, CancellationToken cancellationToken)
    {
        string auth = request.Headers.Get("authorization") ?? "";
        if (_token != null && Js.Lower(auth).StartsWith("bearer ", StringComparison.Ordinal) && Crypto.SameText(Js.Trim(auth[7..]), _token))
        {
            return true;
        }
        object access = await Web.AccessAsync(request, cancellationToken).ConfigureAwait(false);
        if (access is true)
        {
            await LearnHostAsync(request, cancellationToken).ConfigureAwait(false);
        }
        return access;
    }

    /// <summary>The name a request came in on, read as link domains read it.</summary>
    private string HostOf(Request request)
    {
        string? forwarded = _trustProxy.On ? request.Headers.Get("x-forwarded-host") : null;
        return Routes.HostName(forwarded ?? request.Headers.Get("host") ?? new Url(request.Url).Host);
    }

    private async Task<List<string>> SavedHostsAsync(CancellationToken cancellationToken)
    {
        await Runlight.InitAsync(cancellationToken).ConfigureAwait(false);
        object? saved;
        try
        {
            saved = Json.Parse(await _store.SettingAsync("server-hosts", cancellationToken).ConfigureAwait(false) ?? "[]");
        }
        catch (JsonParseException)
        {
            return [];
        }
        return saved is List<object?> list ? [.. list.OfType<string>()] : [];
    }

    /// <summary>
    /// The names the owner and admins signed in from, kept in the database, so a link domain can never be one of
    /// them even when whoever adds it picks another Host header.
    /// </summary>
    private async Task<IReadOnlyList<string>> KnownHostsAsync(CancellationToken cancellationToken) =>
        _ownHosts ??= await SavedHostsAsync(cancellationToken).ConfigureAwait(false);

    /// <summary>
    /// Only the owner and admins teach the server its names, since anyone else could fill the list with made-up
    /// ones, and only real domain names. Names that are already link domains are left out.
    /// </summary>
    private async Task LearnHostAsync(Request request, CancellationToken cancellationToken)
    {
        string host = HostOf(request);
        var known = await KnownHostsAsync(cancellationToken).ConfigureAwait(false);
        if (!Routes.DomainName.IsMatch(host) || known.Contains(host) || known.Count >= MaxOwnHosts)
        {
            return;
        }
        foreach (var domain in await _store.LinkDomainsAsync(cancellationToken).ConfigureAwait(false))
        {
            if (domain.Str("domain") == host)
            {
                return;
            }
        }
        var names = known.ToList();
        // Another process may have saved names since this one read them.
        foreach (string saved in await SavedHostsAsync(cancellationToken).ConfigureAwait(false))
        {
            if (!names.Contains(saved))
            {
                names.Add(saved);
            }
        }
        names.Add(host);
        var kept = names.Take(MaxOwnHosts).ToList();
        _ownHosts = kept;
        await _store.SetSettingAsync("server-hosts", Json.Stringify(kept.Select(n => (object?)n).ToList()), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>The answer to one request. <paramref name="ip"/> is the connection's address, when known.</summary>
    public async Task<Response> HandleAsync(Request request, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        string path = new Url(request.Url).Pathname;
        try
        {
            // The names are read once, so the routes and the emails can ask for them as they answer.
            await KnownHostsAsync(cancellationToken).ConfigureAwait(false);
            // A domain pointed at this server for short links answers at its root, with links one segment deep. The
            // server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
            // signed in, so a link domain added on the dashboard's own name can always be removed again.
            bool linkable = path == Runlight.LinkDomainCheck
                || (OneSegment().IsMatch(path) && !ServerPaths.Contains(path) && !(path == "/" && await Web.SignedInAsync(request, cancellationToken).ConfigureAwait(false) != null));
            if (linkable && !(_publicHost != null && HostOf(request) == _publicHost))
            {
                var linked = await Runlight.LinkDomainResponseAsync(request, ip, cancellationToken).ConfigureAwait(false);
                if (linked != null)
                {
                    return linked;
                }
            }
            if (path == "/healthz")
            {
                return new Response("ok", 200, new Headers { ["content-type"] = "text/plain", ["cache-control"] = "no-store" });
            }
            if (request.Method == "GET" && GoPath().IsMatch(path))
            {
                return await Runlight.LinkHandler()(request, ip, cancellationToken).ConfigureAwait(false);
            }
            // Everything else, the sign-in pages and People included, is the routes'.
            return await Routes.HandleAsync(request, ip, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            await Console.Error.WriteLineAsync("Runlight: " + error.Message).ConfigureAwait(false);
            return Routes.Coded("Internal error", "internal", 500);
        }
    }

    /// <summary>The handler, as an adapter takes it.</summary>
    public RequestHandler Handler() => HandleAsync;

    /// <summary>The scheduled work: salts, email reports that are due, retention, and rollups.</summary>
    public async Task<JsObject> CheckAsync(CancellationToken cancellationToken = default)
    {
        var result = await Runlight.CheckAsync(cancellationToken).ConfigureAwait(false);
        await Runlight.IdleAsync().ConfigureAwait(false);
        return result;
    }

    /// <summary>
    /// Starts the scheduled work in the background: now, then every <paramref name="every"/> (five minutes). A run
    /// that starts while another process (<c>runlight cron</c>, or another copy of the server) is still going leaves
    /// it to that one.
    /// </summary>
    public void Schedule(Config config, TimeSpan? every = null)
    {
        ArgumentNullException.ThrowIfNull(config);
        if (_schedule != null)
        {
            return;
        }
        var stop = _schedule = new CancellationTokenSource();
        TimeSpan wait = every ?? Every;
        _scheduled = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                await TickAsync(config, stop.Token).ConfigureAwait(false);
                try
                {
                    await Task.Delay(wait, stop.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        });
    }

    /// <summary>Stops the schedule, for a server shutting down, and waits for a run under way.</summary>
    public async Task StopAsync()
    {
        var stop = _schedule;
        if (stop == null)
        {
            return;
        }
        await stop.CancelAsync().ConfigureAwait(false);
        try
        {
            await (_scheduled ?? Task.CompletedTask).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        stop.Dispose();
        _schedule = null;
        _scheduled = null;
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    /// <summary>One run of the schedule, as <c>runlight cron</c> runs it, with whatever goes wrong said and left for next time.</summary>
    private async Task TickAsync(Config config, CancellationToken cancellationToken)
    {
        try
        {
            using var held = Config.TryLock(config.DataDir() + "/cron.lock");
            if (held != null)
            {
                try
                {
                    await CheckAsync(cancellationToken).ConfigureAwait(false);
                    // The setup link is no use once someone has an account.
                    if (File.Exists(config.SetupFile()) && await Accounts.CountAsync(cancellationToken).ConfigureAwait(false) > 0)
                    {
                        File.Delete(config.SetupFile());
                    }
                }
                catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
                {
                    await Console.Error.WriteLineAsync("Runlight: the scheduled check failed: " + error.Message).ConfigureAwait(false);
                }
                try
                {
                    var dbIp = config.DbIp();
                    if (dbIp != null)
                    {
                        await dbIp.RefreshAsync(_now(), cancellationToken).ConfigureAwait(false);
                    }
                }
                catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
                {
                    await Console.Error.WriteLineAsync("Runlight: could not refresh location data: " + error.Message).ConfigureAwait(false);
                }
            }
            // Another process may have downloaded the release this one reads.
            config.DbIp()?.LoadNewest();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            await Console.Error.WriteLineAsync("Runlight: the scheduled check failed: " + error.Message).ConfigureAwait(false);
        }
    }
}
