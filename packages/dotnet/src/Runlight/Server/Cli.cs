using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Store;

namespace Runlight.Server;

/// <summary>
/// The commands behind the runlight tool, the .NET counterpart of <c>npx runlight.sh</c>'s: the server itself, the
/// scheduled check for a crontab, a new password for someone locked out, the tables, the setup link, and the access
/// log reader for AI agents.
/// </summary>
public static class Cli
{
    public const string Help = """
        Runlight {0}, privacy friendly web analytics for any number of sites.

        Usage:
          runlight serve                  Start the server
          runlight cron                   Run the scheduled check, and fetch this month's location data
          runlight password <email>       Make an account, or give one a new password
          runlight setup                  Print the link that makes the first account
          runlight migrate                Create or update Runlight's tables
          runlight agents --log <file>    Count AI agents from a web server's access log
          runlight --version              Print the version

        Add --config <file> to read settings from a config.json other than the
        working folder's. Settings are read from the environment first and then
        config.json: PORT, HOST, DATA_DIR, DATABASE_URL, RUNLIGHT_SECRET,
        RUNLIGHT_TOKEN, RUNLIGHT_URL, TRUST_PROXY, RUNLIGHT_GEO, CRON_SECRET, and
        RUNLIGHT_OBSERVE_KEY.

        The server runs the scheduled check every five minutes. To run it from
        cron as well, or for a server that is not always running:
          */5 * * * * cd /path/to/project && runlight cron

        Docs: https://runlight.sh/docs/dotnet/

        """;

    public const string AgentsHelp = """
        Count AI agents on a site that has only the script tag, from its web server's log.

        Usage:
          runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_...

          --log <file>    The access log, in nginx or Apache's combined format, or Caddy's JSON
          --to <url>      Your Runlight, as its dashboard address (or RUNLIGHT_URL)
          --key <key>     The site's key from Settings, Install, Key for CMS plugins (or RUNLIGHT_OBSERVE_KEY)
          --site <url>    The site's address, such as https://example.com, when the log has no host in it
          --follow        Keep running and send fetches as they happen
          --state <file>  Remember where it stopped, so the next run, or a restarted --follow, starts there.
                          Only one run at a time can use it.

        Docs: https://runlight.sh/docs/dotnet/#ai-agents-from-a-log

        """;

    /// <summary>Runs one command and returns the exit code.</summary>
    /// <param name="args">The arguments after the program's name.</param>
    /// <param name="root">The project folder, which holds config.json.</param>
    /// <param name="output">Where it prints; standard output by default.</param>
    /// <param name="error">Where it complains; standard error by default.</param>
    /// <param name="now">The clock, in epoch milliseconds.</param>
    /// <param name="fetcher">Reaches Runlight for the agents command; HttpClientFetcher by default.</param>
    /// <param name="openStore">Opens the store, as <see cref="Config"/> takes it.</param>
    /// <param name="serve">Runs the server, for <c>runlight serve</c>, until it is stopped; the runlight tool's is Kestrel.</param>
    public static async Task<int> RunAsync(
        IReadOnlyList<string> args,
        string root,
        TextWriter? output = null,
        TextWriter? error = null,
        Func<long>? now = null,
        IFetcher? fetcher = null,
        Func<string?, string, SqlStore>? openStore = null,
        Func<Config, Standalone, TextWriter, Task>? serve = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        output ??= Console.Out;
        error ??= Console.Error;
        now ??= () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var rest = args.ToList();
        string? file = null;
        int at = rest.IndexOf("--config");
        if (at >= 0)
        {
            file = at + 1 < rest.Count ? rest[at + 1] : null;
            if (file == null)
            {
                await error.WriteAsync("Runlight: name the file after --config.\n").ConfigureAwait(false);
                return 1;
            }
            rest.RemoveRange(at, 2);
            file = File.Exists(file) ? Path.GetFullPath(file) : file;
        }
        string command = rest.Count > 0 ? rest[0] : "help";
        Config? config = null;
        Config Settings() => config ??= new Config(root, file, openStore);
        try
        {
            switch (command)
            {
                case "help":
                case "--help":
                case "-h":
                    await output.WriteAsync(string.Format(CultureInfo.InvariantCulture, Help, Version.Current)).ConfigureAwait(false);
                    return 0;
                case "--version":
                case "-v":
                    await output.WriteAsync(Version.Current + "\n").ConfigureAwait(false);
                    return 0;
                case "serve":
                    return await ServeAsync(Settings(), output, now, serve).ConfigureAwait(false);
                case "cron":
                    return await CronAsync(Settings(), error, now).ConfigureAwait(false);
                case "password":
                    return await PasswordAsync(Settings(), rest.Count > 1 ? rest[1] : null, output, error, now).ConfigureAwait(false);
                case "setup":
                    return await SetupAsync(Settings(), output).ConfigureAwait(false);
                case "agents":
                    return await AgentsAsync(rest.Skip(1).ToList(), Settings, output, error, now, fetcher).ConfigureAwait(false);
                case "migrate":
                    {
                        var rl = Settings().Standalone(now, setup: false).Runlight;
                        await rl.InitAsync().ConfigureAwait(false);
                        await rl.Store.MigrateAsync(true).ConfigureAwait(false);
                        await output.WriteAsync("Runlight's tables are up to date in " + Settings().Where() + ".\n").ConfigureAwait(false);
                        return 0;
                    }
                default:
                    await error.WriteAsync("Runlight: unknown command \"" + command + "\". Run runlight --help.\n").ConfigureAwait(false);
                    return 1;
            }
        }
        catch (Exception e)
        {
            await error.WriteAsync("Runlight: " + e.Message + "\n").ConfigureAwait(false);
            return 1;
        }
        finally
        {
            if (config != null)
            {
                await config.CloseAsync().ConfigureAwait(false);
            }
        }
    }

