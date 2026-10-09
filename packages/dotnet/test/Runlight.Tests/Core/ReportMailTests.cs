using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Http;
using Runlight.Mail;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests.Core;

/// <summary>The mail service's settings and the reports sent through it, as mail.test.ts and audit.test.ts test them without routes.</summary>
public sealed class ReportMailTests : CoreTestCase
{
    private const string Agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

    private readonly FakeFetcher _fetcher;
    private int _status = 200;
    private long _now;

    public ReportMailTests() => _fetcher = new FakeFetcher((_, _) => new Response(_status == 200 ? "{}" : "nope", _status));

    private async Task<Runlight> RunlightAsync(SiteOptions? site = null, string? secret = null, JsObject? mail = null) =>
        new(new RunlightOptions { Store = await Databases.FreshAsync("sqlite"), Now = () => _now, Fetcher = _fetcher, Site = site, Secret = secret, Mail = mail });

    /// <summary>A report as the routes add one: a period already due counts as sent.</summary>
    private static async Task AddReportAsync(Runlight rl, string email, string frequency, string lang = "en", string origin = "https://stats.example.com/runlight")
    {
        var site = rl.Site("default")!;
        var due = Reports.LastPeriod(frequency, rl.Now(), site.Str("timezone")!);
        await rl.Store.InsertReportAsync(new JsObject
        {
            ["id"] = Hash.RandomId(),
            ["site"] = "default",
            ["email"] = email,
            ["frequency"] = frequency,
            ["lang"] = lang,
            ["token"] = Hash.RandomId(16),
            ["origin"] = origin,
            ["lastPeriod"] = rl.Now() >= due.Long("dueAt") ? due.Get("key") : "",
            ["lastSentAt"] = null,
            ["createdAt"] = rl.Now(),
        });
    }

    private static Task<MailError> Refused(Func<Task> fn, string code) => Refused<MailError>(fn, code);

    private JsObject Body(int i) => (JsObject)Json.Parse(_fetcher.Requests[i].Body!)!;

