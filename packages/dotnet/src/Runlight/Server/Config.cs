using System;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using Runlight.Accounts;
using Runlight.Http;
using Runlight.Store;

namespace Runlight.Server;

/// <summary>
/// The standalone server's settings, as <c>runlight serve</c> and the other commands read them: environment
/// variables first, then a config.json in the project folder (the folder the command runs in) holding the same
/// names.
/// <code>
///   PORT                  where runlight serve listens (3000)
///   HOST                  which address it listens on (0.0.0.0)
///   DATA_DIR              the SQLite file, the secret, the setup code, and location data (./runlight-data)
///   DATABASE_URL          a postgres://, mysql://, or mariadb:// URL, to use that database instead of SQLite
///   RUNLIGHT_SECRET       signs sessions and encrypts saved keys (made and kept in DATA_DIR if unset)
///   RUNLIGHT_TOKEN        also accepted as a bearer token on the API, and makes the first account
///   RUNLIGHT_URL          the dashboard's public address, which can never become a link domain
///   TRUST_PROXY           "false" when no proxy sits in front, so forwarded addresses are ignored
///   RUNLIGHT_GEO          city (the default), country, off, or the path to an MMDB file
///   CRON_SECRET           lets a scheduler run the check over HTTP, at POST /api/check
///   RUNLIGHT_OBSERVE_KEY  one key for every site's AI agent reports
/// </code>
/// Relative paths are read from the project folder. The Runlight package has no database driver of its own, so
/// the store is opened by the function the program passes, which the runlight tool does with Microsoft.Data.Sqlite,
/// Npgsql, and MySqlConnector.
/// </summary>
public sealed partial class Config
{
    private readonly JsObject _file = new();
    private readonly Func<string?, string, SqlStore>? _openStore;
    private readonly Lock _lock = new();
    private string? _secret;
    private SqlStore? _store;
    private DbIp? _dbIp;
    private bool _dbIpMade;

    [GeneratedRegex("^(/|\\\\|[A-Za-z]:[\\\\/])", RegexOptions.CultureInvariant)]
    private static partial Regex Absolute();

    [GeneratedRegex("/setup\\?code=([A-Za-z0-9_-]+)", RegexOptions.CultureInvariant)]
    private static partial Regex SetupLink();

    [GeneratedRegex("^https?://[^/?#]+/?\\z", RegexOptions.CultureInvariant)]
    private static partial Regex OriginOnly();

    /// <param name="root">The project folder, which holds config.json.</param>
    /// <param name="file">A config.json elsewhere; RUNLIGHT_CONFIG names one too.</param>
    /// <param name="openStore">
    /// Opens the store: given DATABASE_URL, or null and the SQLite file's path when it is unset.
    /// </param>
    public Config(string root, string? file = null, Func<string?, string, SqlStore>? openStore = null)
    {
        ArgumentNullException.ThrowIfNull(root);
        Root = root;
        _openStore = openStore;
        file ??= Env.Get("RUNLIGHT_CONFIG");
        string defaultFile = root + "/config.json";
        file = file != null ? PathOf(file) : defaultFile;
        if (File.Exists(file))
        {
            object? values;
            try
            {
                values = Json.Parse(File.ReadAllText(file));
            }
            catch (JsonParseException error)
            {
                throw new InvalidOperationException("Runlight: " + file + " is not JSON: " + error.Message, error);
            }
            _file = values as JsObject
                ?? throw new InvalidOperationException("Runlight: " + file + " must hold an object of settings, such as {\"RUNLIGHT_URL\": \"https://stats.example.com\"}");
        }
        else if (file != defaultFile)
        {
            throw new InvalidOperationException("Runlight: there is no config file at " + file);
        }
    }

    /// <summary>The project folder.</summary>
    public string Root { get; }

    /// <summary>A setting: the environment's, else config.json's, trimmed, with nothing for an empty one.</summary>
    public string? Get(string name)
    {
        string? value = Env.Get(name);
        if (value != null)
        {
            return value;
        }
        object? given = _file.Get(name);
        if (given is bool b)
        {
            return b ? "true" : "false";
        }
        if (given is not (string or double or long))
        {
            return null;
        }
        string text = Js.Trim(Js.String(given));
        return text.Length == 0 ? null : text;
    }

    /// <summary>A path from a setting, read from the project folder when it is relative.</summary>
    public string PathOf(string value) => Absolute().IsMatch(value) ? value : Root + "/" + value;