    /// <summary>
    /// The server, until it is stopped: the setup link said once while there is no account, and the scheduled check
    /// every five minutes.
    /// </summary>
    private static async Task<int> ServeAsync(Config config, TextWriter output, Func<long> now, Func<Config, Standalone, TextWriter, Task>? serve)
    {
        if (serve == null)
        {
            throw new InvalidOperationException("the server runs from the runlight tool (dotnet tool install --global Runlight.Server)");
        }
        var server = config.Standalone(now);
        await server.Runlight.InitAsync().ConfigureAwait(false);
        server.Schedule(config);
        try
        {
            await serve(config, server, output).ConfigureAwait(false);
        }
        finally
        {
            await server.StopAsync().ConfigureAwait(false);
        }
        return 0;
    }

    /// <summary>
    /// What the server says once it is listening: where, where the data is, and how to make the first account while
    /// there is none.
    /// </summary>
    public static async Task AnnounceAsync(Config config, Standalone server, string shown, TextWriter output)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(server);
        ArgumentNullException.ThrowIfNull(output);
        await output.WriteAsync("Runlight " + Version.Current + " is listening on " + shown + "\n").ConfigureAwait(false);
        await output.WriteAsync("Data: " + config.Where() + "\n").ConfigureAwait(false);
        if (await server.Accounts.CountAsync().ConfigureAwait(false) == 0)
        {
            string? code = config.SetupCode();
            await output.WriteAsync(code == null
                ? "\nNo account yet. Open " + shown + "/setup and enter RUNLIGHT_TOKEN to create the first one.\n\n"
                : "\nNo account yet. Open this link to create the first one:\n  " + shown + "/setup?code=" + code + "\n\n").ConfigureAwait(false);
        }
        await output.FlushAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// The scheduled check (salts, email reports, retention, and rollups), then this month's location data. Quiet
    /// when all is well, as cron likes. A run that starts while another is still going leaves it to that one.
    /// </summary>
    private static async Task<int> CronAsync(Config config, TextWriter error, Func<long> now)
    {
        using var held = Config.TryLock(config.DataDir() + "/cron.lock");
        if (held == null)
        {
            return 0;
        }
        var server = config.Standalone(now, setup: false);
        var result = await server.CheckAsync().ConfigureAwait(false);
        // The setup link is no use once someone has an account.
        if (File.Exists(config.SetupFile()) && await server.Accounts.CountAsync().ConfigureAwait(false) > 0)
        {
            File.Delete(config.SetupFile());
        }
        long failed = result.Obj("reports")?.Long("failed") ?? 0;
        if (failed > 0)
        {
            await error.WriteAsync("Runlight: " + Js.Str(failed) + " email " + (failed == 1 ? "report" : "reports") + " could not be sent. The dashboard's Settings, Email reports, says why.\n").ConfigureAwait(false);
        }
        var dbIp = config.DbIp();
        if (dbIp != null)
        {
            await dbIp.RefreshAsync(now()).ConfigureAwait(false);
        }
        return failed > 0 ? 1 : 0;
    }

