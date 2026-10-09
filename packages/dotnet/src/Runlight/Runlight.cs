using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Mail;
using Runlight.Store;

namespace Runlight;

/// <summary>
/// Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports, and the
/// scheduled upkeep. A port of the TypeScript SDK's runlight.ts, by way of the PHP port's Runlight.php.
/// </summary>
/// <remarks>
/// <para>
/// A SiteRow is a JsObject: <c>id</c>, <c>name</c>, <c>hostnames</c> (a list of strings), and <c>timezone</c>.
/// A Remote (a site counted by another install) is a JsObject: <c>url</c>, <c>token</c>, <c>site</c>,
/// <c>hostnames</c>, and <c>scope</c> ("read" or "manage").
/// </para>
/// <para>
/// TypeScript runs some work after answering. Here <see cref="Later"/> queues it and <see cref="IdleAsync"/> runs
/// it, along with the retention a settings change asks for, which an adapter calls once the answer is sent.
/// Everything else runs in <see cref="CheckAsync"/>. Safe to use from several requests at once.
/// </para>
/// </remarks>
public sealed partial class Runlight
{
    /// <summary>A path on every link domain that answers when the domain reaches this Runlight.</summary>
    public const string LinkDomainCheck = "/.well-known/runlight-link-domain";

    /// <summary>Thirty minutes without a request ends a session.</summary>
    public const long SessionIdleMs = 30 * 60 * 1000;

    /// <summary>The choices for how long a site keeps its visits.</summary>
    public static readonly IReadOnlyList<long> RetentionMonths = [6, 12, 24, 36, 60];

    /// <summary>What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets.</summary>
    public static readonly Regex Email = MakeEmail();

    /// <summary>Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. 3: a page counts the views that can report time.</summary>
    private const int RollupVersion = 3;

    /// <summary>Days of rollups built per site in one scheduled check, and how long after a day ends it is built.</summary>
    private const int RollupBatch = 10;

    /// <summary>The most a connected install's list of sites may weigh; a real one is a few kilobytes.</summary>
    private const long RemoteMaxBytes = 2 * 1024 * 1024;

    private const long RollupDelayMs = 2 * 3_600_000;

    private static readonly AsyncLocal<bool> InCheck = new();

    private readonly object _gate = new();
    private readonly Func<string, JsObject?>? _geo;
    private readonly ProxyTrust _trustProxy;
    private readonly RateLimit? _limit;
    private readonly Func<long> _clock;
    private readonly JsObject? _mailInCode;
    private readonly ConcurrentDictionary<string, JsObject> _remoteSeen = new(StringComparer.Ordinal);

    /// <summary>Each timezone's salts for its current day, so a lookup is a map read until midnight there.</summary>
    private readonly ConcurrentDictionary<string, (string Day, string Today, string? Yesterday)> _salts = new(StringComparer.Ordinal);

    /// <summary>Work queued per key by OneAtATimeAsync, such as one visitor's session.</summary>
    private readonly Dictionary<string, Task> _turns = new(StringComparer.Ordinal);

    /// <summary>Work to do once the answer is sent, such as an email whose timing must not show in the answer.</summary>
    private readonly ConcurrentQueue<Func<Task>> _later = new();

    /// <summary>Retention work asked for and not yet done: a site's id, or null for every site.</summary>
    private readonly ConcurrentQueue<string?> _pruning = new();

    private readonly List<string> _routeBases = [];

    /// <summary>The sites as configured in code, or as kept in the database when they are managed; replaced, never changed in place.</summary>
    private List<JsObject> _configured;

    /// <summary>Sites counted by another Runlight install, read through its API with the token it gave; replaced, never changed in place.</summary>
    private Dictionary<string, JsObject> _remotes = new(StringComparer.Ordinal);

    /// <summary>Settings changed in the dashboard, by site; replaced, never changed in place.</summary>
    private Dictionary<string, JsObject> _overrides = new(StringComparer.Ordinal);

    private Task? _ready;
    private bool _isReady;
    private Task<JsObject>? _checking;

    /// <summary>When planner statistics were last gathered.</summary>
    private long _optimizedAt;

    private (long At, HashSet<string> Domains)? _linkDomainCache;

    public Runlight(RunlightOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        Store = options.Store ?? throw new ArgumentException("Runlight: pass a store, such as Stores.Sqlite(SqliteFactory.Instance, \"./data/runlight.db\")", nameof(options));
        ManagedSites = options.ManagedSites;
        IReadOnlyList<SiteOptions> configured = ManagedSites ? [] : options.Sites is { Count: > 0 } ? options.Sites : [options.Site ?? new SiteOptions()];
        _configured = configured.Select(SiteRow).ToList();
        if (_configured.Count > 1 && _configured.Any(site => Hostnames(site).Count == 0))
        {
            throw new ArgumentException("Runlight: with several sites, give each one its hostnames", nameof(options));
        }
        if (_configured.Select(site => site.Str("id")).Distinct(StringComparer.Ordinal).Count() != _configured.Count)
        {
            throw new ArgumentException("Runlight: two sites share an id", nameof(options));
        }
        _geo = options.Geo;
        _trustProxy = options.TrustProxy;
        // null, 0, or anything that is not a positive number means no limit, never a limit of nothing.
        double perMinute = options.RateLimit ?? double.NaN;
        _limit = !(perMinute > 0) ? null : new RateLimit(perMinute >= long.MaxValue ? long.MaxValue : (long)Math.Floor(perMinute), () => Now());
        _clock = options.Now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        Fetcher = options.Fetcher ?? new HttpClientFetcher();
        Links = new Links(Store, Now, InitAsync);
        LinkPath = "/" + EdgeSlashes().Replace(options.LinkPath ?? "/go", "");
        _mailInCode = options.Mail;
        Secret = options.Secret ?? Env.Get("RUNLIGHT_SECRET") ?? Env.Get("RUNLIGHT_TOKEN");
    }

    public SqlStore Store { get; }

    /// <summary>Whether sites are managed in the dashboard.</summary>
    public bool ManagedSites { get; }

    /// <summary>Short links: create, change, delete, and import.</summary>
    public Links Links { get; }

    /// <summary>Where links on the app's own domain are served, such as "/go".</summary>
    public string LinkPath { get; }

    /// <summary>Encrypts the keys kept in the database; null leaves them readable, and the dashboard says so.</summary>
    public string? Secret { get; }

    /// <summary>Every outgoing request goes through it.</summary>
    public IFetcher Fetcher { get; }

    /// <summary>
    /// Where the routes serve the dashboard and API, which a link domain leaves alone, without repeats.
    /// Middleware often runs apart from the routes, where none were made, so the default "/runlight" stands
    /// in there. The routes add theirs with <see cref="AddRouteBase"/>.
    /// </summary>
    public IReadOnlyList<string> RouteBases
    {
        get
        {
            lock (_routeBases)
            {
                return [.. _routeBases];
            }
        }
    }

    /// <summary>Notes where routes are mounted, once each.</summary>
    public void AddRouteBase(string mount)
    {
        lock (_routeBases)
        {
            if (!_routeBases.Contains(mount, StringComparer.Ordinal))
            {
                _routeBases.Add(mount);
            }
        }
    }

    private static JsObject SiteRow(SiteOptions options, int index)
    {
        string timezone = options.Timezone ?? "UTC";
        if (!Time.IsTimezone(timezone))
        {
            throw new ArgumentException("Runlight: unknown timezone \"" + timezone + "\"", nameof(options));
        }
        string id = options.Id ?? (index == 0 ? "default" : "");
        if (id.Length == 0 || !SiteId().IsMatch(id))
        {
            throw new ArgumentException("Runlight: site id \"" + id + "\" must be letters, digits, dots, dashes, or underscores", nameof(options));
        }
        var hostnames = options.Hostnames ?? [];
        return new JsObject
        {
            ["id"] = id,
            ["name"] = options.Name ?? (hostnames.Count > 0 ? hostnames[0] : "My site"),
            ["hostnames"] = hostnames.Select(h => (object?)Sources.StripWww(h)).ToList(),
            ["timezone"] = timezone,
        };
    }

    /// <summary>A site's hostnames, as strings.</summary>
    private static List<string> Hostnames(JsObject site) => site.Arr("hostnames")?.OfType<string>().ToList() ?? [];

    private static string Id(JsObject site) => site.Str("id") ?? "";

    private static string Zone(JsObject site) => site.Str("timezone") ?? "UTC";

    /// <summary>The clock, in milliseconds.</summary>
    public long Now() => _clock();

    // ---- mail

