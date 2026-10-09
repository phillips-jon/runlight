using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Store;

namespace Runlight.Tests.Store;

/// <summary>
/// Visits written through the store as the tracker writes them (a session, then its rows, each
/// counted into the session), for store tests that cannot go through the Runlight core yet.
/// </summary>
public static class Seed
{
    public const long DAY = 86_400_000;
    public const long HOUR = 3_600_000;
    public const long MIN = 60_000;

    /// <summary>A pageview row: path, ts, pageview id, and optionally its hostname.</summary>
    public static object?[] Pv(string path, long ts, string pageview, string? hostname = null) =>
        hostname == null ? ["pageview", path, ts, pageview] : ["pageview", path, ts, pageview, hostname];

    /// <summary>An event row: name, ts, props or null, and optionally the path it was sent from.</summary>
    public static object?[] Ev(string name, long ts, JsObject? props, string? path = null) =>
        path == null ? ["event", name, ts, props] : ["event", name, ts, props, path];

    /// <summary>An engagement row: pageview id, ts, engaged ms, and scroll or null.</summary>
    public static object?[] Eng(string pageview, long ts, long ms, long? scroll) => ["engagement", pageview, ts, ms, scroll];

    /// <summary>
    /// A session with its fields, then its rows in order (see <see cref="Pv"/>, <see cref="Ev"/>,
    /// and <see cref="Eng"/>).
    /// </summary>
    public static async Task VisitAsync(SqlStore store, string id, string visitor, long startedAt, JsObject? fields = null, IReadOnlyList<object?[]>? rows = null, string site = "default")
    {
        fields ??= [];
        var session = new JsObject
        {
            ["id"] = id,
            ["site"] = site,
            ["visitor"] = visitor,
            ["startedAt"] = startedAt,
            ["hostname"] = "example.com",
            ["referrerHost"] = "",
            ["referrerPath"] = "",
            ["source"] = "",
            ["channel"] = "Direct",
            ["utmSource"] = "",
            ["utmMedium"] = "",
            ["utmCampaign"] = "",
            ["utmTerm"] = "",
            ["utmContent"] = "",
            ["country"] = "",
            ["region"] = "",
            ["city"] = "",
            ["browser"] = "Chrome",
            ["browserVersion"] = "129",
            ["os"] = "macOS",
            ["osVersion"] = "",
            ["device"] = "Desktop",
            ["screen"] = "",
            ["language"] = "en",
        }.With(fields);
        await store.InsertSessionAsync(session);
        var paths = new Dictionary<string, string>(StringComparer.Ordinal);
        string last = "/";
        string hostname = fields.Str("hostname") ?? "example.com";
        foreach (var row in rows ?? [])
        {
            var evt = new JsObject
            {
                ["site"] = site,
                ["visitor"] = visitor,
                ["session"] = id,
                ["pageview"] = "",
                ["path"] = last,
                ["hostname"] = hostname,
                ["title"] = "",
                ["name"] = "",
                ["props"] = null,
                ["engagedMs"] = 0L,
                ["scroll"] = null,
                ["link"] = "",
            };
            if ((string)row[0]! == "pageview")
            {
                string path = (string)row[1]!;
                long ts = (long)row[2]!;
                string pv = (string)row[3]!;
                paths[pv] = path;
                last = path;
                string title = "Title " + path;
                await store.InsertEventAsync(evt.With(new JsObject
                {
                    ["ts"] = ts,
                    ["kind"] = "pageview",
                    ["pageview"] = pv,
                    ["path"] = path,
                    ["hostname"] = row.Length > 4 ? row[4] : hostname,
                    // mb_substr counts code points.
                    ["title"] = CodePoints(title, 500),
                }));
                await store.TouchSessionAsync(id, ts, "pageview", path);
            }
            else if ((string)row[0]! == "event")
            {
                long ts = (long)row[2]!;
                string path = row.Length > 4 ? (string)row[4]! : last;
                await store.InsertEventAsync(evt.With(new JsObject { ["ts"] = ts, ["kind"] = "event", ["name"] = row[1], ["props"] = row[3], ["path"] = path }));
                await store.TouchSessionAsync(id, ts, "event", path);
            }
            else
            {
                string pv = (string)row[1]!;
                long ts = (long)row[2]!;
                long ms = (long)row[3]!;
                await store.InsertEventAsync(evt.With(new JsObject
                {
                    ["ts"] = ts,
                    ["kind"] = "engagement",
                    ["pageview"] = pv,
                    ["path"] = paths.TryGetValue(pv, out string? p) ? p : last,
                    ["engagedMs"] = ms,
                    ["scroll"] = row[4],
                }));
                await store.AddEngagementAsync(id, ms);
            }
        }
    }

