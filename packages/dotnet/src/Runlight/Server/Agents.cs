using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using ImportHttp = Runlight.Importers.Http;

namespace Runlight.Server;

/// <summary>What <see cref="Agents.RunAsync"/> takes, as the Node command's options.</summary>
public sealed class AgentsOptions
{
    /// <summary>The access log's path.</summary>
    public required string Log { get; init; }

    /// <summary>The Runlight to report to, as its dashboard address.</summary>
    public required string To { get; init; }

    /// <summary>The site's observe key.</summary>
    public required string Key { get; init; }

    /// <summary>The site's address, for logs with no host in them.</summary>
    public string? Site { get; init; }

    /// <summary>Keep reading as the log grows.</summary>
    public bool Follow { get; init; }

    /// <summary>Where runs remember how far they read, so the next one (or a restarted follow) carries on.</summary>
    public string? State { get; init; }

    /// <summary>What it has to say, a line at a time; printed by default.</summary>
    public Action<string>? Out { get; init; }

    /// <summary>Ends follow, which otherwise runs until the process stops.</summary>
    public Func<bool>? Stop { get; init; }

    /// <summary>How often follow looks at the log, 2 seconds by default.</summary>
    public int PollMs { get; init; } = 2000;

    /// <summary>Waits between looks; Task.Delay by default.</summary>
    public Func<int, Task>? Sleep { get; init; }

    /// <summary>Reaches Runlight; HttpClientFetcher by default.</summary>
    public IFetcher? Fetcher { get; init; }

    /// <summary>Epoch milliseconds, for lines whose time cannot be read.</summary>
    public Func<long>? Now { get; init; }
}

/// <summary>
/// <c>runlight agents</c>: counts AI agents on a site that has only the script tag, by reading its web server's
/// access log. Agents do not run JavaScript, so the tracker never sees them; the server that answered them did.
///
/// It reads nginx and Apache's combined format and Caddy's JSON lines, keeps successful GETs from known AI agents,
/// and sends them in batches to a Runlight's /api/observe with the site's observe key. Nothing else in the log
/// leaves the machine. With follow it keeps reading as the log grows and carries on after the log is rotated.
/// Without it, it reads what is new and stops, for cron. In both modes the state file remembers how far it read,
/// so the next run, or a restarted follow, carries on from there.
///
/// The port of the Node server's agents.ts, by way of the PHP package's. A fetch is an object of url, userAgent,
/// and at (epoch milliseconds).
/// </summary>
public static partial class Agents
{
    private static readonly Dictionary<string, int> Months = new(StringComparer.Ordinal)
    {
        ["Jan"] = 0,
        ["Feb"] = 1,
        ["Mar"] = 2,
        ["Apr"] = 3,
        ["May"] = 4,
        ["Jun"] = 5,
        ["Jul"] = 6,
        ["Aug"] = 7,
        ["Sep"] = 8,
        ["Oct"] = 9,
        ["Nov"] = 10,
        ["Dec"] = 11,
    };

    /// <summary>JavaScript's \S, which also leaves out Unicode spaces.</summary>
    private const string S = "[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]";

    /// <summary>A quoted field's inside: anything but a quote or a backslash, or a backslash and the next character on the line.</summary>
    private const string Quoted = "(?:[^\"\\\\]|\\\\[^\\n\\r\\u2028\\u2029])*";

    // host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
    private static readonly Regex Combined = new(
        "^(?:(" + S + "+) )?" + S + "+ " + S + "+ " + S + "+ \\[([^\\]]+)\\] \"(" + S + "+) (" + S + "+)[^\"]*\" ([0-9]{3}) " + S + "+ \"" + Quoted + "\" \"(" + Quoted + ")\"",
        RegexOptions.CultureInvariant);

    /// <summary>A request line and status, in a line that might be a combined log line without its host.</summary>
    private static readonly Regex RequestLine = new("\"" + S + "+ /" + S + "* [^\"]*\" [0-9]{3}", RegexOptions.CultureInvariant);