    [Fact]
    public async Task Reports_go_out_once_per_period_retry_after_a_failure_and_keep_keys_from_the_browser()
    {
        _now = Utc(2026, 10, 8, 15);
        var rl = await RunlightAsync(new SiteOptions { Name = "Example", Hostnames = ["example.com"], Timezone = "America/Toronto" }, "s3cret");
        await rl.InitAsync();

        var badFrom = await Refused(() => rl.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "re_live_key", ["from"] = "not an address" }), "mail_from");
        Assert.Equal("{}", J(badFrom.Params));
        var noKey = await Refused(() => rl.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "", ["from"] = "reports@example.com" }), "mail_field");
        Assert.Equal("{\"field\":\"apiKey\"}", J(noKey.Params));
        await Refused(() => rl.SaveMailSettingsAsync(new JsObject { ["service"] = "pigeon" }), "mail_service");
        await rl.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "re_live_key", ["from"] = "reports@example.com", ["fromName"] = "Runlight" });
        string stored = (await rl.Store.SettingAsync("mail"))!;
        Assert.StartsWith("v1:", stored, StringComparison.Ordinal);
        Assert.DoesNotContain("re_live_key", stored, StringComparison.Ordinal); // the key is encrypted at rest
        Assert.Equal("{\"service\":\"resend\",\"apiKey\":\"re_live_key\",\"from\":\"reports@example.com\",\"fromName\":\"Runlight\",\"source\":\"dashboard\"}", J(await rl.MailSettingsAsync()));
        // Saving again with the key left blank keeps it.
        await rl.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "", ["from"] = "reports@example.com" });
        Assert.Equal("re_live_key", (await rl.MailSettingsAsync())!.Str("apiKey"));

        await AddReportAsync(rl, "jon@example.com", "weekly", "fr");
        Assert.Equal("{\"sent\":0,\"failed\":0}", J(await rl.SendReportsAsync())); // a report added on a Wednesday waits for the next Monday
        Assert.Empty(_fetcher.Requests);
        _now += 7 * DAY;
        _status = 500;
        Assert.Equal("{\"sent\":0,\"failed\":1}", J(await rl.SendReportsAsync()));
        _status = 200;
        _fetcher.Requests.Clear();
        Assert.Equal("{\"sent\":1,\"failed\":0}", J(await rl.SendReportsAsync())); // a failed send is tried again
        var body = Body(0);
        Assert.Equal("https://api.resend.com/emails", _fetcher.Requests[0].Url);
        Assert.Equal("jon@example.com", body.Arr("to")![0]);
        Assert.Equal("Example : 0 personne la semaine dernière", body.Str("subject"));
        Assert.Contains("du 5 oct. au 11 oct. 2026", body.Str("html"), StringComparison.Ordinal);
        Assert.Contains("0 personne a visité le site la semaine dernière.", body.Str("html"), StringComparison.Ordinal); // French counts zero as one
        Assert.Matches(new Regex("^<https://stats\\.example\\.com/runlight/unsubscribe/[a-f0-9]{32}>$"), body.Obj("headers")!.Str("List-Unsubscribe")!);
        Assert.Equal("List-Unsubscribe=One-Click", body.Obj("headers")!.Str("List-Unsubscribe-Post"));
        Assert.Contains("https://stats.example.com/runlight/?site=default", body.Str("text"), StringComparison.Ordinal);
        Assert.Equal("{\"sent\":0,\"failed\":0}", J(await rl.SendReportsAsync())); // the same period never goes twice
        _now += 7 * DAY;
        Assert.Equal("{\"sent\":1,\"failed\":0}", J(await rl.SendReportsAsync())); // the next week does
        Assert.Equal("{\"ok\":true,\"reports\":{\"sent\":0,\"failed\":0}}", J(await rl.CheckAsync()));
    }

    [Fact]
    public async Task A_report_added_before_Mondays_8am_still_gets_last_weeks()
    {
        // Monday 5 October 2026, 7:00 in Toronto: last week is over and not yet due.
        _now = Utc(2026, 10, 5, 11);
        var rl = await RunlightAsync(new SiteOptions { Name = "Example", Hostnames = ["example.com"], Timezone = "America/Toronto" });
        await rl.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "re_1", ["from"] = "reports@example.com" });
        await AddReportAsync(rl, "jon@example.com", "weekly");
        await AddReportAsync(rl, "jon@example.com", "monthly");
        Assert.Equal("{\"sent\":0,\"failed\":0}", J(await rl.SendReportsAsync()));
        _now += 2 * HOUR;
        Assert.Equal("{\"sent\":1,\"failed\":0}", J(await rl.SendReportsAsync()));
        Assert.Contains("last week", Body(0).Str("subject"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task No_mail_service_sends_nothing_and_saying_so_is_an_error()
    {
        _now = Utc(2026, 10, 12, 15);
        var rl = await RunlightAsync();
        await rl.InitAsync();
        await AddReportAsync(rl, "jon@example.com", "weekly");
        await rl.Store.Db.RunAsync("UPDATE rl_reports SET last_period = ''");
        Assert.Equal("{\"sent\":0,\"failed\":0}", J(await rl.SendReportsAsync()));
        await Refused(() => rl.SendMailAsync(new JsObject { ["to"] = "a@b.co", ["subject"] = "s", ["html"] = "h", ["text"] = "t" }), "mail_unset");
    }

    [Fact]
    public async Task A_mail_service_in_code_is_shown_and_cannot_be_changed()
    {
        var rl = await RunlightAsync(mail: new JsObject { ["service"] = "resend", ["apiKey"] = "re_code", ["from"] = "r@example.com" });
        Assert.Equal("{\"service\":\"resend\",\"apiKey\":\"re_code\",\"from\":\"r@example.com\",\"source\":\"code\"}", J(await rl.MailSettingsAsync()));
        await Refused(() => rl.SaveMailSettingsAsync(null), "mail_in_code");
        await rl.SendMailAsync(new JsObject { ["to"] = "jon@example.com", ["subject"] = "Hi", ["html"] = "<p>Hi</p>", ["text"] = "Hi" });
        Assert.Equal("r@example.com", Body(0).Str("from"));
    }

    [Fact]
    public async Task A_saved_SMTP_password_is_kept_only_while_the_server_it_goes_to_stays_the_same()
    {
        var rl = await RunlightAsync(secret: new string('k', 32));
        JsObject Base() => new() { ["service"] = "smtp", ["host"] = "smtp.example.com", ["port"] = "587", ["security"] = "starttls", ["username"] = "me", ["from"] = "r@example.com" };
        await rl.SaveMailSettingsAsync(Base().With(new JsObject { ["password"] = "hunter2-long" }));
        await rl.SaveMailSettingsAsync(Base().With(new JsObject { ["password"] = "", ["from"] = "reports@example.com" }));
        Assert.Equal("hunter2-long", (await rl.MailSettingsAsync())!.Str("password")); // same server, blank field: kept
        await rl.SaveMailSettingsAsync(Base().With(new JsObject { ["host"] = "evil.example", ["password"] = "", ["from"] = "reports@example.com" }));
        Assert.Equal("", (await rl.MailSettingsAsync())!.Str("password") ?? ""); // a new host needs the password typed again
        await rl.SaveMailSettingsAsync(null);
        Assert.Null(await rl.MailSettingsAsync());
    }

    [Fact]
    public async Task A_key_sealed_with_another_secret_reads_as_no_mail_service()
    {
        var store = await Databases.FreshAsync("sqlite");
        var one = new Runlight(new RunlightOptions { Store = store, Secret = "one" });
        await one.SaveMailSettingsAsync(new JsObject { ["service"] = "resend", ["apiKey"] = "re_1", ["from"] = "r@example.com" });
        var two = new Runlight(new RunlightOptions { Store = store, Secret = "two" });
        Assert.Null(await two.MailSettingsAsync());
    }

    public static TheoryData<string> Cases() => [.. Load("reports").Arr("cases")!.Cast<JsObject>().Select(c => c.Str("name")!)];

    [Theory]
    [MemberData(nameof(Cases))]
    public async Task Reports_render_as_the_TypeScript_SDK_renders_them_in_every_language(string name)
    {
        var c = Load("reports").Arr("cases")!.Cast<JsObject>().First(x => x.Str("name") == name);
        long now = 0;
        var rl = new Runlight(new RunlightOptions
        {
            Store = await Databases.FreshAsync("sqlite"),
            Site = new SiteOptions { Name = "Example & Co", Hostnames = ["example.com"], Timezone = c.Str("timezone") },
            Now = () => now,
        });
        await rl.InitAsync();
        foreach (JsObject goal in c.Arr("goals")!)
        {
            await rl.Store.SaveGoalAsync(goal);
        }
        foreach (JsObject hit in c.Arr("hits")!)
        {
            now = hit.Long("at");
            var headers = new Headers { ["user-agent"] = Agent, ["x-forwarded-for"] = hit.Str("ip")! };
            if (hit.Str("country") != "")
            {
                headers.Set("x-vercel-ip-country", hit.Str("country")!);
            }
            await rl.CollectAsync(new Request("https://example.com/runlight/e", "POST", headers, Json.Stringify(hit.Get("body"))));
        }
        now = c.Long("at");
        var site = rl.Site("default")!;
        var failures = new System.Collections.Generic.List<string>();
        foreach (JsObject expected in c.Arr("reports")!)
        {
            string label = name + ", " + expected.Str("lang") + " " + expected.Str("frequency");
            Assert.Equal(J(expected.Get("period")), J(Reports.LastPeriod(expected.Str("frequency")!, now, c.Str("timezone")!)));
            var report = await Reports.BuildReportAsync(rl.Store, site, expected.Str("frequency")!, expected.Obj("period")!, expected.Str("lang")!, expected.Obj("links")!);
            foreach (string key in new[] { "subject", "text", "html" })
            {
                if (report.Str(key) != expected.Str(key))
                {
                    failures.Add(label + " " + key + ": " + report.Str(key));
                }
            }
        }
        NoFailures(failures);
    }
}