    /// <summary>The first <paramref name="n"/> code points of a string.</summary>
    private static string CodePoints(string s, int n)
    {
        int count = 0;
        int i = 0;
        while (i < s.Length && count < n)
        {
            i += char.IsSurrogatePair(s, i) ? 2 : 1;
            count++;
        }
        return s[..i];
    }

    /// <summary>The UTC date of a time, as yyyy-MM-dd.</summary>
    public static string Date(long ms, string format = "yyyy-MM-dd") =>
        DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString(format, CultureInfo.InvariantCulture);

    /// <summary>Epoch ms of a UTC date and time.</summary>
    public static long Utc(int year, int month, int day, int hour = 0) =>
        new DateTimeOffset(year, month, day, hour, 0, 0, TimeSpan.Zero).ToUnixTimeMilliseconds();

    /// <summary>
    /// A site's days built as the core builds them, a UTC day at a time, for every whole day before
    /// <paramref name="before"/>.
    /// </summary>
    public static async Task<int> BuildDaysAsync(SqlStore store, string site, long from, long before)
    {
        int built = 0;
        for (long day = from / DAY * DAY; day + DAY <= before; day += DAY)
        {
            await store.BuildRollupDayAsync(site, Date(day), day, day + DAY);
            built++;
        }
        return built;
    }

    private static JsObject Call(string method, params object?[] args) => new() { ["method"] = method, ["args"] = args.ToList() };

    private static JsObject Filter(string dimension, string op, string value) => new() { ["dimension"] = dimension, ["op"] = op, ["value"] = value };