    [GeneratedRegex("^([0-9]{2})/([A-Za-z0-9_]{3})/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})\\z", RegexOptions.CultureInvariant)]
    private static partial Regex LogTimeText();

    [GeneratedRegex("[a-z]", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Letter();

    [GeneratedRegex("^[0-9.:]+\\z", RegexOptions.CultureInvariant)]
    private static partial Regex Address();

    [GeneratedRegex(":[0-9]+\\z", RegexOptions.CultureInvariant)]
    private static partial Regex PortSuffix();

    /// <summary>The most fetches /api/observe takes at once.</summary>
    public const int Batch = 500;

    /// <summary>The most of a log read at once, so a log of any size fits in memory a piece at a time.</summary>
    private const int Chunk = 32 * 1024 * 1024;

    /// <summary>How many bytes at the start of a log identify it.</summary>
    private const int Head = 256;

    /// <summary>
    /// A request target as a page on the site. Absolute targets ("GET http://other/x", a proxy request) name
    /// somewhere else and are skipped. The target is set as the path and query of the site's own address, never
    /// parsed as a URL, so "//x" and "/\x" stay paths on the site.
    /// </summary>
    private static string? PageUrl(string target, string @base)
    {
        if (!target.StartsWith('/'))
        {
            return null;
        }
        var url = Url.Parse(@base);
        if (url == null)
        {
            return null;
        }
        int query = target.IndexOf('?', StringComparison.Ordinal);
        url.SetPathname("/" + (query < 0 ? target : target[..query]).TrimStart('/'));
        url.SetSearch(query < 0 ? "" : target[query..]);
        url.Hash = "";
        return url.Href;
    }

    /// <summary>"07/Oct/2026:13:55:36 -0400" as epoch milliseconds, or NaN.</summary>
    private static double LogTime(string value)
    {
        var m = LogTimeText().Match(value);
        if (!m.Success || !Months.TryGetValue(m.Groups[2].Value, out int month))
        {
            return double.NaN;
        }
        // Date.UTC reads years 0 to 99 as 1900 to 1999, and lets days and hours run on past their end.
        long year = Int(m.Groups[3].Value);
        year += year <= 99 ? 1900 : 0;
        long days = DaysFromCivil(year, month + 1) + Int(m.Groups[1].Value) - 1;
        long local = (((days * 24 + Int(m.Groups[4].Value)) * 60 + Int(m.Groups[5].Value)) * 60 + Int(m.Groups[6].Value)) * 1000;
        long offset = (Int(m.Groups[8].Value) * 60 + Int(m.Groups[9].Value)) * 60_000 * (m.Groups[7].Value == "-" ? -1 : 1);
        return local - offset;
    }

    private static long Int(string digits) => long.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);

    /// <summary>Days from 1970-01-01 to the first of this month.</summary>
    private static long DaysFromCivil(long year, int month)
    {
        long y = month <= 2 ? year - 1 : year;
        long era = (y >= 0 ? y : y - 399) / 400;
        long yoe = y - era * 400;
        long doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5;
        long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// <summary><c>value?.[key]</c>, for a value that may be null or undefined.</summary>
    private static object? At(object? value, string key) => value switch
    {
        JsObject o => o.Prop(key),
        string s when key == "length" => (double)s.Length,
        List<object?> l when key == "length" => (double)l.Count,
        _ => Undefined.Value,
    };

    /// <summary><c>value?.[index]</c>: a list's item, or a string's character.</summary>
    private static object? At(object? value, int index) => value switch
    {
        List<object?> l => index < l.Count ? l[index] : Undefined.Value,
        string s => index < s.Length ? s[index].ToString() : Undefined.Value,
        JsObject o => o.Prop(Js.Str(index)),
        _ => Undefined.Value,
    };

    /// <summary>A whole number as a long, as JavaScript makes no difference between them.</summary>
    private static object Whole(double n) => double.IsFinite(n) && Math.Floor(n) == n && Math.Abs(n) < 9.0e15 ? (long)n : n;

    private static double Number(object? n) => n switch
    {
        long l => l,
        double d => d,
        _ => double.NaN,
    };

    /// <summary>
    /// One log line as a page fetch, or null: an object of method, url, status, userAgent, and at.
    /// <paramref name="site"/> is the address pages live at (https://example.com), for formats that do not record
    /// the host.
    /// </summary>
    public static JsObject? ParseLine(string line, string? site = null)
    {
        ArgumentNullException.ThrowIfNull(line);
        string text = Js.Trim(line);
        if (text.Length == 0)
        {
            return null;
        }
        if (text.StartsWith('{'))
        {
            // Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
            try
            {
                object? entry = Json.Parse(text);
                object? request = At(entry, "request");
                object? uri = At(request, "uri");
                object? method = At(request, "method");
                if (!Js.Truthy(uri) || !Js.Truthy(method))
                {
                    return null;
                }
                object? host = At(request, "host");
                string? @base = Js.Truthy(host)
                    ? (Js.Truthy(At(request, "tls")) ? "https" : (site != null && site.StartsWith("http://", StringComparison.Ordinal) ? "http" : "https")) + "://" + Js.String(host)
                    : site;
                if (string.IsNullOrEmpty(@base))
                {
                    return null;
                }
                object? headers = At(request, "headers");
                object? ua = ImportHttp.Coalesce(At(At(headers, "User-Agent"), 0), ImportHttp.Coalesce(At(At(headers, "user-agent"), 0), ""));
                object? ts = At(entry, "ts");
                object at = ts is double or long ? Whole(Number(ts) * 1000) : Whole(ImportHttp.ParseDate(Js.String(ImportHttp.Coalesce(ts, ""))));
                // A target that is not text cannot be a page, as startsWith throws on it in TypeScript.
                string? url = uri is string target ? PageUrl(target, @base) : null;
                if (url == null)
                {
                    return null;
                }
                return new JsObject
                {
                    ["method"] = method,
                    ["url"] = url,
                    ["status"] = Whole(Js.Number(ImportHttp.Coalesce(At(entry, "status"), 0L))),
                    ["userAgent"] = Js.String(ua),
                    ["at"] = at,
                };
            }
            catch (Exception e) when (e is JsonParseException or JsTypeError or InvalidCastException)
            {
                return null;
            }
        }
        var m = Combined.Match(text);
        if (!m.Success)
        {
            return null;
        }
        // A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise site does.
        string first = m.Groups[1].Value;
        string? vhost = first.Length > 0 && Letter().IsMatch(first) && !Address().IsMatch(first) ? PortSuffix().Replace(first, "", 1) : null;
        string? root = vhost != null ? "https://" + vhost : site;
        if (string.IsNullOrEmpty(root))
        {
            return null;
        }
        string? page = PageUrl(m.Groups[4].Value, root);
        return page != null
            ? new JsObject
            {
                ["method"] = m.Groups[3].Value,
                ["url"] = page,
                ["status"] = Int(m.Groups[5].Value),
                ["userAgent"] = m.Groups[6].Value.Replace("\\\"", "\"", StringComparison.Ordinal),
                ["at"] = Whole(LogTime(m.Groups[2].Value)),
            }
            : null;
    }

    /// <summary>
    /// The lines worth sending: GETs that succeeded, from known AI agents, as an object of url, userAgent, and at.
    /// <paramref name="now"/> is epoch milliseconds, for a line whose time cannot be read.
    /// </summary>
    public static JsObject? AgentFetch(string line, string? site = null, Func<long>? now = null)
    {
        var hit = ParseLine(line, site);
        if (hit == null)
        {
            return null;
        }
        double status = Number(hit.Get("status"));
        if (hit.Get("method") is not "GET" || status < 200 || status >= 400 || Ua.AiAgent(hit.Str("userAgent")!) == null)
        {
            return null;
        }
        object? at = hit.Get("at");
        return new JsObject
        {
            ["url"] = hit.Get("url"),
            ["userAgent"] = hit.Get("userAgent"),
            ["at"] = double.IsFinite(Number(at)) ? at : (now ?? Clock)(),
        };
    }

    private static long Clock() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>Sends one batch of fetches to /api/observe and returns how many Runlight kept.</summary>
    private static async Task<double> SendAsync(AgentsOptions options, IFetcher fetcher, List<object?> fetches)
    {
        Response answer;
        try
        {
            answer = await fetcher.FetchAsync(options.To.TrimEnd('/') + "/api/observe", new FetchInit
            {
                Method = "POST",
                Headers = new Headers { ["authorization"] = "Bearer " + options.Key, ["content-type"] = "application/json" },
                BodyText = Json.Stringify(new JsObject { ["fetches"] = fetches }),
                TimeoutMs = 30_000,
            }).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            throw new SendError(error.Message, error);
        }
        if (answer.Status == 401)
        {
            throw new SendError("Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins.");
        }
        string text = await answer.TextAsync().ConfigureAwait(false);
        if (!answer.Ok)
        {
            throw new SendError("Runlight answered " + Js.Str(answer.Status) + ": " + Js.Slice(text, 0, 200));
        }
        return Json.TryParse(text, out object? body) && body is JsObject o && o.Get("recorded") is double or long ? Number(o.Get("recorded")) : 0;
    }

    /// <summary>Opens a file for reading, or throws with the reason.</summary>
    private static FileStream Open(string file)
    {
        try
        {
            return new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new IOException(e.Message, e);
        }
    }

    private readonly record struct Stat(long Ino, long Size);

    private static Stat StatOf(string file)
    {
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists)
            {
                throw new FileNotFoundException("Could not find file '" + file + "'", file);
            }
            return new Stat(FileId.Of(file), info.Length);
        }
        catch (Exception e) when (e is UnauthorizedAccessException)
        {
            throw new IOException(e.Message, e);
        }
    }