    /// <summary>The mail service: from code, or as saved in the dashboard, with <c>source</c>. Null when there is none.</summary>
    public async Task<JsObject?> MailSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (_mailInCode != null)
        {
            return _mailInCode.With(new JsObject { ["source"] = "code" });
        }
        await InitAsync(cancellationToken).ConfigureAwait(false);
        string? sealedValue = await Store.SettingAsync("mail", cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(sealedValue))
        {
            return null;
        }
        string? opened = Mail.Secret.Unseal(sealedValue, Secret);
        if (string.IsNullOrEmpty(opened))
        {
            return null;
        }
        return (Json.Parse(opened) as JsObject ?? new JsObject()).With(new JsObject { ["source"] = "dashboard" });
    }

    /// <summary>
    /// Saves the mail service from the dashboard. A secret field left blank keeps the saved value, so the
    /// browser never needs to see it. Null removes it.
    /// </summary>
    public async Task SaveMailSettingsAsync(JsObject? input, CancellationToken cancellationToken = default)
    {
        if (_mailInCode != null)
        {
            throw new MailError("The mail service is set in code", "mail_in_code");
        }
        if (input == null)
        {
            await Store.SetSettingAsync("mail", null, cancellationToken).ConfigureAwait(false);
            return;
        }
        var before = await MailSettingsAsync(cancellationToken).ConfigureAwait(false);
        var service = Transports.Services.FirstOrDefault(s => Same(s.Get("id"), input.Prop("service"))) ?? throw new MailError("Pick a mail service", "mail_service");
        var fields = service.Arr("fields")!.Cast<JsObject>().ToList();
        var settings = new JsObject { ["service"] = service.Get("id") };
        foreach (var f in fields.Where(f => !f.Bool("secret")))
        {
            settings[f.Str("name")!] = Js.Trim(Js.String(Given(input, f.Str("name")!) ?? ""));
        }
        // A blank secret keeps the saved one only while the connection is the same,
        // so changing the host cannot send a saved password somewhere new.
        bool sameConnection = before != null && Same(before.Get("service"), service.Get("id"));
        if (sameConnection)
        {
            foreach (var f in fields.Where(f => !f.Bool("secret")))
            {
                if (Js.String(Given(before!, f.Str("name")!) ?? "") != (string)settings[f.Str("name")!]!)
                {
                    sameConnection = false;
                    break;
                }
            }
        }
        foreach (var f in fields.Where(f => f.Bool("secret")))
        {
            string name = f.Str("name")!;
            string given = Js.Trim(Js.String(Given(input, name) ?? ""));
            settings[name] = given.Length == 0 && sameConnection ? Js.String(Given(before!, name) ?? "") : given;
        }
        string from = Js.Trim(Js.String(Given(input, "from") ?? ""));
        if (!Email.IsMatch(from))
        {
            throw new MailError("Enter the address reports come from, like reports@example.com", "mail_from");
        }
        string fromName = Js.Slice(Js.Trim(Js.String(Given(input, "fromName") ?? "")), 0, 80);
        var config = settings.With(new JsObject { ["from"] = from });
        if (fromName.Length > 0)
        {
            config["fromName"] = fromName;
        }
        Transports.CheckConfig(config);
        await Store.SetSettingAsync("mail", Mail.Secret.Seal(Json.Stringify(config), Secret), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Sends one email through the mail service: { to, subject, html, text, headers? }.</summary>
    public async Task SendMailAsync(JsObject message, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(message);
        var settings = await MailSettingsAsync(cancellationToken).ConfigureAwait(false) ?? throw new MailError("Set up a mail service first", "mail_unset");
        var full = message.With(new JsObject { ["from"] = settings.Get("from") });
        if (settings.Get("fromName") != null)
        {
            full["fromName"] = settings.Get("fromName");
        }
        await Transports.SendAsync(settings, full, Fetcher, Now(), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Sends every report that is due: last week's on Monday from 8am, last month's on the 1st, in each site's
    /// timezone. Safe to run often; each period goes out once. Called by <see cref="CheckAsync"/>.
    /// </summary>
    /// <returns>{ sent, failed }.</returns>
    public async Task<JsObject> SendReportsAsync(CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        long sent = 0;
        long failed = 0;
        var reports = await Store.ReportsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        if (reports.Count == 0 || await MailSettingsAsync(cancellationToken).ConfigureAwait(false) == null)
        {
            return Counts(sent, failed);
        }
        long now = Now();
        foreach (var r in reports)
        {
            var site = Site(r.Str("site"));
            if (site == null)
            {
                continue;
            }
            string frequency = r.Str("frequency")!;
            var period = Reports.LastPeriod(frequency, now, Zone(site));
            if (now < period.Long("dueAt") || r.Str("lastPeriod") == period.Str("key"))
            {
                continue;
            }
            if (!await Store.ClaimReportAsync(r.Str("id")!, period.Str("key")!, now, cancellationToken).ConfigureAwait(false))
            {
                continue;
            }
            try
            {
                await DeliverReportAsync(r, site, period, cancellationToken).ConfigureAwait(false);
                sent++;
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                await Store.ReleaseReportAsync(r.Str("id")!, period.Str("key")!, r.Str("lastPeriod") ?? "", cancellationToken).ConfigureAwait(false);
                await Console.Error.WriteLineAsync("Runlight: could not send the " + frequency + " report for " + site.Str("name") + " to " + r.Str("email") + ": " + error.Message).ConfigureAwait(false);
                failed++;
            }
        }
        return Counts(sent, failed);
    }

    private static JsObject Counts(long sent, long failed) => new() { ["sent"] = sent, ["failed"] = failed };

    /// <summary>Builds and sends one report (a ReportRow, to a SiteRow). Also used by "Send a sample now".</summary>
    public async Task DeliverReportAsync(JsObject r, JsObject site, JsObject? period = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(r);
        ArgumentNullException.ThrowIfNull(site);
        string frequency = r.Str("frequency")!;
        period ??= Reports.LastPeriod(frequency, Now(), Zone(site));
        string origin = r.Str("origin") ?? "";
        string unsubscribe = origin + "/unsubscribe/" + r.Str("token");
        var report = await Reports.BuildReportAsync(Store, site, frequency, period, r.Str("lang") ?? "en", new JsObject
        {
            ["dashboard"] = origin + "/?site=" + Js.EncodeURIComponent(Id(site)),
            ["unsubscribe"] = unsubscribe,
        }, cancellationToken).ConfigureAwait(false);
        await SendMailAsync(new JsObject
        {
            ["to"] = r.Get("email"),
            ["subject"] = report.Get("subject"),
            ["html"] = report.Get("html"),
            ["text"] = report.Get("text"),
            ["headers"] = new JsObject { ["List-Unsubscribe"] = "<" + unsubscribe + ">", ["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click" },
        }, cancellationToken).ConfigureAwait(false);
    }

    // ---- start

    /// <summary>Creates tables and records the configured sites. Runs once; a failed start is tried again by the next caller.</summary>
    public async Task InitAsync(CancellationToken cancellationToken = default)
    {
        if (_isReady)
        {
            return;
        }
        Task ready;
        lock (_gate)
        {
            ready = _ready ??= RunInitAsync();
        }
        try
        {
            await ready.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch when (ready.IsFaulted)
        {
            lock (_gate)
            {
                if (_ready == ready)
                {
                    _ready = null;
                }
            }
            throw;
        }
    }

    private async Task RunInitAsync()
    {
        // Run apart from the caller, so its locks and cancellation stay its own.
        await Task.Yield();
        await Store.MigrateAsync().ConfigureAwait(false);
        // A database that never had its statistics gathered gets them now, before any report is read, rather
        // than at the first scheduled check, which an app may never run.
        await Store.OptimizeAsync(true).ConfigureAwait(false);
        if (ManagedSites)
        {
            _configured = await Store.SitesAsync().ConfigureAwait(false);
            await LoadRemotesAsync(CancellationToken.None).ConfigureAwait(false);
        }
        foreach (var site in _configured)
        {
            await Store.UpsertSiteAsync(site, Now()).ConfigureAwait(false);
        }
        _overrides = await Store.SiteOverridesAsync().ConfigureAwait(false);
        // A process starting with a timezone set in code is the newest word on it: if the code changed it,
        // the days built in the old one are cleared here, once, and never by a process still running.
        foreach (var site in Sites())
        {
            if (_remotes.ContainsKey(Id(site)))
            {
                continue;
            }
            string? stored = await Store.SettingAsync("rollup-zone:" + Id(site)).ConfigureAwait(false);
            string? zone = !string.IsNullOrEmpty(stored) ? (Json.Parse(stored) as JsObject)?.Str("zone") : null;
            if (zone == null)
            {
                await Store.SetSettingAsync("rollup-zone:" + Id(site), Json.Stringify(new JsObject { ["zone"] = Zone(site), ["since"] = 0L })).ConfigureAwait(false);
            }
            else if (zone != Zone(site))
            {
                await ZoneChangedAsync(Id(site), Zone(site), CancellationToken.None).ConfigureAwait(false);
            }
        }
        _isReady = true;
    }

    // ---- sites

    /// <summary>The sites, with any settings changed in the dashboard applied.</summary>
    public List<JsObject> Sites()
    {
        var overrides = _overrides;
        return _configured.Select(site => overrides.TryGetValue(Id(site), out var o) ? site.With(o) : site.Clone()).ToList();
    }

    /// <summary>A site by id, or the first site when the id is null or empty; null when there is none.</summary>
    public JsObject? Site(string? id)
    {
        var sites = Sites();
        if (string.IsNullOrEmpty(id))
        {
            return sites.Count > 0 ? sites[0] : null;
        }
        return sites.FirstOrDefault(site => Id(site) == id);
    }

    private bool HasSite(string id) => _configured.Any(site => Id(site) == id);

    /// <summary>Checks a list of hostnames for a managed site: at least one, each a domain, none taken.</summary>
    private List<string> HostnamesFor(object? input, string? except = null)
    {
        IEnumerable<object?> items = input is List<object?> list ? list : SplitSpacesAndCommas(Js.String(input is null or Undefined ? "" : input));
        var hostnames = new List<string>();
        foreach (object? h in items)
        {
            string host = Js.Trim(Js.String(h));
            host = Scheme().Replace(host, "", 1);
            host = PathOrPort().Replace(host, "", 1);
            host = Sources.StripWww(host);
            if (host.Length > 0 && !hostnames.Contains(host, StringComparer.Ordinal))
            {
                hostnames.Add(host);
            }
        }
        if (hostnames.Count == 0)
        {
            throw new SettingsError("Add the site's domain, like example.com", "site_domain_needed");
        }
        foreach (string host in hostnames)
        {
            if (!(host.Length <= 253 && Domain().IsMatch(host)) && host != "localhost")
            {
                throw new SettingsError("\"" + host + "\" is not a domain name", "site_domain_invalid", new JsObject { ["host"] = host });
            }
            var owner = _configured.FirstOrDefault(site => Id(site) != except && Hostnames(site).Contains(host, StringComparer.Ordinal));
            if (owner != null)
            {
                throw new SettingsError(host + " already belongs to " + owner.Str("name"), "site_domain_taken", new JsObject { ["host"] = host, ["site"] = owner.Get("name") });
            }
        }
        return hostnames;
    }

    /// <summary>String(input).split(/[\s,]+/).</summary>
    private static List<object?> SplitSpacesAndCommas(string text)
    {
        var parts = new List<object?>();
        var current = new StringBuilder();
        bool inSeparator = false;
        foreach (char c in text)
        {
            if (c == ',' || Js.IsSpace(c))
            {
                if (!inSeparator)
                {
                    parts.Add(current.ToString());
                    current.Clear();
                    inSeparator = true;
                }
                continue;
            }
            inSeparator = false;
            current.Append(c);
        }
        parts.Add(current.ToString());
        return parts;
    }

    private async Task LoadRemotesAsync(CancellationToken cancellationToken)
    {
        var remotes = new Dictionary<string, JsObject>(StringComparer.Ordinal);
        foreach (var row in await Store.SettingsStartingWithAsync("remote:", cancellationToken).ConfigureAwait(false))
        {
            string? opened = Mail.Secret.Unseal(row.Str("value")!, Secret);
            if (!string.IsNullOrEmpty(opened) && Json.Parse(opened) is JsObject remote)
            {
                remotes[row.Str("key")!["remote:".Length..]] = remote;
            }
        }
        _remotes = remotes;
    }

    private void SetRemote(string id, JsObject? remote)
    {
        lock (_gate)
        {
            var next = new Dictionary<string, JsObject>(_remotes, StringComparer.Ordinal);
            if (remote == null)
            {
                next.Remove(id);
            }
            else
            {
                next[id] = remote;
            }
            _remotes = next;
        }
    }

    /// <summary>The install a site is read from (a Remote), when it is counted elsewhere; null otherwise.</summary>
    public JsObject? Remote(string id) => _remotes.TryGetValue(id, out var remote) ? remote.Clone() : null;

    /// <summary>When a connected install's site last had a visit, asked at most once a minute.</summary>
    public async Task<double?> RemoteLastSeenAsync(string id, CancellationToken cancellationToken = default)
    {
        var info = await RemoteInfoAsync(id, cancellationToken).ConfigureAwait(false);
        object? lastSeen = info?.Get("lastSeen");
        return lastSeen == null ? null : Js.Num(lastSeen);
    }

    /// <summary>
    /// What a connected install says about its site: { lastSeen, retentionMonths, connection }, asked at most
    /// once a minute. Retention is Undefined while the install cannot be reached, and <c>connection</c> says
    /// whether it answered ("ok"), refused this server's token ("refused"), or could not be reached
    /// ("unreachable"). Null for a site that is not connected.
    /// </summary>
    public async Task<JsObject?> RemoteInfoAsync(string id, CancellationToken cancellationToken = default)
    {
        if (!_remotes.TryGetValue(id, out var remote))
        {
            return null;
        }
        if (_remoteSeen.TryGetValue(id, out var cached) && Now() - cached.Long("at") < 60_000)
        {
            return Without(cached, "at");
        }
        var info = new JsObject { ["lastSeen"] = cached?.Get("lastSeen"), ["retentionMonths"] = Undefined.Value, ["connection"] = "unreachable" };
        try
        {
            var answer = await Fetcher.FetchAsync(remote.Str("url") + "/api/sites", new FetchInit
            {
                Headers = new Headers { ["authorization"] = "Bearer " + remote.Str("token") },
                TimeoutMs = 8000,
                MaxBytes = RemoteMaxBytes,
            }, cancellationToken).ConfigureAwait(false);
            if (answer.Status is 401 or 403)
            {
                info["connection"] = "refused";
            }
            var body = await JsonOrNullAsync(answer, cancellationToken).ConfigureAwait(false);
            if (body is JsObject o && o.Get("sites") is List<object?> sites)
            {
                foreach (object? s in sites)
                {
                    if (s is not JsObject site)
                    {
                        // TS reads `s.id` of each and stops at a null, as a throw would.
                        if (s == null)
                        {
                            break;
                        }
                        continue;
                    }
                    if (Same(site.Prop("id"), remote.Prop("site")))
                    {
                        info = new JsObject { ["lastSeen"] = Coalesce(site.Prop("lastSeen")), ["retentionMonths"] = Coalesce(site.Prop("retentionMonths")), ["connection"] = "ok" };
                        break;
                    }
                }
            }
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
        }
        _remoteSeen[id] = new JsObject { ["at"] = Now() }.With(info);
        return info;
    }

    private static JsObject Without(JsObject o, string key)
    {
        var copy = o.Clone();
        copy.Remove(key);
        return copy;
    }

    /// <summary>A value, or null where it is null or undefined (TypeScript's <c>?? null</c>).</summary>
    private static object? Coalesce(object? value) => value is Undefined ? null : value;

    /// <summary>Forgets what a connected install said, after a change made through it.</summary>
    public void ForgetRemoteInfo(string id) => _remoteSeen.TryRemove(id, out _);

    /// <summary>A capped JSON body, or null where TS's readJsonCapped(...).catch(() => null) gives null.</summary>
    private static async Task<object?> JsonOrNullAsync(Response answer, CancellationToken cancellationToken)
    {
        try
        {
            return await Body.ReadJsonCappedAsync(answer, RemoteMaxBytes, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return null;
        }
    }

    /// <summary>Asks a connected install to delete the token this server holds for it. A failure leaves it listed there.</summary>
    private async Task RevokeRemoteTokenAsync(JsObject remote, CancellationToken cancellationToken)
    {
        try
        {
            await Fetcher.FetchAsync(remote.Str("url") + "/api/token", new FetchInit
            {
                Method = "DELETE",
                Headers = new Headers { ["authorization"] = "Bearer " + remote.Str("token") },
                TimeoutMs = 5_000,
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
        }
    }

    /// <summary>
    /// Connects a site counted by another Runlight (an app's own install) so this server shows it too. Takes
    /// the install's address, as its dashboard is (https://example.com/runlight), and an API token made there.
    /// </summary>
    private async Task<JsObject> AddRemoteSiteAsync(JsObject input, CancellationToken cancellationToken)
    {
        string url = TrailingSlashes().Replace(Js.Trim(Js.String(Given(input, "url") ?? "")), "");
        if (!InstallAddress().IsMatch(url))
        {
            throw new SettingsError("Enter the install's address, like https://example.com/runlight", "connect_url");
        }
        string token = Js.Trim(Js.String(Given(input, "token") ?? ""));
        if (token.Length == 0)
        {
            throw new SettingsError("Enter an API token from that install", "install_token");
        }
        Response answer;
        try
        {
            answer = await Fetcher.FetchAsync(url + "/api/sites", new FetchInit
            {
                Headers = new Headers { ["authorization"] = "Bearer " + token },
                TimeoutMs = 10_000,
                MaxBytes = RemoteMaxBytes,
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (BodyTooLongException)
        {
            // An answer too long to read is no Runlight's.
            throw new SettingsError(url + " did not answer like a Runlight install", "connect_not_runlight", new JsObject { ["url"] = url });
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            throw new SettingsError("Could not reach " + url, "unreachable", new JsObject { ["host"] = new Url(url).Host });
        }
        if (answer.Status is 401 or 403)
        {
            throw new SettingsError("That install refused the token", "install_refused");
        }
        var body = await JsonOrNullAsync(answer, cancellationToken).ConfigureAwait(false);
        var sites = body is JsObject o && o.Get("sites") is List<object?> list ? list : [];
        if (!answer.Ok || sites.Count == 0)
        {
            throw new SettingsError(url + " did not answer like a Runlight install", "connect_not_runlight", new JsObject { ["url"] = url });
        }
        // What the token may do there; an install from before manage tokens has no /api/token and reads only.
        string scope = "read";
        string tokenSite = "";
        try
        {
            var about = await Fetcher.FetchAsync(url + "/api/token", new FetchInit
            {
                Headers = new Headers { ["authorization"] = "Bearer " + token },
                TimeoutMs = 10_000,
                MaxBytes = RemoteMaxBytes,
            }, cancellationToken).ConfigureAwait(false);
            var info = about.Ok ? await JsonOrNullAsync(about, cancellationToken).ConfigureAwait(false) as JsObject : null;
            if (info != null && info.Get("scope") is "manage")
            {
                scope = "manage";
            }
            object? site = info?.Get("site");
            tokenSite = Js.String(site ?? "");
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
        }
        object? want = tokenSite.Length > 0 ? tokenSite : input.Prop("site");
        var there = sites.OfType<JsObject>().FirstOrDefault(s => Same(s.Prop("id"), want)) ?? sites[0] as JsObject ?? new JsObject();
        // An install's answer is read as given: a site without a list of hostnames has none.
        var thereHostnames = there.Get("hostnames") is List<object?> hs ? hs.OfType<string>().ToList() : [];
        // Connecting the same site again (to allow changes, or with a new token) updates it in place.
        foreach (var (existing, known) in _remotes)
        {
            if (known.Str("url") == url && Same(known.Prop("site"), there.Prop("id")))
            {
                var updated = known.With(new JsObject { ["token"] = token, ["scope"] = scope, ["hostnames"] = thereHostnames.Cast<object?>().ToList() });
                if (known.Str("token") != token)
                {
                    await RevokeRemoteTokenAsync(known, cancellationToken).ConfigureAwait(false);
                }
                await Store.SetSettingAsync("remote:" + existing, Mail.Secret.Seal(Json.Stringify(updated), Secret), cancellationToken).ConfigureAwait(false);
                SetRemote(existing, updated);
                _remoteSeen.TryRemove(existing, out _);
                return Site(existing)!;
            }
        }
        string host = Js.Lower(NotIdChar().Replace(thereHostnames.Count > 0 ? thereHostnames[0] : new Url(url).Host, "-"));
        string id = Js.Slice(host, 0, 56);
        for (int n = 2; HasSite(id); n++)
        {
            id = Js.Slice(host, 0, 56) + "-" + Js.Str(n);
        }
        string name = Js.Slice(Js.Trim(Js.String(Given(input, "name") ?? "")), 0, 80);
        name = name.Length > 0 ? name : Js.String(there.Prop("name"));
        // No hostnames: tracker hits never land on a site that is counted elsewhere.
        var row = new JsObject
        {
            ["id"] = id,
            ["name"] = name,
            ["hostnames"] = new List<object?>(),
            ["timezone"] = there.Get("timezone") is string tz && Time.IsTimezone(tz) ? tz : "UTC",
        };
        var remoteRow = new JsObject
        {
            ["url"] = url,
            ["token"] = token,
            ["site"] = there.Prop("id"),
            ["hostnames"] = thereHostnames.Cast<object?>().ToList(),
            ["scope"] = scope,
        };
        await Store.UpsertSiteAsync(row, Now(), cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("remote:" + id, Mail.Secret.Seal(Json.Stringify(remoteRow), Secret), cancellationToken).ConfigureAwait(false);
        SetRemote(id, remoteRow);
        lock (_gate)
        {
            _configured = ByName([.. _configured, row]);
        }
        return row.Clone();
    }

    private static readonly System.Globalization.CompareInfo Collation = CultureInfo.GetCultureInfo("en").CompareInfo;

    /// <summary>Sites in name order, as TS sorts them with localeCompare (a stable sort).</summary>
    private static List<JsObject> ByName(IEnumerable<JsObject> sites) =>
        sites.OrderBy(site => site.Str("name") ?? "", Comparer<string>.Create((a, b) => Collation.Compare(a, b, CompareOptions.None))).ToList();

    /// <summary>
    /// Adds a site, when sites are managed in the dashboard: one counted here ({ name, hostnames, timezone }),
    /// or one connected from another install ({ name, remote: { url, token, site } }).
    /// </summary>
    public async Task<JsObject> AddSiteAsync(JsObject input, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        await InitAsync(cancellationToken).ConfigureAwait(false);
        if (!ManagedSites)
        {
            throw new SettingsError("Sites are set in code", "sites_in_code");
        }
        if (input.Get("remote") is JsObject remote)
        {
            var given = remote.Clone();
            given.Remove("name");
            if (input.Has("name"))
            {
                given["name"] = input.Get("name");
            }
            return await AddRemoteSiteAsync(given, cancellationToken).ConfigureAwait(false);
        }
        var hostnames = HostnamesFor(input.Get("hostnames"));
        string name = Js.Trim(Js.String(Given(input, "name") ?? ""));
        name = name.Length > 0 ? name : hostnames[0];
        if (name.Length > 80)
        {
            throw new SettingsError("A site name is 1 to 80 characters", "site_name");
        }
        string timezone = Js.String(Given(input, "timezone") ?? "UTC");
        if (!Time.IsTimezone(timezone))
        {
            throw new SettingsError("Unknown timezone \"" + timezone + "\"", "unknown_timezone", new JsObject { ["timezone"] = timezone });
        }
        string stem = Js.Slice(NotLowerIdChar().Replace(hostnames[0], "-"), 0, 56);
        string id = stem;
        for (int n = 2; HasSite(id); n++)
        {
            id = stem + "-" + Js.Str(n);
        }
        var site = new JsObject { ["id"] = id, ["name"] = name, ["hostnames"] = hostnames.Cast<object?>().ToList(), ["timezone"] = timezone };
        await Store.UpsertSiteAsync(site, Now(), cancellationToken).ConfigureAwait(false);
        lock (_gate)
        {
            _configured = ByName([.. _configured, site]);
        }
        return site.Clone();
    }

    /// <summary>Deletes a site and everything recorded for it, when sites are managed in the dashboard.</summary>
    public async Task DeleteSiteAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        if (!ManagedSites)
        {
            throw new SettingsError("Sites are set in code", "sites_in_code");
        }
        if (!HasSite(id))
        {
            throw new SettingsError("Unknown site", "unknown_site");
        }
        await Store.DeleteSiteAsync(id, cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("retention:" + id, null, cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("observe-key:" + id, null, cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("rollup-zone:" + id, null, cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("orphans-swept:" + id, null, cancellationToken).ConfigureAwait(false);
        // A site made again with the same id starts its Umami import from the beginning.
        foreach (var row in await Store.SettingsStartingWithAsync("import:umami-visits:" + id + ":", cancellationToken).ConfigureAwait(false))
        {
            await Store.SetSettingAsync(row.Str("key")!, null, cancellationToken).ConfigureAwait(false);
        }
        // A connected install keeps its own data; only the connection goes, and its token there with it.
        if (_remotes.TryGetValue(id, out var remote))
        {
            await RevokeRemoteTokenAsync(remote, cancellationToken).ConfigureAwait(false);
            SetRemote(id, null);
            await Store.SetSettingAsync("remote:" + id, null, cancellationToken).ConfigureAwait(false);
        }
        lock (_gate)
        {
            _configured = _configured.Where(site => Id(site) != id).ToList();
            var overrides = new Dictionary<string, JsObject>(_overrides, StringComparer.Ordinal);
            overrides.Remove(id);
            _overrides = overrides;
        }
    }

    /// <summary>
    /// Changes a site's name or timezone from the dashboard. Stored apart from the settings in code, which
    /// keep being written on every start. A managed site has no settings in code, so its changes, hostnames
    /// too, go to its row. A key left out of <paramref name="patch"/> (or Undefined) is left alone.
    /// </summary>
    public async Task<JsObject> UpdateSiteAsync(string id, JsObject patch, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(patch);
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var current = _configured.LastOrDefault(site => Id(site) == id) ?? throw new SettingsError("Unknown site", "unknown_site");
        var next = ManagedSites ? current.Clone() : (_overrides.TryGetValue(id, out var o) ? o.Clone() : new JsObject());
        if (patch.Prop("name") is not Undefined)
        {
            string name = Js.Trim(Js.String(patch.Get("name")));
            if (name.Length == 0 || name.Length > 80)
            {
                throw new SettingsError("A site name is 1 to 80 characters", "site_name");
            }
            next["name"] = name;
        }
        if (patch.Prop("timezone") is not Undefined)
        {
            string timezone = Js.String(patch.Get("timezone"));
            if (!Time.IsTimezone(timezone))
            {
                throw new SettingsError("Unknown timezone \"" + timezone + "\"", "unknown_timezone", new JsObject { ["timezone"] = timezone });
            }
            next["timezone"] = timezone;
            if (timezone != Site(id)?.Str("timezone"))
            {
                await ZoneChangedAsync(id, timezone, cancellationToken).ConfigureAwait(false);
            }
        }
        if (ManagedSites)
        {
            if (patch.Prop("hostnames") is not Undefined && !_remotes.ContainsKey(id))
            {
                next["hostnames"] = HostnamesFor(patch.Get("hostnames"), id).Cast<object?>().ToList();
            }
            await Store.UpsertSiteAsync(next, Now(), cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                _configured = _configured.Select(site => Id(site) == id ? next : site).ToList();
            }
            return Site(id)!;
        }
        await Store.SetSiteOverridesAsync(id, next, cancellationToken).ConfigureAwait(false);
        lock (_gate)
        {
            _overrides = new Dictionary<string, JsObject>(_overrides, StringComparer.Ordinal) { [id] = next };
        }
        return Site(id)!;
    }

    // ---- retention

    /// <summary>How many months of visits a site keeps, or null to keep everything (the default).</summary>
    public async Task<long?> RetentionAsync(string site, CancellationToken cancellationToken = default)
    {
        double value = Js.Number(await Store.SettingAsync("retention:" + site, cancellationToken).ConfigureAwait(false));
        return RetentionMonths.Contains((long)value) && value == Math.Floor(value) ? (long)value : null;
    }

    /// <summary>
    /// Sets how many months of visits a site keeps (one of <see cref="RetentionMonths"/>, or null for forever).
    /// Deleting a long history takes a while, so it runs in <see cref="IdleAsync"/>, after the answer, with
    /// tracking going on between its pieces, as TS runs it after answering.
    /// </summary>
    public async Task SetRetentionAsync(string site, double? months, CancellationToken cancellationToken = default)
    {
        if (Site(site) == null || _remotes.ContainsKey(site))
        {
            throw new SettingsError("Unknown site", "unknown_site");
        }
        if (months != null && !RetentionMonths.Any(m => m == months))
        {
            string list = string.Join(", ", RetentionMonths.Select(Js.Str));
            throw new SettingsError("Keep visits for " + list + " months, or forever", "retention_bad", new JsObject { ["months"] = list });
        }
        await Store.SetSettingAsync("retention:" + site, months == null ? null : Json.Number(months.Value), cancellationToken).ConfigureAwait(false);
        _pruning.Enqueue(site);
    }

    /// <summary>Queues work for <see cref="IdleAsync"/>, so it runs after the answer is sent, as TypeScript leaves a promise running.</summary>
    public void Later(Func<Task> work) => _later.Enqueue(work);

    /// <summary>
    /// Runs the work still waiting from earlier calls (<see cref="Later"/> work and a retention change's
    /// deletions). An adapter calls it once the answer is out; the scheduled check and tests wait for it.
    /// </summary>
    public async Task IdleAsync()
    {
        while (_later.TryDequeue(out var work))
        {
            try
            {
                await work().ConfigureAwait(false);
            }
            catch (Exception error)
            {
                await Console.Error.WriteLineAsync("Runlight: " + error.Message).ConfigureAwait(false);
            }
        }
        while (_pruning.TryDequeue(out string? only))
        {
            try
            {
                await ApplyRetentionAsync(only, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                await Console.Error.WriteLineAsync("Runlight: could not apply retention " + error.Message).ConfigureAwait(false);
            }
        }
    }

    /// <summary>
    /// Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded before
    /// the change were made per day of the old timezone, and could count one person twice in a new day, so
    /// only days that start after the change are built; earlier ones are always counted visit by visit.
    /// </summary>
    private async Task<long> ZoneChangedAsync(string id, string timezone, CancellationToken cancellationToken)
    {
        long since = Now();
        await Store.ClearRollupsAsync(id, cancellationToken: cancellationToken).ConfigureAwait(false);
        await Store.SetSettingAsync("rollup-zone:" + id, Json.Stringify(new JsObject { ["zone"] = timezone, ["since"] = since }), cancellationToken).ConfigureAwait(false);
        return since;
    }

    /// <summary>
    /// Since when a site's days may be built: 0 for always, or when its timezone last changed. Null when
    /// this process holds a different timezone than the one on record, such as an older copy still running
    /// during a deploy, or one that has not yet seen a change made in the dashboard. It builds nothing for
    /// that site, and reports read the visits themselves for any day not built, so nothing is wrong meanwhile.
    /// </summary>
    private async Task<double?> RollupSinceAsync(JsObject site, CancellationToken cancellationToken)
    {
        string? stored = await Store.SettingAsync("rollup-zone:" + Id(site), cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(stored))
        {
            await Store.SetSettingAsync("rollup-zone:" + Id(site), Json.Stringify(new JsObject { ["zone"] = Zone(site), ["since"] = 0L }), cancellationToken).ConfigureAwait(false);
            return 0;
        }
        var zone = Json.Parse(stored) as JsObject;
        return zone?.Str("zone") == Zone(site) ? zone.Num("since") : null;
    }

    /// <summary>
    /// Adds up each site's finished days, so long ranges read a row a day instead of every visit. A day is
    /// built two hours after it ends in the site's timezone, once late engagement has landed, and at most
    /// RollupBatch days a run, so a long history fills in over a few runs. Reports read the raw visits for
    /// any day not built yet, so the numbers are the same either way. Only a visit still going two hours past
    /// midnight, with no 30 minute gap, could add to a day after it is built.
    /// </summary>
    /// <returns>How many days were built.</returns>
    public async Task<int> BuildRollupsAsync(CancellationToken cancellationToken = default)
    {
        // Days rolled up by an earlier way of counting are cleared once, and built again below.
        if (await Store.SettingAsync("rollup-version", cancellationToken).ConfigureAwait(false) != Js.Str(RollupVersion))
        {
            foreach (var site in Sites())
            {
                await Store.ClearRollupsAsync(Id(site), cancellationToken: cancellationToken).ConfigureAwait(false);
            }
            await Store.SetSettingAsync("rollup-version", Js.Str(RollupVersion), cancellationToken).ConfigureAwait(false);
        }
        int built = 0;
        long now = Now();
        // TypeScript builds fewer days a check on a database that caps statements per request (Cloudflare
        // D1); no .NET database does.
        int batch = RollupBatch;
        foreach (var site in Sites())
        {
            string id = Id(site);
            string tz = Zone(site);
            if (_remotes.ContainsKey(id))
            {
                continue;
            }
            double? first = await Store.FirstSeenAsync(id, cancellationToken).ConfigureAwait(false);
            if (first == null)
            {
                continue;
            }
            long cutoff = await RetentionCutoffAsync(id, cancellationToken).ConfigureAwait(false) ?? 0;
            double? since = await RollupSinceAsync(site, cancellationToken).ConfigureAwait(false);
            if (since == null)
            {
                continue;
            }
            var done = new HashSet<string>(await Store.RollupDaysAsync(id, cancellationToken).ConfigureAwait(false), StringComparer.Ordinal);
            string today = Time.LocalDate(now, tz);
            string oldest = Time.LocalDate((long)Math.Max(first.Value, cutoff), tz);
            int made = 0;
            // Newest first, so recent ranges speed up before a long history is done.
            for (string day = Time.AddDays(today, -1); string.CompareOrdinal(day, oldest) >= 0 && made < batch; day = Time.AddDays(day, -1))
            {
                if (done.Contains(day))
                {
                    continue;
                }
                long start = Time.StartOf(day, tz);
                long end = Time.StartOf(Time.AddDays(day, 1), tz);
                if (start < since)
                {
                    break;
                }
                if (now < end + RollupDelayMs || start < cutoff)
                {
                    continue;
                }
                try
                {
                    await Store.BuildRollupDayAsync(id, day, start, end, cancellationToken).ConfigureAwait(false);
                    made++;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    // Another process building the same day at once loses nothing: the day is there either way.
                    if (!(await Store.RollupDaysAsync(id, cancellationToken).ConfigureAwait(false)).Contains(day, StringComparer.Ordinal))
                    {
                        await Console.Error.WriteLineAsync("Runlight: could not add up " + day + " for " + id + " " + error.Message).ConfigureAwait(false);
                    }
                }
            }
            built += made;
        }
        return built;
    }

    // ---- the assistant

    /// <summary>The dashboard assistant's { provider, model, baseUrl, key }, kept sealed like the mail keys. Null until an owner sets it up.</summary>
    public async Task<JsObject?> AssistantSettingsAsync(CancellationToken cancellationToken = default)
    {
        string? stored = await Store.SettingAsync("assistant", cancellationToken).ConfigureAwait(false);
        string? opened = !string.IsNullOrEmpty(stored) ? Mail.Secret.Unseal(stored, Secret) : null;
        return !string.IsNullOrEmpty(opened) ? Json.Parse(opened) as JsObject : null;
    }

    /// <summary>Saves the assistant's settings; an empty key keeps the one saved for the same provider. Null removes them.</summary>
    public async Task SaveAssistantSettingsAsync(JsObject? input, CancellationToken cancellationToken = default)
    {
        if (input == null)
        {
            await Store.SetSettingAsync("assistant", null, cancellationToken).ConfigureAwait(false);
            return;
        }
        var provider = Assistant.Providers.FirstOrDefault(p => Same(p.Id, input.Prop("provider"))) ?? throw new SettingsError("Choose a provider", "assistant_provider");
        string baseUrl = TrailingSlashes().Replace(Js.Trim(Js.String(Given(input, "baseUrl") ?? "")), "");
        if (baseUrl.Length > 0)
        {
            var parsed = Url.Parse(baseUrl);
            if (parsed == null || (parsed.Protocol != "https:" && parsed.Protocol != "http:"))
            {
                throw new SettingsError("Enter the service's address, starting with https://", "assistant_address_bad");
            }
        }
        if (baseUrl.Length == 0 && provider.BaseUrl.Length == 0)
        {
            throw new SettingsError("Enter the service's address", "assistant_address");
        }
        string model = Js.Slice(Js.Trim(Js.String(Given(input, "model") ?? "")), 0, 200);
        if (model.Length == 0 && provider.Model.Length == 0)
        {
            throw new SettingsError("Enter the model to use", "assistant_model");
        }
        var before = await AssistantSettingsAsync(cancellationToken).ConfigureAwait(false);
        string key = Js.Trim(Js.String(Given(input, "key") ?? ""));
        // A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
        string beforeBase = before?.Str("baseUrl") ?? "";
        if (key.Length == 0 && before?.Str("provider") == provider.Id && (beforeBase.Length > 0 ? beforeBase : provider.BaseUrl) == (baseUrl.Length > 0 ? baseUrl : provider.BaseUrl))
        {
            key = before?.Str("key") ?? "";
        }
        if (key.Length == 0 && provider.Key == "yes")
        {
            throw new SettingsError("Enter your " + provider.Name + " key", "assistant_key", new JsObject { ["provider"] = provider.Name });
        }
        var settings = new JsObject { ["provider"] = provider.Id, ["model"] = model, ["baseUrl"] = baseUrl, ["key"] = key };
        await Store.SetSettingAsync("assistant", Mail.Secret.Seal(Json.Stringify(settings), Secret), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>The oldest moment a site keeps visits from, or null when it keeps everything.</summary>
    public async Task<long?> RetentionCutoffAsync(string site, CancellationToken cancellationToken = default)
    {
        long? months = await RetentionAsync(site, cancellationToken).ConfigureAwait(false);
        if (months == null)
        {
            return null;
        }
        // setUTCMonth: the same day and time that many months back, a day past the month's end running on.
        long now = Now();
        long ms = ((now % 1000) + 1000) % 1000;
        var at = DateTimeOffset.FromUnixTimeMilliseconds(now - ms).UtcDateTime;
        return Time.Utc(at.Year, at.Month - 1 - months.Value, at.Day, at.Hour, at.Minute, at.Second) + ms;
    }

    /// <summary>Deletes visits older than each site's retention allows. Cheap when there is nothing to delete.</summary>
    private async Task ApplyRetentionAsync(string? only, CancellationToken cancellationToken)
    {
        foreach (var site in Sites())
        {
            string id = Id(site);
            if ((!string.IsNullOrEmpty(only) && id != only) || _remotes.ContainsKey(id))
            {
                continue;
            }
            long? cutoff = await RetentionCutoffAsync(id, cancellationToken).ConfigureAwait(false);
            if (cutoff == null)
            {
                continue;
            }
            await Store.DropBeforeAsync(id, cutoff.Value, cancellationToken).ConfigureAwait(false);
            // Earlier versions let an event join its visit days late, so retention could leave such an event behind
            // once its visit was gone. They are swept once; events can no longer join a visit that late.
            if (!Js.Truthy(await Store.SettingAsync("orphans-swept:" + id, cancellationToken).ConfigureAwait(false)))
            {
                await Store.DropOrphansAsync(id, cutoff.Value, Now(), cancellationToken).ConfigureAwait(false);
                await Store.SetSettingAsync("orphans-swept:" + id, "1", cancellationToken).ConfigureAwait(false);
            }
        }
    }

    // ---- tracking

    /// <summary>The site a page belongs to, or null if it belongs to none.</summary>
    public JsObject? SiteFor(string hostname, string? id = null)
    {
        string host = Sources.StripWww(hostname);
        var remotes = _remotes;
        // A site counted by another install never takes hits here.
        if (remotes.Count > 0)
        {
            var local = Sites().Where(site => !remotes.ContainsKey(Id(site))).ToList();
            if (!string.IsNullOrEmpty(id))
            {
                return remotes.ContainsKey(id) ? null : SiteForAmong(local, host, id);
            }
            return SiteForAmong(local, host);
        }
        return SiteForAmong(Sites(), host, id);
    }

    private static JsObject? SiteForAmong(List<JsObject> sites, string host, string? id = null)
    {
        if (!string.IsNullOrEmpty(id))
        {
            var site = sites.FirstOrDefault(s => Id(s) == id);
            return site != null && (Hostnames(site).Count == 0 || Hostnames(site).Contains(host, StringComparer.Ordinal)) ? site : null;
        }
        if (sites.Count == 1)
        {
            var only = sites[0];
            return Hostnames(only).Count == 0 || Hostnames(only).Contains(host, StringComparer.Ordinal) ? only : null;
        }
        return sites.FirstOrDefault(site => Hostnames(site).Contains(host, StringComparer.Ordinal));
    }

    /// <summary>
    /// A test from a developer's own machine while a site is being set up. A site with no visits yet accepts
    /// hits from localhost and .local or .test names, so the install screen confirms it works; after its first
    /// visit they are ignored again, so local browsing never mixes with real traffic.
    /// </summary>
    private async Task<JsObject?> SetupSiteAsync(string hostname, string? id, CancellationToken cancellationToken)
    {
        string host = Js.Lower(hostname);
        if (host.StartsWith('['))
        {
            host = host[1..];
        }
        if (host.EndsWith(']'))
        {
            host = host[..^1];
        }
        if (!(host is "localhost" or "127.0.0.1" or "::1" || host.EndsWith(".localhost", StringComparison.Ordinal) || host.EndsWith(".local", StringComparison.Ordinal) || host.EndsWith(".test", StringComparison.Ordinal)))
        {
            return null;
        }
        var sites = Sites();
        var site = !string.IsNullOrEmpty(id) ? Site(id) : (sites.Count == 1 ? sites[0] : null);
        if (site == null || _remotes.ContainsKey(Id(site)))
        {
            return null;
        }
        return await Store.LastSeenAsync(Id(site), cancellationToken).ConfigureAwait(false) == null ? site : null;
    }

    /// <summary>
    /// The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes from a
    /// header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote and a client
    /// cannot choose (Vercel, Netlify, Cloudflare, Caddy, and nginx all append there), then X-Real-IP and
    /// CF-Connecting-IP. Naming one header (after another proxy in front, such as Cloudflare before nginx)
    /// reads only that one. Otherwise it is the connection's address: <paramref name="ip"/>, or else the
    /// request's own RemoteAddress.
    /// </summary>
    public string ClientIp(Request request, string? ip = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (_trustProxy.On)
        {
            var h = request.Headers;
            string? Last(string name)
            {
                string? value = h.Get(name);
                if (value == null)
                {
                    return null;
                }
                var parts = value.Split(',').Select(Js.Trim).Where(x => x.Length > 0).ToList();
                return parts.Count == 0 ? null : parts[^1];
            }
            string? forwarded = _trustProxy.Header == null
                ? Last("x-forwarded-for") ?? h.Get("x-real-ip") ?? h.Get("cf-connecting-ip")
                : (_trustProxy.Header == "x-forwarded-for" ? Last("x-forwarded-for") : h.Get(_trustProxy.Header));
            if (forwarded != null && Js.Trim(forwarded).Length > 0)
            {
                return Js.Trim(forwarded);
            }
        }
        return ip ?? request.RemoteAddress;
    }

    /// <summary>
    /// Today's salt in a site's timezone and, if it still exists, yesterday's. Salts follow the site's own
    /// days, as its reports do, so a visitor is one visitor for the whole of that site's day. Old salts go
    /// on the way.
    /// </summary>
    private async Task<(string Day, string Today, string? Yesterday)> CurrentSaltsAsync(long now, string timezone, CancellationToken cancellationToken)
    {
        string day = Time.LocalDate(now, timezone);
        if (_salts.TryGetValue(timezone, out var cached) && cached.Day == day)
        {
            return cached;
        }
        string today = await Store.SaltAsync(day, Hash.RandomSalt(), cancellationToken).ConfigureAwait(false);
        string? yesterday = await Store.SaltIfExistsAsync(Time.AddDays(day, -1), cancellationToken).ConfigureAwait(false);
        await DropOldSaltsAsync(now, cancellationToken).ConfigureAwait(false);
        var salts = (day, today, yesterday);
        _salts[timezone] = salts;
        return salts;
    }

    /// <summary>
    /// Deletes salts whose day has ended everywhere. The earliest timezone is a day behind UTC and still
    /// needs its yesterday, so a salt goes two UTC days after its date.
    /// </summary>
    private Task DropOldSaltsAsync(long now, CancellationToken cancellationToken) =>
        Store.DropSaltsBeforeAsync(Js.IsoString(now - 2 * 86_400_000)[..10], cancellationToken);

    /// <summary>The host a proxy says the request was for, read only when proxy headers are trusted, as the client's address is.</summary>
    private string? ForwardedHost(Request request) => _trustProxy.On ? request.Headers.Get("x-forwarded-host") : null;

    /// <summary>
    /// Handles one tracker request. Bad input is dropped quietly; only a database that keeps failing throws.
    /// </summary>
    /// <param name="request">The tracker's POST.</param>
    /// <param name="ip">The connection's address, when the request does not carry it.</param>
    /// <param name="cancellationToken">Stops the work.</param>
    public async Task CollectAsync(Request request, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        double length = Js.Number(request.Headers.Get("content-length") ?? (object)0L);
        if (length > Payload.MaxBody)
        {
            return;
        }
        // Read no more than a tracker hit can be, whatever the length header says (or when there is none).
        byte[] bytes = request.Bytes();
        if (bytes.Length > Payload.MaxBody)
        {
            return;
        }
        var payload = Payload.ParsePayload(Body.Utf8(bytes));
        if (payload == null)
        {
            return;
        }

        string ua = request.Headers.Get("user-agent") ?? "";
        if (Ua.AiAgent(ua) != null || Ua.IsBot(ua))
        {
            return;
        }
        if (_limit != null && !_limit.Allow(ClientIp(request, ip)))
        {
            return;
        }

        // A database too busy to take the hit right now (every pooled connection held by long reports, or
        // another process writing the SQLite file) gets it a little later, at the time it arrived.
        long now = Now();
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                await RecordAsync(payload, request, ip, now, cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (Exception error) when (attempt < 3 && Busy(error))
            {
                await Task.Delay(500 * attempt, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private async Task RecordAsync(Payload payload, Request request, string? ip, long now, CancellationToken cancellationToken)
    {
        // Managed sites load from the database in init, so it must come first.
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var url = payload.Url;
        var site = SiteFor(url.Hostname, payload.Site) ?? await SetupSiteAsync(url.Hostname, payload.Site, cancellationToken).ConfigureAwait(false);
        if (site == null)
        {
            return;
        }

        if (payload.Kind == "engagement")
        {
            await EngagementAsync(site, payload, now, cancellationToken).ConfigureAwait(false);
            return;
        }

        var page = Sources.ParsePage(url);
        (string Id, string Visitor)? session = null;
        bool reopen = true;
        if (payload.Kind == "event" && payload.PageviewId.Length > 0)
        {
            var pageview = await Store.PageviewAsync(Id(site), payload.PageviewId, cancellationToken).ConfigureAwait(false);
            // An event joins its page's visit unless that visit began longer ago than reports look for its rows
            // (a tab left open for days); it then starts a visit of its own, as any later activity would.
            if (pageview != null && now - pageview.Num("startedAt") < SqlStore.EventTailMs)
            {
                session = (pageview.Str("session")!, pageview.Str("visitor")!);
                // A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
                reopen = now - pageview.Num("lastAt") <= SessionIdleMs;
                if (now - pageview.Num("startedAt") > 3_600_000)
                {
                    await Store.TouchedOldVisitAsync(Id(site), pageview.Long("startedAt"), now - RollupDelayMs + 3_600_000, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        session ??= await SessionForAsync(
            site,
            request,
            ip,
            page,
            payload.Referrer,
            now,
            payload.ScreenWidth,
            payload.ScreenWidth is > 0 or < 0 && payload.ScreenHeight is > 0 or < 0 ? Js.Str(payload.ScreenWidth.Value) + "x" + Js.Str(payload.ScreenHeight.Value) : "",
            payload.Language,
            cancellationToken).ConfigureAwait(false);

        string path = page.Str("path")!;
        await Store.TouchSessionAsync(session.Value.Id, now, payload.Kind, path, reopen, cancellationToken).ConfigureAwait(false);
        await Store.InsertEventAsync(new JsObject
        {
            ["site"] = Id(site),
            ["ts"] = now,
            ["kind"] = payload.Kind,
            ["visitor"] = session.Value.Visitor,
            ["session"] = session.Value.Id,
            ["pageview"] = payload.PageviewId,
            ["path"] = path,
            ["hostname"] = page.Get("hostname"),
            ["title"] = payload.Kind == "pageview" ? payload.Title : "",
            ["name"] = payload.Kind == "event" ? payload.Name : "",
            ["props"] = payload.Props,
            ["engagedMs"] = 0L,
            ["scroll"] = null,
            ["link"] = "",
        }, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// The visitor's open session on a site, or a new one attributed to this request. Shared by tracker hits
    /// and short link clicks.
    /// </summary>
    private async Task<(string Id, string Visitor)> SessionForAsync(
        JsObject site,
        Request request,
        string? ip,
        JsObject page,
        string referrer,
        long now,
        long? screenWidth,
        string screen,
        string language,
        CancellationToken cancellationToken)
    {
        string ua = request.Headers.Get("user-agent") ?? "";
        string address = ClientIp(request, ip);
        var salts = await CurrentSaltsAsync(now, Zone(site), cancellationToken).ConfigureAwait(false);
        string today = Hash.VisitorHash(salts.Today, Id(site), address, ua);
        var candidates = new List<string> { today };
        if (!string.IsNullOrEmpty(salts.Yesterday))
        {
            candidates.Add(Hash.VisitorHash(salts.Yesterday, Id(site), address, ua));
        }
        // One visitor's requests often arrive together (a pageview and the event
        // right after it). Taking turns per visitor means only the first opens a
        // session and the rest find it, instead of each opening its own.
        return await OneAtATimeAsync(Id(site) + ":" + today, async () =>
        {
            var open = await Store.OpenSessionAsync(Id(site), candidates, now - SessionIdleMs, cancellationToken).ConfigureAwait(false);
            if (open != null)
            {
                return (open.Str("id")!, open.Str("visitor")!);
            }

            string id = Hash.RandomId();
            var attribution = Sources.Attribute(page, referrer, Hostnames(site));
            var parsed = Ua.ParseClient(
                ua,
                new JsObject
                {
                    ["brands"] = request.Headers.Get("sec-ch-ua"),
                    ["mobile"] = request.Headers.Get("sec-ch-ua-mobile"),
                    ["platform"] = request.Headers.Get("sec-ch-ua-platform"),
                },
                screenWidth);
            var location = Geo.Locate(request.Headers, address, _geo);
            var utm = page.Obj("utm")!;
            var row = new JsObject
            {
                ["id"] = id,
                ["site"] = Id(site),
                ["visitor"] = today,
                ["startedAt"] = now,
                ["hostname"] = page.Get("hostname"),
            }
                .With(attribution)
                .With(new JsObject
                {
                    ["utmSource"] = utm.Get("source"),
                    ["utmMedium"] = utm.Get("medium"),
                    ["utmCampaign"] = utm.Get("campaign"),
                    ["utmTerm"] = utm.Get("term"),
                    ["utmContent"] = utm.Get("content"),
                })
                .With(location)
                .With(parsed)
                .With(new JsObject { ["screen"] = screen, ["language"] = language });
            await Store.InsertSessionAsync(row, cancellationToken).ConfigureAwait(false);
            return (id, today);
        }).ConfigureAwait(false);
    }

    /// <summary>Runs <paramref name="fn"/> after any earlier call with the same key has finished.</summary>
    private async Task<T> OneAtATimeAsync<T>(string key, Func<Task<T>> fn)
    {
        var turn = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task previous;
        lock (_turns)
        {
            previous = _turns.TryGetValue(key, out var p) ? p : Task.CompletedTask;
            _turns[key] = turn.Task;
        }
        try
        {
            await previous.ConfigureAwait(false);
            return await fn().ConfigureAwait(false);
        }
        finally
        {
            lock (_turns)
            {
                if (_turns.TryGetValue(key, out var current) && current == turn.Task)
                {
                    _turns.Remove(key);
                }
            }
            turn.SetResult();
        }
    }

    private async Task EngagementAsync(JsObject site, Payload payload, long now, CancellationToken cancellationToken)
    {
        if (payload.EngagedMs <= 0)
        {
            return;
        }
        var pageview = await Store.PageviewAsync(Id(site), payload.PageviewId, cancellationToken).ConfigureAwait(false);
        // Reports look for a visit's rows only so long after it began, so later time on it is let go.
        if (pageview == null || now - pageview.Num("startedAt") >= SqlStore.EventTailMs)
        {
            return;
        }
        await Store.AddEngagementAsync(pageview.Str("session")!, payload.EngagedMs, cancellationToken).ConfigureAwait(false);
        // Only a visit that began more than an hour ago can belong to a day that is already added up.
        if (now - pageview.Num("startedAt") > 3_600_000)
        {
            await Store.TouchedOldVisitAsync(Id(site), pageview.Long("startedAt"), now - RollupDelayMs + 3_600_000, cancellationToken).ConfigureAwait(false);
        }
        await Store.InsertEventAsync(new JsObject
        {
            ["site"] = Id(site),
            ["ts"] = now,
            ["kind"] = "engagement",
            ["visitor"] = pageview.Get("visitor"),
            ["session"] = pageview.Get("session"),
            ["pageview"] = payload.PageviewId,
            ["path"] = pageview.Get("path"),
            ["hostname"] = pageview.Get("hostname"),
            ["title"] = "",
            ["name"] = "",
            ["props"] = null,
            ["engagedMs"] = payload.EngagedMs,
            ["scroll"] = payload.Scroll,
            ["link"] = "",
        }, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Records a request from a known AI agent. Call it from middleware for every page request; it ignores
    /// everything else and never throws. Agents do not run JavaScript, so the tracker cannot see them.
    /// </summary>
    /// <param name="request">The page request.</param>
    /// <param name="at">When a log reader says the page was served, in epoch milliseconds; now when null.</param>
    /// <param name="cancellationToken">Stops the work.</param>
    public async Task<bool> ObserveAsync(Request request, double? at = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            if (request.Method != "GET")
            {
                return false;
            }
            var agent = Ua.AiAgent(request.Headers.Get("user-agent") ?? "");
            if (agent == null)
            {
                return false;
            }
            var url = new Url(request.Url);
            // Pages, not their assets.
            var m = Extension().Match(url.Pathname);
            if (m.Success && !(Js.Lower(m.Groups[1].Value) is "html" or "htm" or "md" or "txt" or "php"))
            {
                return false;
            }
            string host = ForwardedHost(request) ?? request.Headers.Get("host") ?? url.Hostname;
            await InitAsync(cancellationToken).ConfigureAwait(false);
            var site = SiteFor(host.Split(':')[0]);
            if (site == null)
            {
                return false;
            }
            // A log reader sends when the page was served. Older than a week is dropped, so a first run over
            // an old log does not land as one spike on today; a time ahead of now counts as now.
            long now = Now();
            bool finite = at != null && double.IsFinite(at.Value);
            if (finite && at < now - 7 * 86_400_000L)
            {
                return false;
            }
            long ts = finite && at <= now ? (long)Math.Floor(at!.Value) : now;
            await Store.InsertEventAsync(new JsObject
            {
                ["site"] = Id(site),
                ["ts"] = ts,
                ["kind"] = "fetch",
                ["visitor"] = "",
                ["session"] = "",
                ["pageview"] = "",
                ["path"] = Js.Slice(url.Pathname, 0, 1000),
                ["hostname"] = Sources.StripWww(url.Hostname),
                ["title"] = "",
                ["name"] = agent.Get("name"),
                ["props"] = new JsObject { ["company"] = agent.Get("company"), ["kind"] = agent.Get("kind") },
                ["engagedMs"] = 0L,
                ["scroll"] = null,
                ["link"] = "",
            }, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            // Analytics must never break the page it watches, but a failure should still be seen.
            await Console.Error.WriteLineAsync("Runlight: could not record an AI agent fetch " + error.Message).ConfigureAwait(false);
            return false;
        }
    }

    // ---- short links

    /// <summary>
    /// The link domains, read at most every 30 seconds. Every request to a standalone server asks, so this
    /// saves a query on each tracker hit; a change made here clears it at once, one made by another process
    /// within half a minute.
    /// </summary>
    private async Task<HashSet<string>> LinkDomainSetAsync(CancellationToken cancellationToken)
    {
        long now = Now();
        var cache = _linkDomainCache;
        if (cache != null && now - cache.Value.At < 30_000)
        {
            return cache.Value.Domains;
        }
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var domains = new HashSet<string>(
            (await Store.LinkDomainsAsync(cancellationToken).ConfigureAwait(false)).Select(d => d.Str("domain")!),
            StringComparer.Ordinal);
        _linkDomainCache = (now, domains);
        return domains;
    }

    /// <summary>Clears the cached link domains after one is added or removed.</summary>
    public void ForgetLinkDomains() => _linkDomainCache = null;

    /// <summary>
    /// Handles <c>{linkPath}/{slug}</c> on the app's own domain: in an adapter, send requests under
    /// <see cref="LinkPath"/> to it.
    /// </summary>
    public RequestHandler LinkHandler() => async (request, ip, cancellationToken) =>
    {
        ArgumentNullException.ThrowIfNull(request);
        string path = new Url(request.Url).Pathname;
        string slug = path.StartsWith(LinkPath + "/", StringComparison.Ordinal) ? Decode(path[(LinkPath.Length + 1)..]) : "";
        var found = slug.Length > 0 && !slug.Contains('/', StringComparison.Ordinal) ? await RedirectAsync(request, slug, "", ip, cancellationToken).ConfigureAwait(false) : null;
        return found ?? NotFound();
    };

    /// <summary>
    /// For middleware: when a request arrives on a link domain added in Settings (such as t.example.com),
    /// answers <c>/{slug}</c> there with the redirect, and anything else with a 404. Null for every other host,
    /// so the app carries on as normal, and for the dashboard's own paths, so its owner can always reach it to
    /// remove the domain.
    /// </summary>
    public async Task<Response?> LinkDomainResponseAsync(Request request, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var url = new Url(request.Url);
        // A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
        string given = ForwardedHost(request) ?? request.Headers.Get("host") ?? url.Host;
        string host = Sources.StripWww(Js.Trim(given.Split(',')[0]).Split(':')[0]);
        if (!(await LinkDomainSetAsync(cancellationToken).ConfigureAwait(false)).Contains(host))
        {
            return null;
        }
        // Lets the dashboard confirm that requests to this domain reach Runlight.
        if (url.Pathname == LinkDomainCheck)
        {
            return new Response(Json.Stringify(new JsObject { ["runlight"] = true, ["domain"] = host }), 200, new Headers { ["content-type"] = "application/json", ["cache-control"] = "no-store" });
        }
        var bases = RouteBases;
        foreach (string b in bases.Count > 0 ? bases : ["/runlight"])
        {
            if (b != "/" && (url.Pathname == b || url.Pathname.StartsWith(b + "/", StringComparison.Ordinal)))
            {
                return null;
            }
        }
        string slug = Decode(url.Pathname[1..]);
        var found = slug.Length > 0 && !slug.Contains('/', StringComparison.Ordinal) ? await RedirectAsync(request, slug, host, ip, cancellationToken).ConfigureAwait(false) : null;
        return found ?? NotFound();
    }

    private static Response NotFound() => new("Not found", 404, new Headers { ["content-type"] = "text/plain; charset=utf-8" });

    /// <summary>decodeURIComponent, throwing where it throws a URIError.</summary>
    private static string Decode(string text) => Js.DecodeURIComponent(text) ?? throw new UriFormatException("URI malformed");

    /// <summary>
    /// Answers a request for a short link: a redirect to its destination, with the click recorded like a visit
    /// (source, place, device, and any campaign tags on the short URL) but kept out of visitor and pageview
    /// counts. Bots are redirected and not counted. <paramref name="domain"/> is the link domain the request
    /// came in on, or "" for the app's own link path, which answers for every link. Null when no link fits.
    /// </summary>
    public async Task<Response?> RedirectAsync(Request request, string slug, string domain, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var url = new Url(request.Url);
        string host = Sources.StripWww((ForwardedHost(request) ?? request.Headers.Get("host") ?? url.Host).Split(':')[0]);
        var link = await Store.LinkBySlugAsync(slug, cancellationToken).ConfigureAwait(false);
        // The app's own link path answers for every link, so a link whose domain
        // was removed keeps working; a link domain answers only for its own links.
        if (link == null || (domain.Length > 0 && link.Str("domain") != domain))
        {
            return null;
        }
        var site = Site(link.Str("site")) ?? Sites().FirstOrDefault();
        string ua = request.Headers.Get("user-agent") ?? "";
        if (site != null && Ua.AiAgent(ua) == null && !Ua.IsBot(ua) && request.Method == "GET")
        {
            try
            {
                long now = Now();
                string first = (request.Headers.Get("accept-language") ?? "").Split(',')[0].Split(';')[0];
                string language = Js.Slice(Js.Trim(first), 0, 35);
                var session = await SessionForAsync(site, request, ip, Sources.ParsePage(url), request.Headers.Get("referer") ?? "", now, null, "", language, cancellationToken).ConfigureAwait(false);
                await Store.TouchSessionAsync(session.Id, now, "click", url.Pathname, cancellationToken: cancellationToken).ConfigureAwait(false);
                await Store.InsertEventAsync(new JsObject
                {
                    ["site"] = Id(site),
                    ["ts"] = now,
                    ["kind"] = "click",
                    ["visitor"] = session.Visitor,
                    ["session"] = session.Id,
                    ["pageview"] = "",
                    ["path"] = Js.Slice(url.Pathname, 0, 1000),
                    ["hostname"] = host,
                    ["title"] = "",
                    ["name"] = link.Get("slug"),
                    ["props"] = null,
                    ["engagedMs"] = 0L,
                    ["scroll"] = null,
                    ["link"] = link.Get("id"),
                }, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                // A failed count must never break the redirect.
                await Console.Error.WriteLineAsync("Runlight: could not record a link click " + error.Message).ConfigureAwait(false);
            }
        }
        return new Response("", 302, new Headers { ["location"] = link.Str("url")!, ["cache-control"] = "no-store", ["referrer-policy"] = "no-referrer-when-downgrade" });
    }

    // ---- the scheduled check

    /// <summary>
    /// Scheduled upkeep, safe to run every minute. It rotates salts, sends the email reports that are due,
    /// deletes visits past each site's retention, and builds daily rollups. It also rereads sites, their
    /// dashboard settings, and connected installs, so a change made by another process sharing the database
    /// shows up here too. A check still running when the next is asked for is shared, never run twice at once;
    /// one asked for from inside a check does nothing more.
    /// </summary>
    /// <returns>{ ok: true, reports: { sent, failed } }.</returns>
    public Task<JsObject> CheckAsync(CancellationToken cancellationToken = default)
    {
        if (InCheck.Value)
        {
            return Task.FromResult(new JsObject { ["ok"] = true, ["reports"] = Counts(0, 0) });
        }
        Task<JsObject> checking;
        lock (_gate)
        {
            checking = _checking ??= SharedCheckAsync();
        }
        return checking.WaitAsync(cancellationToken);
    }

    private async Task<JsObject> SharedCheckAsync()
    {
        // Always finishes after the caller has recorded it, so the cleanup below never runs first.
        await Task.Yield();
        InCheck.Value = true;
        try
        {
            return await RunCheckAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                _checking = null;
            }
        }
    }

    private async Task<JsObject> RunCheckAsync(CancellationToken cancellationToken)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        // Requests take a current schema version on trust; the scheduled check goes over every table and index.
        await Store.MigrateAsync(true, cancellationToken).ConfigureAwait(false);
        if (ManagedSites)
        {
            var sites = await Store.SitesAsync(cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                _configured = sites;
            }
            await LoadRemotesAsync(cancellationToken).ConfigureAwait(false);
        }
        // A name or timezone changed in the dashboard by another process reaches this one too.
        _overrides = await Store.SiteOverridesAsync(cancellationToken).ConfigureAwait(false);
        _salts.Clear();
        foreach (string timezone in Sites().Select(Zone).Distinct(StringComparer.Ordinal))
        {
            await CurrentSaltsAsync(Now(), timezone, cancellationToken).ConfigureAwait(false);
        }
        await DropOldSaltsAsync(Now(), cancellationToken).ConfigureAwait(false);
        // Every site's retention covers any one site's that is still waiting.
        _pruning.Clear();
        try
        {
            await ApplyRetentionAsync(null, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            await Console.Error.WriteLineAsync("Runlight: could not apply retention " + error.Message).ConfigureAwait(false);
        }
        if (Now() - _optimizedAt >= 86_400_000)
        {
            _optimizedAt = Now();
            await Store.OptimizeAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        await BuildRollupsAsync(cancellationToken).ConfigureAwait(false);
        return new JsObject { ["ok"] = true, ["reports"] = await SendReportsAsync(cancellationToken).ConfigureAwait(false) };
    }

    // ---- helpers

    /// <summary>True for a database that could not take a statement just now and may a moment later.</summary>
    private static bool Busy(Exception error) => BusyMessage().IsMatch(error.Message);

    /// <summary>A key's value as TS reads <c>input.key ?? fallback</c>: null for a key that is absent, null, or undefined.</summary>
    private static object? Given(JsObject input, string key) => input.Get(key) is Undefined ? null : input.Get(key);

    /// <summary>JavaScript's ===, for the values JSON holds.</summary>
    private static bool Same(object? a, object? b)
    {
        if (a is string x && b is string y)
        {
            return x == y;
        }
        if (a is null || b is null)
        {
            return a is null && b is null;
        }
        if (a is Undefined || b is Undefined)
        {
            return a is Undefined && b is Undefined;
        }
        if (a is bool p && b is bool q)
        {
            return p == q;
        }
        if (a is string || b is string || a is bool || b is bool)
        {
            return false;
        }
        if (Json.TryNumberOf(a, out double m) && Json.TryNumberOf(b, out double n))
        {
            return m == n;
        }
        return ReferenceEquals(a, b);
    }

    private static Regex MakeEmail()
    {
        var spaces = new StringBuilder();
        for (int c = 0; c <= 0xffff; c++)
        {
            if (Js.IsSpace((char)c))
            {
                spaces.Append((char)c);
            }
        }
        string part = "[^" + spaces + "@<>\"]+";
        return new Regex("^" + part + "@" + part + "\\." + part + "\\z", RegexOptions.CultureInvariant);
    }

    [GeneratedRegex("^/+|/+\\z", RegexOptions.CultureInvariant)]
    private static partial Regex EdgeSlashes();

    [GeneratedRegex("/+\\z", RegexOptions.CultureInvariant)]
    private static partial Regex TrailingSlashes();

    [GeneratedRegex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex SiteId();

    [GeneratedRegex("^https?://", RegexOptions.CultureInvariant)]
    private static partial Regex Scheme();

    [GeneratedRegex("[/:][^\\n\\r\\u2028\\u2029]*\\z", RegexOptions.CultureInvariant)]
    private static partial Regex PathOrPort();

    [GeneratedRegex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\z", RegexOptions.CultureInvariant)]
    private static partial Regex Domain();

    [GeneratedRegex("^https://[^/]+|^http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?(/|\\z)", RegexOptions.CultureInvariant)]
    private static partial Regex InstallAddress();

    [GeneratedRegex("[^a-zA-Z0-9._-]", RegexOptions.CultureInvariant)]
    private static partial Regex NotIdChar();

    [GeneratedRegex("[^a-z0-9._-]", RegexOptions.CultureInvariant)]
    private static partial Regex NotLowerIdChar();

    [GeneratedRegex("\\.([a-zA-Z0-9]+)\\z", RegexOptions.CultureInvariant)]
    private static partial Regex Extension();

    [GeneratedRegex("timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked|connection pool has been exhausted|All pooled connections are in use", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex BusyMessage();
}