    /// <summary>The data folder, made on first use and readable only by this user.</summary>
    public string DataDir()
    {
        string dir = DataPath();
        if (!Directory.Exists(dir))
        {
            try
            {
                if (OperatingSystem.IsWindows())
                {
                    Directory.CreateDirectory(dir);
                }
                else
                {
                    Directory.CreateDirectory(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
            if (!Directory.Exists(dir))
            {
                throw new InvalidOperationException("Runlight: could not make the data folder " + dir + ". Make it, writable by the server, or set DATA_DIR.");
            }
        }
        return dir;
    }

    private string DataPath() => PathOf(Get("DATA_DIR") ?? "runlight-data");

    /// <summary>Where the data lives, for messages.</summary>
    public string Where()
    {
        string url = Get("DATABASE_URL") ?? "";
        if (Regex.IsMatch(url, "^postgres(ql)?://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            return "Postgres";
        }
        if (Regex.IsMatch(url, "^mysql://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            return "MySQL";
        }
        if (Regex.IsMatch(url, "^mariadb://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            return "MariaDB";
        }
        return url.Length > 0 ? url : DataPath() + "/runlight.db";
    }

    /// <summary>The store, opened once: DATABASE_URL's database, or the SQLite file in the data folder.</summary>
    public SqlStore Store()
    {
        lock (_lock)
        {
            if (_store == null)
            {
                var open = _openStore ?? throw new InvalidOperationException("Runlight: no database driver to open the store with; run the runlight tool, or pass one to Config");
                string? url = Get("DATABASE_URL");
                _store = url != null ? open(url, "") : open(null, DataDir() + "/runlight.db");
            }
            return _store;
        }
    }

    /// <summary>Closes the store, when one was opened.</summary>
    public async System.Threading.Tasks.Task CloseAsync()
    {
        SqlStore? store;
        lock (_lock)
        {
            store = _store;
            _store = null;
        }
        if (store != null)
        {
            await store.CloseAsync().ConfigureAwait(false);
        }
    }

    /// <summary>RUNLIGHT_SECRET, or one made on first use and kept beside the data, readable only by this user.</summary>
    public string Secret()
    {
        if (_secret != null)
        {
            return _secret;
        }
        string? given = Get("RUNLIGHT_SECRET");
        if (given != null)
        {
            return _secret = given;
        }
        string file = DataDir() + "/secret";
        string saved = ReadTrimmed(file);
        if (saved.Length > 0)
        {
            return _secret = saved;
        }
        string made = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        // Made once: whoever writes the file first wins, and everyone else reads theirs.
        if (!WriteNew(file, made + "\n"))
        {
            Thread.Sleep(50);
            saved = ReadTrimmed(file);
            if (saved.Length == 0)
            {
                throw new InvalidOperationException("Runlight: could not write " + file + ". Make the data folder writable, or set RUNLIGHT_SECRET.");
            }
            return _secret = saved;
        }
        return _secret = made;
    }

    /// <summary>The dashboard's public address, such as https://stats.example.com, or null.</summary>
    public string? Url()
    {
        string? url = Get("RUNLIGHT_URL");
        if (url != null && !OriginOnly().IsMatch(url))
        {
            throw new InvalidOperationException("Runlight: set RUNLIGHT_URL to the dashboard's address only, such as https://stats.example.com");
        }
        return url;
    }

    /// <summary>
    /// "false" with nothing in front, or the one header your proxy sets, such as cf-connecting-ip behind Cloudflare.
    /// Null when unset, so the library's default applies and it can warn when nothing sits in front.
    /// </summary>
    public ProxyTrust? TrustProxy()
    {
        string value = Js.Lower(Get("TRUST_PROXY") ?? "");
        if (value.Length == 0)
        {
            return null;
        }
        if (value == "false")
        {
            return ProxyTrust.FromBoolean(false);
        }
        return value is "x-forwarded-for" or "x-real-ip" or "cf-connecting-ip" ? ProxyTrust.FromString(value) : ProxyTrust.FromBoolean(true);
    }

    /// <summary>
    /// DB-IP's monthly download, for RUNLIGHT_GEO city (the default) or country, or null. The same one each time, so
    /// a running server's lookups see what its schedule downloads.
    /// </summary>
    public DbIp? DbIp()
    {
        lock (_lock)
        {
            if (!_dbIpMade)
            {
                string mode = Js.Lower(Get("RUNLIGHT_GEO") ?? "city");
                _dbIp = mode is "city" or "country" ? new DbIp(DataPath() + "/geo", mode) : null;
                _dbIpMade = true;
            }
            return _dbIp;
        }
    }

    /// <summary>The location lookup: DB-IP's newest release, an MMDB file of the owner's, or null when it is off.</summary>
    public Func<string, JsObject?>? Geo()
    {
        string setting = Get("RUNLIGHT_GEO") ?? "city";
        var dbIp = DbIp();
        if (dbIp != null)
        {
            return dbIp.LoadNewest().Current();
        }
        if (Js.Lower(setting) == "off")
        {
            return null;
        }
        string file = PathOf(setting);
        Func<string, JsObject?>? lookup = null;
        return ip =>
        {
            lookup ??= global::Runlight.Geo.FileLookup(file);
            return lookup(ip);
        };
    }

    /// <summary>The file that holds the setup link while there is no account.</summary>
    public string SetupFile() => DataDir() + "/setup.txt";

    /// <summary>
    /// The one-time code that unlocks /setup, made the first time it is asked for and written to setup.txt in the
    /// data folder with the link that carries it. With RUNLIGHT_TOKEN set there is none: setup asks for the token.
    /// </summary>
    public string? SetupCode()
    {
        if (Get("RUNLIGHT_TOKEN") != null)
        {
            return null;
        }
        string file = SetupFile();
        var found = SetupLink().Match(File.Exists(file) ? File.ReadAllText(file) : "");
        if (found.Success)
        {
            return found.Groups[1].Value;
        }
        string code = Web.SetupCode();
        string? url = Url();
        string link = (url != null ? url.TrimEnd('/') : "https://your-runlight-address") + "/setup?code=" + code;
        if (!WriteNew(file, "Open this link to create the first Runlight account. It works only while Runlight has no account.\n" + link + "\n"))
        {
            // Someone else wrote it first.
            Thread.Sleep(50);
            found = SetupLink().Match(File.Exists(file) ? File.ReadAllText(file) : "");
            if (found.Success)
            {
                return found.Groups[1].Value;
            }
            throw new InvalidOperationException("Runlight: could not write " + file + ". Make the data folder writable, or set RUNLIGHT_TOKEN.");
        }
        return code;
    }

    /// <summary>The standalone server these settings describe.</summary>
    /// <param name="now">The clock, for tests.</param>
    /// <param name="fetcher">Every outgoing request, for tests.</param>
    /// <param name="setup">Whether to make the setup code when there is none, as the web pages need.</param>
    public Standalone Standalone(Func<long>? now = null, IFetcher? fetcher = null, bool setup = true)
    {
        var dbIp = DbIp();
        var geo = Geo();
        string? code = setup ? SetupCode() : null;
        return new Standalone(new StandaloneOptions
        {
            Store = Store(),
            Secret = Secret(),
            Token = Get("RUNLIGHT_TOKEN"),
            Url = Url(),
            TrustProxy = TrustProxy(),
            GeoCredit = dbIp != null,
            CronSecret = Get("CRON_SECRET"),
            ObserveKey = Get("RUNLIGHT_OBSERVE_KEY"),
            Geo = geo,
            SetupCode = code,
            SetupWhere = code != null ? "in the file setup.txt in Runlight's data folder (<code>runlight setup</code> prints it too)" : null,
            Now = now,
            Fetcher = fetcher,
        });
    }

    /// <summary>A file's text, trimmed, or "" when there is none.</summary>
    private static string ReadTrimmed(string file)
    {
        try
        {
            return File.Exists(file) ? Js.Trim(File.ReadAllText(file)) : "";
        }
        catch (IOException)
        {
            return "";
        }
    }

    /// <summary>Writes a file that is not there yet, readable only by this user; false when it is there already.</summary>
    internal static bool WriteNew(string file, string text)
    {
        FileStream stream;
        try
        {
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows())
            {
                options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            }
            stream = new FileStream(file, options);
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        using (stream)
        {
            stream.Write(Js.Utf8(text));
        }
        return true;
    }

    /// <summary>
    /// Takes the lock in a file without waiting, as flock(LOCK_EX | LOCK_NB) does, or null when another process
    /// holds it. Disposing releases it.
    /// </summary>
    public static IDisposable? TryLock(string file)
    {
        try
        {
            return new FileStream(file, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            // A lock file that cannot be made locks nothing, as a failed fopen leaves the run to go ahead.
            return new MemoryStream();
        }
    }
}