    /// <summary>Up to <paramref name="length"/> bytes from <paramref name="offset"/>.</summary>
    private static byte[] ReadAt(FileStream fd, long offset, int length)
    {
        if (length <= 0)
        {
            return [];
        }
        fd.Seek(offset, SeekOrigin.Begin);
        byte[] buffer = new byte[length];
        int read = 0;
        while (read < length)
        {
            int n = fd.Read(buffer, read, length - read);
            if (n == 0)
            {
                break;
            }
            read += n;
        }
        return read == length ? buffer : buffer[..read];
    }

    private readonly record struct Fingerprint(string Head, int Length);

    /// <summary>
    /// A fingerprint of the log's first bytes. A log rotated by copying and truncating keeps its inode, so a
    /// different start is how a new log shows itself. An open file (in follow mode) is read as it is, even once it
    /// is renamed.
    /// </summary>
    private static Fingerprint HeadOf(string file, int length = Head)
    {
        using var fd = Open(file);
        return HeadOf(fd, length);
    }

    private static Fingerprint HeadOf(FileStream fd, int length = Head)
    {
        byte[] buffer = ReadAt(fd, 0, (int)Math.Min(length, fd.Length));
        return new Fingerprint(Hash.Sha256(buffer), buffer.Length);
    }

    /// <summary>Whether the log at this inode still starts the way it did, so a saved place in it still holds.</summary>
    private static bool SameLog(string file, JsObject saved, Stat stat)
    {
        if (saved.Long("ino") != stat.Ino)
        {
            return false;
        }
        if (!Js.Truthy(saved.Prop("head")) || saved.Prop("length") is Undefined)
        {
            return true;
        }
        long length = (long)Js.Number(saved.Prop("length"));
        return stat.Size >= length && HeadOf(file, (int)length).Head == Js.String(saved.Prop("head"));
    }