    /// <summary>
    /// A new password for someone locked out, which also turns off their two-factor sign-in, since someone at the
    /// server is who they say. It makes the account when there is none: the owner on a server with nobody yet, and
    /// an admin otherwise.
    /// </summary>
    private static async Task<int> PasswordAsync(Config config, string? email, TextWriter output, TextWriter error, Func<long> now)
    {
        if (email == null || Js.Trim(email).Length == 0)
        {
            await error.WriteAsync("Runlight: name the account, as in runlight password you@example.com\n").ConfigureAwait(false);
            return 1;
        }
        var server = config.Standalone(now, setup: false);
        await server.Runlight.InitAsync().ConfigureAwait(false);
        string password = Crypto.Base64url(Crypto.RandomBytes(12));
        bool existed = await server.Accounts.ByEmailAsync(email).ConfigureAwait(false) != null;
        var user = await server.Accounts.SetPasswordAsync(email, password, now()).ConfigureAwait(false);
        bool reset = user.Bool("twoFactor");
        if (reset)
        {
            await server.Accounts.DisableTwoFactorAsync(user.Str("id")!).ConfigureAwait(false);
        }
        string who = Js.Lower(Js.Trim(email));
        await output.WriteAsync((existed ? "New password" : "Account made, as " + (user.Str("role") == "owner" ? "the owner" : "an admin") + ",") + " for " + who + ": " + password + "\n"
            + (reset ? "Two-factor sign-in is now off for this account; turn it on again under Account.\n" : "")
            + "Sign in, and change it by running this again whenever you like.\n").ConfigureAwait(false);
        return 0;
    }

    /// <summary>
    /// Reads a web server's access log and sends the AI agent fetches in it to a Runlight, as <c>npx runlight.sh
    /// agents</c> does. --to and --key default to RUNLIGHT_URL and RUNLIGHT_OBSERVE_KEY, from the environment or
    /// config.json. With --follow it runs until it is stopped, and a stop by SIGINT or SIGTERM releases the state
    /// file's lock on the way out.
    /// </summary>
    private static async Task<int> AgentsAsync(List<string> args, Func<Config> settings, TextWriter output, TextWriter error, Func<long> now, IFetcher? fetcher)
    {
        string? Flag(string name)
        {
            int at = args.IndexOf("--" + name);
            return at >= 0 && at + 1 < args.Count ? args[at + 1] : null;
        }
        if (args.Contains("--help") || args.Contains("-h"))
        {
            await output.WriteAsync(AgentsHelp).ConfigureAwait(false);
            return 0;
        }
        string? log = Flag("log");
        string? to = Flag("to");
        string? key = Flag("key");
        if (to == null || key == null)
        {
            var config = settings();
            to ??= config.Get("RUNLIGHT_URL");
            key ??= config.Get("RUNLIGHT_OBSERVE_KEY");
        }
        if (string.IsNullOrEmpty(log) || string.IsNullOrEmpty(to) || string.IsNullOrEmpty(key))
        {
            await error.WriteAsync(AgentsHelp).ConfigureAwait(false);
            return 1;
        }
        bool follow = args.Contains("--follow");
        bool stopped = false;
        var signals = new List<IDisposable>();
        ConsoleCancelEventHandler? cancel = null;
        if (follow)
        {
            cancel = (_, e) =>
            {
                e.Cancel = true;
                stopped = true;
            };
            Console.CancelKeyPress += cancel;
            if (!OperatingSystem.IsWindows())
            {
                signals.Add(PosixSignalRegistration.Create(PosixSignal.SIGTERM, context =>
                {
                    context.Cancel = true;
                    stopped = true;
                }));
            }
        }
        string? site = Flag("site");
        string? state = Flag("state");
        try
        {
            await Agents.RunAsync(new AgentsOptions
            {
                Log = Path.GetFullPath(log),
                To = to,
                Key = key,
                Follow = follow,
                Out = line => output.Write(line + "\n"),
                Stop = () => stopped,
                Now = now,
                Site = string.IsNullOrEmpty(site) ? null : site,
                State = string.IsNullOrEmpty(state) ? null : Path.GetFullPath(state),
                Fetcher = fetcher,
            }).ConfigureAwait(false);
        }
        finally
        {
            if (cancel != null)
            {
                Console.CancelKeyPress -= cancel;
            }
            foreach (var signal in signals)
            {
                signal.Dispose();
            }
        }
        return 0;
    }

    private static async Task<int> SetupAsync(Config config, TextWriter output)
    {
        var server = config.Standalone(setup: false);
        await server.Runlight.InitAsync().ConfigureAwait(false);
        if (await server.Accounts.CountAsync().ConfigureAwait(false) > 0)
        {
            await output.WriteAsync("Runlight already has an account. To get into one, run runlight password <email>.\n").ConfigureAwait(false);
            return 0;
        }
        if (config.Get("RUNLIGHT_TOKEN") != null)
        {
            await output.WriteAsync("Open /setup at your Runlight's address and enter RUNLIGHT_TOKEN to create the first account.\n").ConfigureAwait(false);
            return 0;
        }
        config.SetupCode();
        await output.WriteAsync(await File.ReadAllTextAsync(config.SetupFile()).ConfigureAwait(false)).ConfigureAwait(false);
        if (config.Url() == null)
        {
            await output.WriteAsync("Put your Runlight's own address in place of https://your-runlight-address, or set RUNLIGHT_URL.\n").ConfigureAwait(false);
        }
        return 0;
    }
}