    /// <summary>A database with a bit of everything, written through the .NET store, and the reads to compare over it.</summary>
    public static async Task<List<JsObject>> EverythingAsync(SqlStore store)
    {
        await store.MigrateAsync();
        long now = Utc(2026, 10, 6, 12);
        await store.UpsertSiteAsync(new JsObject { ["id"] = "default", ["name"] = "Example", ["hostnames"] = new List<object?> { "example.com" }, ["timezone"] = "UTC" }, now);
        await store.UpsertSiteAsync(new JsObject { ["id"] = "b", ["name"] = "Bee", ["hostnames"] = new List<object?>(), ["timezone"] = "Asia/Tokyo" }, now);
        await store.SetSiteOverridesAsync("b", new JsObject { ["name"] = "Renamed" });
        string[] pages = ["/", "/pricing", "/blog/one", "/caf%C3%A9", "/%C3%9Cber-uns", "/thanks", "/#/cart"];
        string[] countries = ["GB", "US", "DE", "FR"];
        string[] campaigns = ["alpha", "Zeta", "émile", "Émile", "a-b", "ab", ""];
        int n = 0;
        for (int day = 9; day >= 0; day--)
        {
            for (int v = 0; v < 5; v++)
            {
                n++;
                long start = now - day * DAY - 10 * HOUR + v * 2 * HOUR + n * 1000L;
                var rows = new List<object?[]>();
                long t = start;
                for (int p = 0; p < 1 + n % 3; p++)
                {
                    rows.Add(Pv(pages[(n + p) % pages.Length], t, "pv" + n + "x" + p));
                    if (n % 2 == 0)
                    {
                        rows.Add(Eng("pv" + n + "x" + p, t + 5000, 8000 + n * 100L, n % 3 != 0 ? 30 + n % 50 : null));
                    }
                    if (n % 3 == 0)
                    {
                        rows.Add(Ev("Signup", t + 6000, new JsObject { ["plan"] = n % 2 != 0 ? "pro" : "team", ["amount"] = (5 + n % 4).ToString(CultureInfo.InvariantCulture) + ".5" }));
                    }
                    t += 30_000;
                }
                await VisitAsync(store, "s" + n, "v" + (n % 17), start, new JsObject
                {
                    ["country"] = countries[n % 4],
                    ["source"] = n % 2 != 0 ? "Google" : "",
                    ["channel"] = n % 2 != 0 ? "Search" : "Direct",
                    ["utmCampaign"] = campaigns[n % campaigns.Length],
                    ["device"] = n % 3 != 0 ? "Desktop" : "Mobile",
                    ["browser"] = n % 4 != 0 ? "Chrome" : "Safari",
                }, rows);
            }
        }
        string R(char c, int k) => new(c, k);
        await store.SaveGoalAsync(new JsObject { ["id"] = R('a', 24), ["site"] = "default", ["name"] = "Signup", ["kind"] = "event", ["match"] = "Signup", ["clickBy"] = "", ["valueMode"] = "prop", ["value"] = 0L, ["valueProp"] = "amount", ["currency"] = "USD", ["createdAt"] = now });
        await store.SaveGoalAsync(new JsObject { ["id"] = R('b', 24), ["site"] = "default", ["name"] = "Thanks", ["kind"] = "page", ["match"] = "/th*", ["clickBy"] = "", ["valueMode"] = "fixed", ["value"] = 4.25, ["valueProp"] = "", ["currency"] = "EUR", ["createdAt"] = now });
        await store.SaveGoalAsync(new JsObject { ["id"] = R('c', 24), ["site"] = "default", ["name"] = "Cart", ["kind"] = "page", ["match"] = "/#/cart", ["clickBy"] = "", ["valueMode"] = "none", ["value"] = 0L, ["valueProp"] = "", ["currency"] = "USD", ["createdAt"] = now });
        await store.SaveFunnelAsync(new JsObject
        {
            ["id"] = R('f', 24),
            ["site"] = "default",
            ["name"] = "F",
            ["steps"] = new List<object?> { new JsObject { ["kind"] = "page", ["match"] = "/" }, new JsObject { ["kind"] = "page", ["match"] = "/pricing" }, new JsObject { ["kind"] = "event", ["match"] = "Signup" } },
            ["createdAt"] = now,
        });
        await store.InsertLinkAsync(new JsObject { ["id"] = R('l', 24), ["site"] = "default", ["domain"] = "", ["slug"] = "go", ["name"] = "Go", ["url"] = "https://example.com/", ["createdAt"] = now - DAY, ["updatedAt"] = now - DAY });
        await store.AddLinkDomainAsync("go.example.com", "default", now);
        for (int i = 0; i < 6; i++)
        {
            await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = now - i * 7 * HOUR, ["kind"] = "click", ["visitor"] = i % 2 != 0 ? "cv" + i : "", ["session"] = "", ["pageview"] = "", ["path"] = "", ["hostname"] = "", ["title"] = "", ["name"] = "", ["props"] = null, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = R('l', 24) });
            await store.InsertEventAsync(new JsObject { ["site"] = "default", ["ts"] = now - i * 5 * HOUR, ["kind"] = "fetch", ["visitor"] = "", ["session"] = "", ["pageview"] = "", ["path"] = pages[i % 3], ["hostname"] = "example.com", ["title"] = "", ["name"] = i % 2 != 0 ? "GPTBot" : "ClaudeBot", ["props"] = new JsObject { ["company"] = "X" }, ["engagedMs"] = 0L, ["scroll"] = null, ["link"] = "" });
        }
        await store.InsertShareAsync(new JsObject { ["id"] = R('s', 24), ["site"] = "default", ["name"] = "Client", ["createdAt"] = now });
        await store.InsertTokenAsync(new JsObject { ["id"] = R('k', 24), ["name"] = "Script", ["site"] = "", ["scope"] = "manage", ["hash"] = R('h', 64), ["hint"] = "abcd", ["createdAt"] = now, ["lastUsedAt"] = null });
        await store.InsertReportAsync(new JsObject { ["id"] = R('r', 24), ["site"] = "default", ["email"] = "a@example.com", ["frequency"] = "weekly", ["lang"] = "en", ["token"] = R('q', 32), ["origin"] = "", ["lastPeriod"] = "", ["lastSentAt"] = null, ["createdAt"] = now });
        await store.SetSettingAsync("remote:a", "1");
        await store.SaltAsync("2026-10-06", R('9', 64));
        await BuildDaysAsync(store, "default", now - 7 * DAY, now - 3 * DAY);

        var calls = new List<JsObject>
        {
            Call("sites"),
            Call("siteOverrides"),
            Call("rollupDays", "default"),
        };
        List<object?>[] filters =
        [
            [],
            [Filter("country", "is", "GB")],
            [Filter("page", "contains", "über")],
            [Filter("event", "not", "Signup")],
            [Filter("utm_campaign", "contains", "ÉMILE")],
        ];
        var goals = await store.GoalsAsync("default");
        var funnels = await store.FunnelsAsync("default");
        foreach (var (from, to) in new[] { (now - 8 * DAY, now + DAY), (now - 5 * DAY - 3 * HOUR, now - DAY) })
        {
            foreach (var f in filters)
            {
                var query = new JsObject { ["site"] = "default", ["from"] = from, ["to"] = to, ["filters"] = f };
                calls.Add(Call("stats", query));
                calls.Add(Call("hourly", query));
                foreach (string dimension in new[] { "page", "hostname", "event", "entry", "exit", "source", "channel", "utm_campaign", "country", "device", "browser", "ai_agent", "ai_page" })
                {
                    calls.Add(Call("breakdown", query, dimension, 5L, 0L));
                }
                calls.Add(Call("goalTotalsAll", query, goals.Cast<object?>().ToList()));
                calls.Add(Call("funnelCounts", query, funnels[0]));
                calls.Add(Call("journeyPages", query, 3L));
                calls.Add(Call("eventPropKeys", query, "Signup"));
                calls.Add(Call("eventPropValues", query, "Signup", "plan", 5L));
                foreach (var g in goals)
                {
                    calls.Add(Call("goalBreakdown", query, g, "path", 5L));
                }
            }
            calls.Add(Call("links", "default", from, to));
        }
        var buckets = new List<object?>();
        for (int i = 0; i < 12; i++)
        {
            buckets.Add(new JsObject { ["start"] = now - (11 - i) * DAY, ["end"] = now - (10 - i) * DAY });
        }
        foreach (var f in filters)
        {
            calls.Add(Call("series", new JsObject { ["site"] = "default", ["filters"] = f }, buckets));
            calls.Add(Call("goalSeries", new JsObject { ["site"] = "default", ["filters"] = f }, goals[0], buckets));
        }
        calls.Add(Call("linkSeries", "default", R('l', 24), buckets));
        calls.Add(Call("realtime", "default", now - 9 * HOUR));
        calls.Add(Call("goals"));
        calls.Add(Call("funnels", "default"));
        calls.Add(Call("linkBySlug", "go"));
        calls.Add(Call("linkDomains"));
        calls.Add(Call("shares", "default"));
        calls.Add(Call("tokens"));
        calls.Add(Call("reports"));
        calls.Add(Call("settingsStartingWith", "remote:"));
        calls.Add(Call("saltIfExists", "2026-10-06"));
        calls.Add(Call("pageview", "default", "pv3x1"));
        return calls;
    }
}
