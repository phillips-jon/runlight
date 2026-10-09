using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Server;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Server;

/// <summary>The port of the Node server's agents.test.ts, by way of the PHP's AgentsTest: the access log reader that counts AI agents.</summary>
public sealed class AgentsTests : ServerTestCase
{
    private const string GptBot = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)";
    private const string Claude = "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)";
    private const string Chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "runlight-agents-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6)));

    public override ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(_dir);
        return base.InitializeAsync();
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        if (File.Exists(_dir + "/access.log") && !OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(_dir + "/access.log", UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
        }
        Directory.Delete(_dir, true);
    }

    private static string Line(string path, string ua, int status = 200, string method = "GET", string time = "07/Oct/2026:13:55:36 -0400", string vhost = "") =>
        (vhost.Length > 0 ? vhost + " " : "") + "203.0.113.9 - - [" + time + "] \"" + method + " " + path + " HTTP/1.1\" " + status + " 5120 \"-\" \"" + ua + "\"";

    private static long Utc(int y, int m, int d, int h = 0, int i = 0, int s = 0) => Time.Utc(y, m - 1, d, h, i, s);

    /// <summary>The files in the test's folder.</summary>
    private List<string> Files() => [.. Directory.GetFiles(_dir).Select(Path.GetFileName).Order(StringComparer.Ordinal)!];

    private static void Quiet(string line)
    {
    }

    /// <summary>A Runlight that takes reports for example.com with the key rlo_site, and a fetcher that reaches its routes.</summary>
    private static async Task<(Runlight Rl, FakeFetcher Fetcher)> RunlightAsync()
    {
        long now = Utc(2026, 10, 7, 18);
        var rl = new Runlight(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Site = new SiteOptions { Hostnames = ["example.com"] }, Now = () => now });
        await rl.InitAsync();
        await rl.Store.SetSettingAsync("observe-key:default", "rlo_site");
        var routes = rl.Routes(new RoutesOptions { Token = "owner" });
        var fetcher = new FakeFetcher((url, init) => routes.HandleAsync(new Request(url, init.Method, init.Headers, init.Body)));
        return (rl, fetcher);
    }

    /// <summary>
    /// A fetcher like a small server that keeps each batch, answering with how many it took. <paramref name="answer"/>
    /// is an answer of its own for a post, given its number and size.
    /// </summary>
    private sealed class Counter(Func<int, int, Response?>? answer = null) : IFetcher
    {
        public int Stored { get; set; }

        public int Posts { get; private set; }

        public Task<Response> FetchAsync(string url, FetchInit? init = null, System.Threading.CancellationToken cancellationToken = default)
        {
            Posts++;
            int n = ((JsObject)Json.Parse(init!.BodyText!)!).Arr("fetches")!.Count;
            var own = answer?.Invoke(Posts, n);
            if (own != null)
            {
                return Task.FromResult(own);
            }
            Stored += n;
            return Task.FromResult(Response.JsonOf(new JsObject { ["recorded"] = (long)n }));
        }
    }

    [Fact]
    public void Log_lines_nginx_and_apache_combined_a_vhost_column_and_caddys_json()
    {
        Assert.Equal(
            Json.Stringify(new JsObject { ["method"] = "GET", ["url"] = "https://example.com/blog/post?x=1", ["status"] = 200L, ["userAgent"] = GptBot, ["at"] = Utc(2026, 10, 7, 17, 55, 36) }),
            Json.Stringify(Agents.ParseLine(Line("/blog/post?x=1", GptBot), "https://example.com")));
        Assert.Null(Agents.ParseLine(Line("/", GptBot))); // with no host anywhere there is no page to name
        Assert.Equal("https://blog.example.com/", Agents.ParseLine(Line("/", GptBot, vhost: "blog.example.com:443"))!.Str("url"));
        string caddy = Json.Stringify(new JsObject { ["ts"] = 1791399336.5, ["status"] = 200L, ["request"] = new JsObject { ["method"] = "GET", ["host"] = "example.com", ["uri"] = "/docs/", ["tls"] = new JsObject(), ["headers"] = new JsObject { ["User-Agent"] = new List<object?> { Claude } } } });
        Assert.Equal(
            Json.Stringify(new JsObject { ["method"] = "GET", ["url"] = "https://example.com/docs/", ["status"] = 200L, ["userAgent"] = Claude, ["at"] = 1791399336500L }),
            Json.Stringify(Agents.ParseLine(caddy)));
        Assert.Null(Agents.ParseLine("not a log line"));
        // A target is a path and query on the site, never read as an address: a backslash cannot name another host.
        Assert.Equal("https://example.com//evil.example/x?y=1", Agents.ParseLine(Line("/\\evil.example/x?y=1", GptBot), "https://example.com")!.Str("url"));
        Assert.Equal("https://example.com/evil.example/x", Agents.ParseLine(Line("//evil.example/x", GptBot), "https://example.com")!.Str("url"));

        // Only successful GETs from AI agents are worth sending.
        Assert.NotNull(Agents.AgentFetch(Line("/", GptBot), "https://example.com"));
        Assert.Null(Agents.AgentFetch(Line("/", Chrome), "https://example.com")); // people are the tracker's job
        Assert.Null(Agents.AgentFetch(Line("/", GptBot, 404), "https://example.com"));
        Assert.Null(Agents.AgentFetch(Line("/", GptBot, 200, "POST"), "https://example.com"));
    }

    [Fact]
    public void Lines_are_read_as_the_node_command_reads_them()
    {
        var fixture = Fixtures.Load("agents");
        long now = fixture.Long("now");
        var failures = new List<string>();
        foreach (var item in fixture.Arr("cases")!)
        {
            var c = (JsObject)item!;
            string? site = c.Get("site") as string;
            var parsed = Agents.ParseLine(c.Str("line")!, site);
            if (parsed != null && parsed.Get("at") is double d && double.IsNaN(d))
            {
                parsed["at"] = "NaN";
            }
            if (Json.Stringify(parsed) != Json.Stringify(c.Get("parsed")))
            {
                failures.Add("parsed " + Fixtures.Label(c) + ": " + Json.Stringify(parsed));
            }
            var fetched = Agents.AgentFetch(c.Str("line")!, site, () => now);
            if (Json.Stringify(fetched) != Json.Stringify(c.Get("fetched")))
            {
                failures.Add("fetched " + Fixtures.Label(c) + ": " + Json.Stringify(fetched));
            }
        }
        Fixtures.NoFailures(failures);
    }

    [Fact]
    public async Task A_log_is_read_once_carries_on_where_it_stopped_and_starts_over_after_rotation()
    {
        var (rl, fetcher) = await RunlightAsync();
        const string to = "http://127.0.0.1:9/runlight";
        string log = _dir + "/access.log";
        string state = _dir + "/state.json";
        Task<List<JsObject>> Fetches() => rl.Store.Db.AllAsync("SELECT path, name, ts FROM rl_events WHERE kind = 'fetch' ORDER BY ts, path");
        Task<double> Run() => Agents.RunAsync(new AgentsOptions { Log = log, To = to, Key = "rlo_site", Site = "https://example.com", State = state, Fetcher = fetcher, Out = Quiet });

        File.WriteAllText(log, string.Join("\n", Line("/a", GptBot), Line("/b", Chrome), Line("/c", Claude, 200, "GET", "07/Oct/2026:13:56:00 -0400"), Line("/style.css", GptBot), ""));
        Assert.Equal(2, await Run()); // two pages count; the stylesheet and the person do not
        var first = await Fetches();
        Assert.Equal(["/a GPTBot", "/c ClaudeBot"], first.Select(f => f.Str("path") + " " + f.Str("name"))); // Runlight keeps pages, not their assets
        Assert.Equal(Utc(2026, 10, 7, 17, 55, 36), (long)Sql.Num(first[0].Get("ts"))); // counted when the page was served
        Assert.Equal("Bearer rlo_site", fetcher.Requests[0].Headers.Str("authorization"));
        Assert.Equal("http://127.0.0.1:9/runlight/api/observe", fetcher.Requests[0].Url);

        Assert.Equal(0, await Run()); // nothing new, nothing sent
        File.AppendAllText(log, Line("/d", GptBot) + "\n");
        Assert.Equal(1, await Run());

        File.Move(log, log + ".1");
        File.WriteAllText(log, Line("/e", Claude) + "\n");
        Assert.Equal(1, await Run()); // a rotated log is read from the top
        Assert.Equal(["/a", "/c", "/d", "/e"], (await Fetches()).Select(f => f.Str("path")!).Order(StringComparer.Ordinal));
        File.Delete(log + ".1");

        var refused = await Assert.ThrowsAsync<SendError>(() => Agents.RunAsync(new AgentsOptions { Log = log, To = to, Key = "rlo_wrong", Site = "https://example.com", Fetcher = fetcher, Out = Quiet }));
        Assert.Contains("refused the key", refused.Message, StringComparison.Ordinal);

        // Lines for another host, a // path, an absolute target, an old line, and a bad byte: none stops the rest.
        int before = (await Fetches()).Count;
        using (var file = File.Create(log))
        {
            file.Write(Encoding.UTF8.GetBytes(Line("/f", GptBot, 200, "GET", "07/Oct/2026:13:57:00 -0400", "other.example:443") + "\n"));
            file.Write(Encoding.UTF8.GetBytes(Line("//g", GptBot) + "\n"));
            file.Write(Encoding.UTF8.GetBytes(Line("http://evil.example/h", GptBot) + "\n"));
            file.Write(Encoding.UTF8.GetBytes(Line("/old", GptBot, 200, "GET", "01/Sep/2026:10:00:00 -0400") + "\n"));
            file.Write([0xff, 0xfe, (byte)'\n']);
            file.Write(Encoding.UTF8.GetBytes(Line("/i", Claude) + "\n"));
        }
        Assert.Equal(2, await Run()); // /g and /i count; the other host, the absolute target, and the old line do not
        var paths = (await Fetches()).Select(f => f.Str("path")).ToList();
        Assert.Equal(before + 2, paths.Count);
        Assert.Contains("/g", paths);
        Assert.Contains("/i", paths);
        Assert.DoesNotContain("/f", paths);
        Assert.DoesNotContain("/h", paths);
        Assert.DoesNotContain("/old", paths);
        Assert.Equal(0, await Run()); // the offset after a bad byte lands on the next line, so nothing is sent twice

        // Rotated by copying and truncating: the same file, a new start, already longer than the old place.
        await TruncateAndWriteAsync(log, Line("/one", GptBot) + "\n");
        Assert.Equal(1, await Run());
        await TruncateAndWriteAsync(log, Line("/two", Claude) + "\n" + Line("/three", GptBot) + "\n");
        Assert.Equal(2, await Run()); // both lines of the new log, none skipped
    }

    /// <summary>Writes a file over in place, as file_put_contents does, so it keeps its inode.</summary>
    private static async Task TruncateAndWriteAsync(string file, string text)
    {
        await using var stream = new FileStream(file, FileMode.Truncate, FileAccess.Write);
        await stream.WriteAsync(Encoding.UTF8.GetBytes(text));
    }

    [Fact]
    public async Task Following_a_log_reads_what_was_written_just_before_a_rotation_then_the_new_log()
    {
        var (rl, fetcher) = await RunlightAsync();
        string log = _dir + "/access.log";
        File.WriteAllText(log, "");
        int polls = 0;
        var said = new List<string>();
        // Each look at the log waits first; the steps run in that wait, as another process writing the log would.
        await Agents.RunAsync(new AgentsOptions
        {
            Log = log,
            To = "http://127.0.0.1:9/runlight",
            Key = "rlo_site",
            Site = "https://example.com",
            Follow = true,
            Fetcher = fetcher,
            Sleep = _ =>
            {
                polls++;
                if (polls == 2)
                {
                    File.AppendAllText(log, Line("/before", GptBot) + "\n");
                    // Rotated before the reader looks again: the last line is in the renamed file only.
                    File.AppendAllText(log, Line("/last-old", Claude) + "\n");
                    File.Move(log, log + ".1");
                    File.WriteAllText(log, Line("/new", GptBot) + "\n");
                }
                return Task.CompletedTask;
            },
            Stop = () => polls >= 6,
            Out = said.Add,
        });
        var paths = (await rl.Store.Db.AllAsync("SELECT path FROM rl_events WHERE kind = 'fetch' ORDER BY path")).Select(r => r.Str("path"));
        Assert.Equal(["/before", "/last-old", "/new"], paths);
        Assert.Equal("Following " + log + ". AI agent fetches go to http://127.0.0.1:9/runlight as they happen.", said[0]);
        Assert.Equal(["Sent 2 AI agent fetches.", "Sent 1 AI agent fetches."], said.Skip(1));
    }

    [Fact]
    public async Task A_failed_batch_sends_none_of_the_earlier_ones_again_and_a_bad_state_file_starts_over_with_a_word()
    {
        int failAt = 0;
        var fetcher = new Counter((post, _) => post == failAt ? new Response("busy", 503) : null);
        string log = _dir + "/access.log";
        string state = _dir + "/state.json";
        File.WriteAllText(log, string.Concat(Enumerable.Range(0, 1200).Select(i => Line("/p" + i, GptBot) + "\n")));
        failAt = 2;
        var e = await Assert.ThrowsAsync<SendError>(() => Agents.RunAsync(new AgentsOptions { Log = log, To = "http://127.0.0.1:9", Key = "k", Site = "https://example.com", State = state, Fetcher = fetcher, Out = Quiet }));
        Assert.Equal("Runlight answered 503: busy", e.Message);
        Assert.Equal(500, fetcher.Stored); // the first batch went
        await Agents.RunAsync(new AgentsOptions { Log = log, To = "http://127.0.0.1:9", Key = "k", Site = "https://example.com", State = state, Fetcher = fetcher, Out = Quiet });
        Assert.Equal(1200, fetcher.Stored); // each line once

        File.WriteAllText(state, "{ not json");
        var said = new List<string>();
        fetcher.Stored = 0;
        await Agents.RunAsync(new AgentsOptions { Log = log, To = "http://127.0.0.1:9", Key = "k", Site = "https://example.com", State = state, Fetcher = fetcher, Out = said.Add });
        Assert.Matches("^Could not read .*state\\.json", said[0]);
        Assert.Equal("Sent 1200 AI agent fetches from 1200 new lines.", said[1]);
        Assert.Equal(1200, fetcher.Stored); // read from the top
        Assert.Equal(new FileInfo(log).Length, ((JsObject)Json.Parse(File.ReadAllText(state))!).Long("offset"));
    }

    [Fact]
    public async Task Lines_with_no_host_and_no_site_are_mentioned_once()
    {
        var fetcher = new Counter();
        string log = _dir + "/access.log";
        File.WriteAllText(log, Line("/a", GptBot) + "\n" + Line("/b", GptBot) + "\n");
        var said = new List<string>();
        double sent = await Agents.RunAsync(new AgentsOptions { Log = log, To = "http://127.0.0.1:9", Key = "k", Fetcher = fetcher, Out = said.Add });
        Assert.Equal(0, sent);
        Assert.Equal(["Some lines have no host in them. Add --site https://your-site.example so they can be counted.", "Sent 0 AI agent fetches from 2 new lines."], said);
        Assert.Equal(0, fetcher.Posts);
    }

    [Fact]
    public async Task One_run_at_a_time_uses_a_state_file_a_crashed_runs_lock_is_taken_over_and_the_state_is_written_whole()
    {
        string log = _dir + "/access.log";
        string state = _dir + "/state.json";
        string? second = null;
        Func<Task<double>>? run = null;
        // While the first run sends its first batch, a second one starts on the same state file.
        var fetcher = new Counter((post, _) =>
        {
            if (post == 1)
            {
                try
                {
                    run!().GetAwaiter().GetResult();
                    second = "ran";
                }
                catch (IOException error)
                {
                    second = error.Message;
                }
            }
            return null;
        });
        run = () => Agents.RunAsync(new AgentsOptions { Log = log, To = "http://127.0.0.1:9", Key = "k", Site = "https://example.com", State = state, Fetcher = fetcher, Out = Quiet });
        File.WriteAllText(log, string.Concat(Enumerable.Range(0, 1500).Select(i => Line("/p" + i, GptBot) + "\n")));
        Assert.Equal(1500, await run());
        Assert.Matches(new Regex("^Another run is using .*state\\.json \\(process [0-9]+\\)\\. Wait for it to finish, or delete .*state\\.json\\.lock if none is running\\.\\z"), second ?? "");
        Assert.Equal(1500, fetcher.Stored); // each line once
        Assert.Equal(["access.log", "state.json"], Files()); // the lock is released and no temporary file is left

        // A lock from a process that has ended is stale.
        int ended;
        using (var child = Process.Start(new ProcessStartInfo(OperatingSystem.IsWindows() ? "cmd.exe" : "/bin/sh", OperatingSystem.IsWindows() ? "/c exit" : "-c true") { UseShellExecute = false })!)
        {
            await child.WaitForExitAsync();
            ended = child.Id;
        }
        File.WriteAllText(state + ".lock", Js.Str(ended));
        File.AppendAllText(log, Line("/late", GptBot) + "\n");
        Assert.Equal(1, await run());
        Assert.Equal(1501, fetcher.Stored);
        Assert.Equal(["access.log", "state.json"], Files());

        // A lock held by a running process is left alone.
        string me = Js.Str(Environment.ProcessId);
        File.WriteAllText(state + ".lock", me);
        var held = await Assert.ThrowsAsync<IOException>(run);
        Assert.Contains("(process " + me + ")", held.Message, StringComparison.Ordinal);
        Assert.Equal(me, File.ReadAllText(state + ".lock"));
        File.Delete(state + ".lock");
    }

    [Fact]
    public async Task Following_a_log_that_cannot_be_read_waits_and_says_so_and_a_restart_reads_a_log_rotated_meanwhile_from_its_start()
    {
        if (OperatingSystem.IsWindows() || Environment.UserName == "root")
        {
            Assert.Skip("root reads every file, and Windows has no file modes");
        }
        var fetcher = new Counter();
        string log = _dir + "/access.log";
        string state = _dir + "/state.json";
        File.WriteAllText(log, "");
        int polls = 0;
        var steps = new Dictionary<int, Action>
        {
            [2] = () => File.AppendAllText(log, Line("/a", GptBot) + "\n"),
            [4] = () => Mode(log, UnixFileMode.None),
            [8] = () =>
            {
                Mode(log, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
                File.AppendAllText(log, Line("/b", GptBot) + "\n");
            },
        };
        var said = new List<string>();
        await Agents.RunAsync(new AgentsOptions
        {
            Log = log,
            To = "http://127.0.0.1:9",
            Key = "k",
            Site = "https://example.com",
            State = state,
            Follow = true,
            Fetcher = fetcher,
            Sleep = _ =>
            {
                polls++;
                if (steps.TryGetValue(polls, out var step))
                {
                    step();
                }
                return Task.CompletedTask;
            },
            Stop = () => polls >= 10,
            Out = said.Add,
        });
        Assert.Equal(2, fetcher.Stored); // it carried on once the log could be read again
        Assert.Single(said, l => l.StartsWith("Could not read", StringComparison.Ordinal)); // said once, not every poll
        Assert.DoesNotContain(said, l => l.StartsWith("Could not send", StringComparison.Ordinal));

        // Stopped, then the log was rotated: everything in the new log is unread.
        File.Move(log, log + ".1");
        File.WriteAllText(log, Line("/c", GptBot) + "\n" + Line("/d", GptBot) + "\n");
        polls = 0;
        await Agents.RunAsync(new AgentsOptions
        {
            Log = log,
            To = "http://127.0.0.1:9",
            Key = "k",
            Site = "https://example.com",
            State = state,
            Follow = true,
            Fetcher = fetcher,
            Sleep = _ =>
            {
                polls++;
                return Task.CompletedTask;
            },
            Stop = () => polls >= 3,
            Out = Quiet,
        });
        Assert.Equal(4, fetcher.Stored);
        Assert.Equal(["access.log", "access.log.1", "state.json"], Files());
    }

    private static void Mode(string file, UnixFileMode mode)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(file, mode);
        }
    }

    [Fact]
    public async Task A_send_that_cannot_reach_runlight_is_tried_again_on_the_next_look()
    {
        var fetcher = new Counter((post, _) => post <= 2 ? throw new FetchException("Could not connect") : null);
        string log = _dir + "/access.log";
        File.WriteAllText(log, "");
        int polls = 0;
        var said = new List<string>();
        await Agents.RunAsync(new AgentsOptions
        {
            Log = log,
            To = "http://127.0.0.1:9",
            Key = "k",
            Site = "https://example.com",
            Follow = true,
            Fetcher = fetcher,
            Sleep = _ =>
            {
                if (++polls == 1)
                {
                    File.WriteAllText(log, Line("/a", GptBot) + "\n");
                }
                return Task.CompletedTask;
            },
            Stop = () => polls >= 4,
            Out = said.Add,
        });
        Assert.Equal(1, fetcher.Stored);
        Assert.Equal(["Could not send, trying again shortly: Could not connect", "Sent 1 AI agent fetches."], said.Skip(1));
    }

    [Fact]
    public async Task The_command_line()
    {
        async Task<(int Code, string Out, string Err, FakeFetcher Fetcher)> RunAsync(params string[] args)
        {
            var output = new StringWriter();
            var error = new StringWriter();
            var fetcher = new FakeFetcher((url, init) => Response.JsonOf(new JsObject { ["recorded"] = (long)((JsObject)Json.Parse(init.BodyText!)!).Arr("fetches")!.Count }));
            int code = await Cli.RunAsync(args, _dir, output, error, () => 1_791_374_400_000, fetcher);
            return (code, output.ToString(), error.ToString(), fetcher);
        }
        var (code, output, error, sent) = await RunAsync("agents", "--help");
        Assert.Equal(0, code);
        Assert.Equal(Cli.AgentsHelp, output);
        (code, _, error, _) = await RunAsync("agents", "--log", "access.log");
        Assert.Equal(1, code); // no address and no key
        Assert.Equal(Cli.AgentsHelp, error);

        string log = _dir + "/access.log";
        File.WriteAllText(log, Line("/a", GptBot) + "\n");
        (code, _, error, _) = await RunAsync("agents", "--log", _dir + "/missing.log", "--to", "https://stats.example.com", "--key", "k");
        Assert.Equal(1, code);
        Assert.Equal("Runlight: No log at " + _dir + "/missing.log\n", error);

        // --to and --key come from config.json when they are not given.
        File.WriteAllText(_dir + "/config.json", "{\"RUNLIGHT_URL\": \"https://stats.example.com/\", \"RUNLIGHT_OBSERVE_KEY\": \"rlo_all\"}");
        (code, output, error, sent) = await RunAsync("agents", "--log", _dir + "/./access.log", "--site", "https://example.com", "--state", _dir + "/state.json");
        Assert.Equal((0, "Sent 1 AI agent fetches from 1 new lines.\n", ""), (code, output, error));
        Assert.Equal("https://stats.example.com/api/observe", sent.Requests[0].Url);
        Assert.Equal("Bearer rlo_all", sent.Requests[0].Headers.Str("authorization"));
        Assert.Equal(
            Json.Stringify(new JsObject { ["fetches"] = new List<object?> { new JsObject { ["url"] = "https://example.com/a", ["userAgent"] = GptBot, ["at"] = Utc(2026, 10, 7, 17, 55, 36) } } }),
            sent.Requests[0].Body);
        var saved = (JsObject)Json.Parse(File.ReadAllText(_dir + "/state.json"))!;
        Assert.Equal(["ino", "offset", "head", "length"], saved.Select(e => e.Key));
        Assert.Equal(new FileInfo(log).Length, saved.Long("offset"));
        if (!OperatingSystem.IsWindows())
        {
            // The log's inode, as ls -i shows it.
            var ls = Process.Start(new ProcessStartInfo("ls", ["-i", log]) { RedirectStandardOutput = true })!;
            string listed = await ls.StandardOutput.ReadToEndAsync();
            await ls.WaitForExitAsync();
            Assert.Equal(Js.Trim(listed).Split(' ')[0], Js.Str(saved.Long("ino")));
        }
        File.Delete(_dir + "/config.json");
    }
}
