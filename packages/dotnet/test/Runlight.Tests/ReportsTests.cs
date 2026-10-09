using System.Collections.Generic;
using System.Linq;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>Email reports' Intl formatting and their periods, replayed from fixtures/reports.json (the TypeScript SDK's).</summary>
public sealed class ReportsTests
{
    public static TheoryData<string> Langs() => [.. Load("reports").Arr("intl")!.Cast<JsObject>().Select(s => s.Str("lang")!)];

    private static JsObject Set(string lang) => Load("reports").Arr("intl")!.Cast<JsObject>().First(s => s.Str("lang") == lang);

    private static IEnumerable<List<object?>> Pairs(JsObject set, string key) => set.Arr(key)!.Cast<List<object?>>();

    [Theory]
    [MemberData(nameof(Langs))]
    public void Numbers_percents_and_dates_are_written_as_Intl_writes_them(string lang)
    {
        var set = Set(lang);
        var failures = new List<string>();
        void Check(string what, string got, object? want)
        {
            if (got != (string)want!)
            {
                failures.Add(lang + " " + what + ": " + got + ", want " + want);
            }
        }
        foreach (var p in Pairs(set, "number"))
        {
            Check("number " + Js.String(p[0]), Intl.Number(lang, Js.Num(p[0])), p[1]);
        }
        foreach (var p in Pairs(set, "decimal"))
        {
            Check("decimal " + Js.String(p[0]), Intl.Number(lang, Js.Num(p[0]), 1, 1), p[1]);
        }
        foreach (var p in Pairs(set, "percent"))
        {
            Check("percent " + Js.String(p[0]), Intl.Percent(lang, Js.Num(p[0])), p[1]);
        }
        foreach (var p in Pairs(set, "monthYear"))
        {
            Check("monthYear " + p[0], Intl.MonthYear(lang, (string)p[0]!), p[1]);
        }
        foreach (var p in Pairs(set, "shortDay"))
        {
            Check("shortDay " + p[0], Intl.ShortDay(lang, (string)p[0]!, false), p[1]);
            Check("shortDay year " + p[0], Intl.ShortDay(lang, (string)p[0]!, true), p[2]);
        }
        NoFailures(failures);
    }

    [Theory]
    [MemberData(nameof(Langs))]
    public void Currencies_and_region_names_are_Nodes(string lang)
    {
        var set = Set(lang);
        var failures = new List<string>();
        foreach (var p in Pairs(set, "currency"))
        {
            double n = Js.Num(p[0]);
            string got = Intl.Currency(lang, n, (string)p[1]!, Js.IsInteger(n) ? 0 : 2);
            if (got != (string)p[2]!)
            {
                failures.Add(lang + " " + Js.String(p[0]) + " " + p[1] + ": " + got + ", want " + p[2]);
            }
        }
        foreach (var p in Pairs(set, "region"))
        {
            string got = Intl.Region(lang, (string)p[0]!);
            if (got != (string)p[1]!)
            {
                failures.Add(lang + " region " + p[0] + ": " + got + ", want " + p[1]);
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Report_periods_match_for_every_zone_and_frequency()
    {
        var failures = new List<string>();
        foreach (JsObject c in Load("reports").Arr("periods")!)
        {
            string got = J(Reports.LastPeriod(c.Str("frequency")!, (long)c.Num("now"), c.Str("zone")!));
            if (got != J(c.Get("period")))
            {
                failures.Add(Label(c) + ": " + got);
            }
        }
        NoFailures(failures);
    }

    [Fact]
    public void Report_periods_are_last_Monday_to_Sunday_or_last_month_due_from_8am_the_day_after_in_the_sites_zone()
    {
        // Wednesday 8 October 2026, 15:00 UTC (11:00 in Toronto).
        long now = Time.Utc(2026, 9, 8, 15);
        var week = Reports.LastPeriod("weekly", now, "America/Toronto");
        Assert.Equal(["w:2026-09-28", "2026-09-28", "2026-10-04", "2026-09-21"], new[] { week.Str("key"), week.Str("fromDate"), week.Str("toDate"), week.Str("previousFrom") });
        Assert.Equal(Time.Utc(2026, 9, 5, 12), week.Get("dueAt")); // Monday 5 October, 8am Toronto
        var month = Reports.LastPeriod("monthly", now, "America/Toronto");
        Assert.Equal(["m:2026-09", "2026-09-01", "2026-09-30", "2026-08-01", "2026-08-31"], new[] { month.Str("key"), month.Str("fromDate"), month.Str("toDate"), month.Str("previousFrom"), month.Str("previousTo") });
        long early = Time.Utc(2026, 9, 5, 7);
        Assert.True(early < (long)Reports.LastPeriod("weekly", early, "America/Toronto").Get("dueAt")!);
    }
}
