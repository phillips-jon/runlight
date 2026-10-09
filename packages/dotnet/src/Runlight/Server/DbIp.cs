using System;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Server;

/// <summary>
/// Location for servers with no platform headers (Cloudflare, Vercel, and Netlify send their own, and those always
/// win), from DB-IP's free databases (CC BY 4.0, https://db-ip.com). This is the port of the Geo class in
/// packages/server/src/geo.ts: <c>runlight cron</c> and the server's own schedule download each month's release
/// with <see cref="RefreshAsync"/>, and lookups read the newest file on disk. <see cref="Lookup"/> opens it at the
/// first lookup, as each PHP request does; a server that keeps running reads through <see cref="Current"/>
/// instead, which <see cref="LoadNewest"/> points at the newest release whenever the schedule runs, as the Node
/// server's Geo does.
/// </summary>
public sealed class DbIp
{
    private readonly string _dir;
    private readonly string _mode;
    private readonly Func<string, string, CancellationToken, Task<bool>> _download;
    private readonly Action<string> _log;
    private readonly Lock _lock = new();
    private string? _loaded;
    private Func<string, JsObject?>? _lookup;

    /// <param name="dir">The folder the releases live in.</param>
    /// <param name="mode">"city" or "country".</param>
    /// <param name="download">
    /// Writes the gzipped file at the URL to the file, and says whether it got one; a plain HTTPS download by
    /// default.
    /// </param>
    /// <param name="log">Where it says what it did; standard error by default.</param>
    public DbIp(string dir, string mode, Func<string, string, CancellationToken, Task<bool>>? download = null, Action<string>? log = null)
    {
        _dir = dir;
        _mode = mode;
        _download = download ?? DownloadAsync;
        _log = log ?? (line => Console.Error.WriteLine(line));
    }