    private sealed record Read(List<string> Lines, List<long> Ends, long Next, bool More);

    /// <summary>
    /// Reads whole lines from a byte offset, at most a chunk, and returns where the next read starts. Offsets
    /// count bytes up to each newline byte, so a malformed character cannot shift them. Ends holds where the line
    /// after each one starts, so a place can be saved part way through a chunk.
    /// </summary>
    private static Read ReadFrom(string file, long offset)
    {
        // A path is opened for this read; an open file (in follow mode) stays open, even once it is renamed.
        if (StatOf(file).Size <= offset)
        {
            return new Read([], [], offset, false);
        }
        using var fd = Open(file);
        return ReadFrom(fd, offset);
    }

    private static Read ReadFrom(FileStream fd, long offset)
    {
        long size = fd.Length;
        if (size <= offset)
        {
            return new Read([], [], offset, false);
        }
        byte[] buffer = ReadAt(fd, offset, (int)Math.Min(size - offset, Chunk));
        int end = Array.LastIndexOf(buffer, (byte)'\n');
        // A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
        if (end < 0)
        {
            return buffer.Length == Chunk ? new Read([], [], offset + buffer.Length, true) : new Read([], [], offset, false);
        }
        var lines = new List<string>();
        var ends = new List<long>();
        for (int start = 0; start <= end;)
        {
            int newline = Array.IndexOf(buffer, (byte)'\n', start);
            // Read as UTF-8 the way Node does, each malformed sequence becoming U+FFFD.
            lines.Add(Js.Decode(buffer.AsSpan(start, newline - start)));
            ends.Add(offset + newline + 1);
            start = newline + 1;
        }
        return new Read(lines, ends, offset + end + 1, offset + buffer.Length < size);
    }