    /// <summary>"2026-10", the month DB-IP names each release after.</summary>
    public static string Month(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM", CultureInfo.InvariantCulture);

    private string File(string release) => _dir + "/dbip-" + _mode + "-lite-" + release + ".mmdb";

    /// <summary>The newest release on disk, or null before the first download.</summary>
    public string? Newest()
    {
        if (!Directory.Exists(_dir))
        {
            return null;
        }
        string prefix = "dbip-" + _mode + "-lite-";
        return Directory.GetFiles(_dir)
            .Where(f => Path.GetFileName(f).StartsWith(prefix, StringComparison.Ordinal) && f.EndsWith(".mmdb", StringComparison.Ordinal))
            .Select(f => _dir + "/" + Path.GetFileName(f))
            .Order(StringComparer.Ordinal)
            .LastOrDefault();
    }

    /// <summary>
    /// A lookup answering from the newest release on disk, opened at the first lookup, or null when there is none
    /// yet. Lookups that fail answer nothing, as they do before the first download in TypeScript.
    /// </summary>
    public Func<string, JsObject?>? Lookup()
    {
        string? file = Newest();
        if (file == null)
        {
            return null;
        }
        Func<string, JsObject?>? found = null;
        return ip =>
        {
            try
            {
                found ??= Geo.LookupFrom(Mmdb.Open(file));
            }
            catch (Exception)
            {
                return null;
            }
            return found(ip);
        };
    }

    /// <summary>A lookup that always answers, from the release <see cref="LoadNewest"/> last opened, and with nothing before there is one.</summary>
    public Func<string, JsObject?> Current() => ip => _lookup?.Invoke(ip);

    /// <summary>
    /// Opens the newest release on disk when it is not the one open already. Safe to call often: it reads only the
    /// folder when nothing changed.
    /// </summary>
    public DbIp LoadNewest()
    {
        string? file = Newest();
        if (file == null || file == _loaded)
        {
            return this;
        }
        lock (_lock)
        {
            if (file != _loaded)
            {
                try
                {
                    _lookup = Geo.LookupFrom(Mmdb.Open(file));
                    _loaded = file;
                }
                catch (Exception error)
                {
                    _log("Runlight: could not open location data in " + file + ": " + error.Message);
                }
            }
        }
        return this;
    }

    /// <summary>
    /// Fetches this month's release when it is missing. A new month's file appears a day or so after the month
    /// starts, so until then last month's is fetched when that is missing too. Older releases go once a new one is
    /// ready. Safe to call often: once this month's file is there it reads only the folder.
    /// </summary>
    public async Task RefreshAsync(long now, CancellationToken cancellationToken = default)
    {
        string current = Month(now);
        if (System.IO.File.Exists(File(current)))
        {
            return;
        }
        try
        {
            Directory.CreateDirectory(_dir);
        }
        catch (Exception)
        {
            _log("Runlight: could not make the folder for location data, " + _dir);
            return;
        }
        DateTime at = DateTimeOffset.FromUnixTimeMilliseconds(now).UtcDateTime;
        string previous = Month(new DateTimeOffset(at.Year, at.Month, 15, 0, 0, 0, TimeSpan.Zero).AddMonths(-1).ToUnixTimeMilliseconds());
        foreach (string release in new[] { current, previous })
        {
            if (System.IO.File.Exists(File(release)))
            {
                return;
            }
            string url = "https://download.db-ip.com/free/dbip-" + _mode + "-lite-" + release + ".mmdb.gz";
            string gz = File(release) + ".gz.partial";
            string partial = File(release) + ".partial";
            try
            {
                if (!await _download(url, gz, cancellationToken).ConfigureAwait(false))
                {
                    continue;
                }
                await GunzipAsync(gz, partial, cancellationToken).ConfigureAwait(false);
                // A file that does not open as a database is never kept.
                Mmdb.Open(partial).Dispose();
                System.IO.File.Move(partial, File(release), true);
                string prefix = "dbip-" + _mode + "-lite-";
                foreach (string old in Directory.GetFiles(_dir).Where(f => Path.GetFileName(f).StartsWith(prefix, StringComparison.Ordinal)))
                {
                    if (Path.GetFileName(old) != Path.GetFileName(File(release)))
                    {
                        try
                        {
                            System.IO.File.Delete(old);
                        }
                        catch (IOException)
                        {
                        }
                    }
                }
                _log("Runlight: location data from DB-IP (" + release + ") is ready.");
                return;
            }
            catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                _log("Runlight: could not download location data from " + url + ": " + error.Message);
            }
            finally
            {
                Remove(gz);
                Remove(partial);
            }
        }
    }

    private static void Remove(string file)
    {
        try
        {
            System.IO.File.Delete(file);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static async Task GunzipAsync(string from, string to, CancellationToken cancellationToken)
    {
        try
        {
            var input = System.IO.File.OpenRead(from);
            await using (input.ConfigureAwait(false))
            {
                var gzip = new GZipStream(input, CompressionMode.Decompress);
                await using (gzip.ConfigureAwait(false))
                {
                    var output = System.IO.File.Create(to);
                    await using (output.ConfigureAwait(false))
                    {
                        await gzip.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
                    }
                }
            }
        }
        catch (InvalidDataException)
        {
            throw new IOException("could not unpack " + from);
        }
    }

    /// <summary>
    /// Downloads a file straight to disk, since a city database is too big to hold in memory. This is the one
    /// download that does not go through a fetcher, which keeps whole answers in memory. Redirects are followed on
    /// https only.
    /// </summary>
    private static async Task<bool> DownloadAsync(string url, string file, CancellationToken cancellationToken)
    {
        using var handler = new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(15) };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(10) };
        var uri = new Uri(url);
        for (int redirects = 0; redirects <= 5; redirects++)
        {
            if (uri.Scheme != "https")
            {
                throw new HttpRequestException("not https: " + uri);
            }
            using var answer = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if ((int)answer.StatusCode is >= 300 and < 400 && answer.Headers.Location != null)
            {
                uri = new Uri(uri, answer.Headers.Location);
                continue;
            }
            if (answer.StatusCode != HttpStatusCode.OK)
            {
                return false;
            }
            var output = System.IO.File.Create(file);
            await using (output.ConfigureAwait(false))
            {
                await answer.Content.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
            }
            return true;
        }
        return false;
    }
}