    /// <summary>Whether a process with this id is running on this machine.</summary>
    private static bool Running(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // It runs, as someone else.
            return true;
        }
    }

    /// <summary>The text of a file, or null when it cannot be read.</summary>
    private static string? Contents(string file)
    {
        try
        {
            return File.ReadAllText(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// Takes the lock beside a state file, so two runs never read from the same place and send the same lines
    /// twice. The lock holds the run's process id; a lock left by a process that is no longer running is taken
    /// over. Returns the release.
    /// </summary>
    private static Action Lock(string state)
    {
        string path = state + ".lock";
        string mine = Js.Str(Environment.ProcessId);
        for (int attempt = 0; attempt < 3; attempt++)
        {
            if (Config.WriteNew(path, mine))
            {
                bool released = false;
                EventHandler? onExit = null;
                void Release()
                {
                    if (released)
                    {
                        return;
                    }
                    released = true;
                    AppDomain.CurrentDomain.ProcessExit -= onExit;
                    if (Contents(path) == mine)
                    {
                        TryDelete(path);
                    }
                }
                // Released on exit too, as a run that stops part way would otherwise leave its lock behind.
                onExit = (_, _) => Release();
                AppDomain.CurrentDomain.ProcessExit += onExit;
                return Release;
            }
            if (!File.Exists(path))
            {
                throw new IOException("Could not create " + path);
            }
            string? held = Contents(path);
            if (held == null)
            {
                continue;
            }
            held = Js.Trim(held);
            double pid = Js.Number(held);
            // A lock being written has no id in it yet, so it counts as held.
            if (held.Length == 0 || (pid > 0 && pid <= int.MaxValue && Math.Floor(pid) == pid && Running((int)pid)))
            {
                break;
            }
            // Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one that
            // finds a newer lock moved aside puts it back.
            string aside = path + "." + mine;
            try
            {
                File.Move(path, aside, true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }
            if (Js.Trim(Contents(aside) ?? "") != held)
            {
                try
                {
                    File.Copy(aside, path, false);
                }
                catch (IOException)
                {
                }
                File.Delete(aside);
                break;
            }
            File.Delete(aside);
        }
        string holder = Js.Trim(Contents(path) ?? "");
        throw new IOException("Another run is using " + state + (holder.Length > 0 ? " (process " + holder + ")" : "") + ". Wait for it to finish, or delete " + path + " if none is running.");
    }

    private static void TryDelete(string file)
    {
        try
        {
            File.Delete(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Writes the state whole or not at all, so a crash part way never leaves it empty.</summary>
    private static void WriteState(string state, long ino, long offset, Fingerprint head)
    {
        string temp = state + "." + Js.Str(Environment.ProcessId) + ".tmp";
        try
        {
            File.WriteAllBytes(temp, Js.Utf8(Json.Stringify(new JsObject { ["ino"] = ino, ["offset"] = offset, ["head"] = head.Head, ["length"] = (long)head.Length })));
            File.Move(temp, state, true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new IOException("Could not write " + state + ": " + e.Message, e);
        }
    }

    /// <summary>Reads the log and sends what AI agents fetched, returning how many fetches Runlight kept.</summary>
    public static async Task<double> RunAsync(AgentsOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        Action release = !string.IsNullOrEmpty(options.State) ? Lock(options.State) : () => { };
        try
        {
            return await ReadLogAsync(options).ConfigureAwait(false);
        }
        finally
        {
            release();
        }
    }

    private static async Task<double> ReadLogAsync(AgentsOptions options)
    {
        Action<string> say = options.Out ?? Console.WriteLine;
        IFetcher? made = null;
        IFetcher fetcher = options.Fetcher ?? (made = new HttpClientFetcher());
        try
        {
            return await ReadLogAsync(options, say, fetcher).ConfigureAwait(false);
        }
        finally
        {
            (made as IDisposable)?.Dispose();
        }
    }

    private static async Task<double> ReadLogAsync(AgentsOptions options, Action<string> say, IFetcher fetcher)
    {
        Func<long> now = options.Now ?? Clock;
        string? site = !string.IsNullOrEmpty(options.Site) ? options.Site : null;
        string? state = !string.IsNullOrEmpty(options.State) ? options.State : null;
        string log = options.Log;
        if (!File.Exists(log))
        {
            throw new FileNotFoundException("No log at " + log, log);
        }
        double total = 0;
        bool warned = false;

        // Sends the agent fetches among lines read, a batch at a time, calling done with where the next unsent line
        // starts after each batch, so a failure part way sends none of the earlier batches again.
        async Task<double> HandleAsync(Read read, Action<long> done)
        {
            // Lines with no host and no site cannot be placed on a site; say so once rather than skip them silently.
            if (site == null && !warned)
            {
                foreach (string line in read.Lines)
                {
                    if (!Js.Trim(line).StartsWith('{') && RequestLine.IsMatch(line) && ParseLine(line) == null)
                    {
                        warned = true;
                        say("Some lines have no host in them. Add --site https://your-site.example so they can be counted.");
                        break;
                    }
                }
            }
            double kept = 0;
            var batch = new List<object?>();
            int count = read.Lines.Count;
            for (int i = 0; i < count; i++)
            {
                var found = AgentFetch(read.Lines[i], site, now);
                if (found != null)
                {
                    batch.Add(found);
                }
                if (batch.Count == Batch || (i == count - 1 && batch.Count > 0))
                {
                    double recorded = await SendAsync(options, fetcher, batch).ConfigureAwait(false);
                    kept += recorded;
                    total += recorded;
                    batch = [];
                    done(read.Ends[i]);
                }
            }
            return kept;
        }

        // The place to save: the file being read, by its inode and its own start, and how far into it.
        void Save(long ino, long offset, Fingerprint head)
        {
            if (state != null)
            {
                WriteState(state, ino, offset, head);
            }
        }

        // Where the last run stopped, or null with a word about it when the state file cannot be read.
        JsObject? ReadState()
        {
            if (state == null || !File.Exists(state))
            {
                return null;
            }
            Json.TryParse(Contents(state) ?? "", out object? saved);
            object? ino = saved is JsObject o1 ? o1.Prop("ino") : null;
            object? offset = saved is JsObject o2 ? o2.Prop("offset") : null;
            if (ino is double or long && offset is double or long)
            {
                var place = new JsObject { ["ino"] = Whole(Number(ino)), ["offset"] = Whole(Number(offset)) };
                var s = (JsObject)saved!;
                if (s.Prop("head") is not Undefined)
                {
                    place["head"] = s.Prop("head");
                }
                if (s.Prop("length") is not Undefined)
                {
                    place["length"] = s.Prop("length");
                }
                return place;
            }
            say("Could not read " + state + ", so this run starts as if it were the first.");
            return null;
        }

        if (!options.Follow)
        {
            // Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
            var saved = ReadState();
            var stat = StatOf(log);
            long offset = saved != null && saved.Num("offset") <= stat.Size && SameLog(log, saved, stat) ? (long)saved.Num("offset") : 0;
            long lines = 0;
            // A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
            while (true)
            {
                var read = ReadFrom(log, offset);
                await HandleAsync(read, at => Save(stat.Ino, at, HeadOf(log))).ConfigureAwait(false);
                lines += read.Lines.Count;
                offset = read.Next;
                Save(stat.Ino, offset, HeadOf(log));
                if (!read.More)
                {
                    break;
                }
            }
            say("Sent " + Json.Number(total) + " AI agent fetches from " + Js.Str(lines) + " new lines.");
            return total;
        }

        // Follow: start where the state says, else at the end like tail -F. A log that was rotated since the state
        // was saved is all new, so it is read from its start.
        Func<bool> stop = options.Stop ?? (() => false);
        Func<int, Task> sleep = options.Sleep ?? (ms => Task.Delay(ms));
        var resumed = ReadState();
        var first = StatOf(log);
        long inode = first.Ino;
        long place = resumed != null ? (resumed.Num("offset") <= first.Size && SameLog(log, resumed, first) ? (long)resumed.Num("offset") : 0) : first.Size;
        say("Following " + log + ". AI agent fetches go to " + options.To + " as they happen.");
        // The log stays open, so when it is renamed in a rotation, what was written to it before the switch is
        // still read to the end before the new log starts. Its fingerprint is taken from the open file too, so a
        // place saved while finishing an old log names that log, never the new one.
        var fd = Open(log);
        try
        {
            var known = HeadOf(fd);
            // The same trouble every two seconds is said once, until something changes.
            string trouble = "";
            while (!stop())
            {
                await sleep(options.PollMs).ConfigureAwait(false);
                try
                {
                    Stat? stat = File.Exists(log) ? StatOf(log) : null;
                    bool renamed = stat == null || stat.Value.Ino != inode;
                    // Copied and truncated in place: the same file, shorter or with a new start.
                    if (!renamed && (stat!.Value.Size < place || !SameLog(log, new JsObject { ["ino"] = inode, ["head"] = known.Head, ["length"] = (long)known.Length }, stat.Value)))
                    {
                        place = 0;
                    }
                    var read = ReadFrom(fd, place);
                    double sent = await HandleAsync(read, at =>
                    {
                        place = at;
                        Save(inode, place, known);
                    }).ConfigureAwait(false);
                    // Only past lines that were sent, so a failed send is tried again next time.
                    place = read.Next;
                    Save(inode, place, known);
                    if (sent != 0)
                    {
                        say("Sent " + Json.Number(sent) + " AI agent fetches.");
                    }
                    if (renamed && stat != null && !read.More)
                    {
                        // The old log is finished; the new one is read from its start.
                        var next = Open(log);
                        await fd.DisposeAsync().ConfigureAwait(false);
                        fd = next;
                        inode = stat.Value.Ino;
                        place = 0;
                    }
                    // The start grows until it is Head bytes long, so the fingerprint is taken again each time.
                    known = HeadOf(fd);
                    trouble = "";
                }
                catch (Exception error)
                {
                    string said = error is SendError ? "Could not send, trying again shortly: " + error.Message : "Could not read " + log + ", trying again shortly: " + error.Message;
                    if (said != trouble)
                    {
                        say(said);
                    }
                    trouble = said;
                }
            }
        }
        finally
        {
            await fd.DisposeAsync().ConfigureAwait(false);
        }
        return total;
    }
}
