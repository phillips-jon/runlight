using System;
using System.Collections.Generic;
using System.Linq;
using Xunit;
using static Runlight.Tests.Fixtures;

namespace Runlight.Tests;

/// <summary>The TypeScript SDK's time tests, then the fixture written from it.</summary>
public sealed class TimeTests
{
    private static string Iso(long ms) => Js.IsoString(ms);

    private static long Utc(int y, int m, int d = 1, int h = 0) => Time.Utc(y, m, d, h);

    private static JsObject? Resolve(JsObject input, string zone, long now, string? firstDate = null) =>
        Time.ResolveRange(input.Str("period"), input.Str("from"), input.Str("to"), input.Str("interval"), zone, now, firstDate);

    [Fact]
    public void A_local_day_starts_at_local_midnight()
    {
        Assert.Equal("2026-06-30T23:00:00.000Z", Iso(Time.StartOf("2026-07-01", "Europe/London")));
        Assert.Equal("2026-01-15T05:00:00.000Z", Iso(Time.StartOf("2026-01-15", "America/Toronto")));
        Assert.Equal("2026-01-14T18:30:00.000Z", Iso(Time.StartOf("2026-01-15", "Asia/Kolkata")));
        Assert.Equal("2026-01-15T00:00:00.000Z", Iso(Time.StartOf("2026-01-15", "UTC")));
    }

    [Fact]
    public void The_spring_dst_change_makes_a_23_hour_day()
    {
        var range = Resolve(new JsObject { ["from"] = "2026-03-07", ["to"] = "2026-03-09" }, "America/Toronto", Utc(2026, 2, 10))!;
        var days = Time.Buckets(range, "America/Toronto");
        Assert.Equal([24L, 23L, 24L], days.Select(d => (d.Long("end") - d.Long("start")) / 3_600_000).ToArray());
    }

    [Fact]
    public void Named_periods_resolve_in_the_sites_timezone()
    {
        long now = Utc(2026, 9, 6, 2);
        Assert.Equal("2026-10-05", Time.LocalDate(now, "America/Toronto"));
        var today = Resolve(new JsObject { ["period"] = "today" }, "America/Toronto", now)!;
        Assert.Equal("2026-10-05", today.Str("fromDate"));
        Assert.Equal("hour", today.Str("interval"));
        var lastMonth = Resolve(new JsObject { ["period"] = "last_month" }, "UTC", now)!;
        Assert.Equal("2026-09-01", lastMonth.Str("fromDate"));
        Assert.Equal("2026-09-30", lastMonth.Str("toDate"));
        Assert.Null(Resolve(new JsObject { ["period"] = "nope" }, "UTC", now));
        Assert.Null(Resolve(new JsObject { ["from"] = "2026-02-30", ["to"] = "2026-03-01" }, "UTC", now));
    }

    [Fact]
    public void A_day_whose_midnight_is_skipped_by_the_clocks_begins_when_they_land()
    {
        foreach (var (date, zone, start) in new[]
        {
            ("2026-09-06", "America/Santiago", "2026-09-06T04:00:00.000Z"),
            ("2026-03-08", "America/Havana", "2026-03-08T05:00:00.000Z"),
            ("2026-03-29", "Atlantic/Azores", "2026-03-29T01:00:00.000Z"),
        })
        {
            long at = Time.StartOf(date, zone);
            Assert.Equal(start, Iso(at));
            Assert.Equal(date, Time.LocalDate(at, zone));
            Assert.NotEqual(date, Time.LocalDate(at - 1, zone));
        }
    }

    /// <summary>
    /// ICU's System V zones with summer time keep the United States rules of their day, which no
    /// zone in the system's database has; their names are taken, and they follow today's rules here.
    /// </summary>
    private static readonly string[] SystemVSummer = ["systemv/ast4adt", "systemv/est5edt", "systemv/cst6cdt", "systemv/mst7mdt", "systemv/pst8pdt", "systemv/yst9ydt"];

    /// <summary>
    /// The fixture came from Node's ICU with time zone data 2025c; the zones here are read from the
    /// system's database, which is newer where the rules changed since (Morocco from 2026, and
    /// British Columbia and Alberta keeping summer time), so those zones are left out of the
    /// comparisons. Regenerate the fixture to bring them back.
    /// </summary>
    private static readonly string[] NewerData =
    [
        "Africa/Casablanca", "Africa/El_Aaiun", "America/Vancouver", "America/Edmonton", "America/Inuvik", "America/Yellowknife",
        "Canada/Mountain", "Canada/Pacific", "America/Dawson_Creek", "America/Fort_Nelson", "America/Creston",
        "Mountain", "Pacific", "MST7MDT", "PST8PDT",
    ];

    private static bool Newer(string zone) => NewerData.Contains(zone, StringComparer.OrdinalIgnoreCase);

    [Fact]
    public void Zones()
    {
        var fixture = Load("time");
        var failures = new List<string>();
        // Before 1970 ICU follows the database's backzone history; the system's has only the links.
        var times = fixture.Arr("sampleTimes")!.Select(t => (long)Js.Num(t)).ToList();
        foreach (JsObject zone in fixture.Arr("zones")!)
        {
            string name = zone.Str("name")!;
            bool valid = Time.IsTimezone(name);
            if (valid != zone.Bool("valid"))
            {
                failures.Add(name + (valid ? " taken" : " refused"));
                continue;
            }
            if (!valid || SystemVSummer.Contains(name.ToLowerInvariant()) || Newer(name))
            {
                continue;
            }
            var local = zone.Arr("local")!;
            for (int i = 0; i < times.Count; i++)
            {
                if (times[i] < 0)
                {
                    continue;
                }
                var (weekday, hour) = Time.LocalWeekdayHour(times[i], name);
                string got = Time.LocalDate(times[i], name) + " " + weekday + " " + hour;
                if (got != (string)local[i]!)
                {
                    failures.Add(name + " at " + times[i] + ": " + got + " not " + local[i]);
                }
            }
        }
        Assert.True(fixture.Arr("zones")!.Count > 600);
        NoFailures(failures);
    }

    /// <summary>
    /// The old names the time zone database made links in 2024b read as those links, as ICU reads them, even
    /// where the system builds them as zones of their own (Ubuntu's WET kept to UTC in 1970, while Lisbon was an
    /// hour ahead).
    /// </summary>
    [Theory]
    [InlineData("WET", 0L, "1970-01-01 3 1")]
    [InlineData("wet", 15638400000L, "1970-07-01 2 1")]
    [InlineData("CET", 0L, "1970-01-01 3 1")]
    [InlineData("EST", 0L, "1969-12-31 2 19")]
    [InlineData("MST", 15638400000L, "1970-06-30 1 17")]
    public void Linked_legacy_zones_read_as_their_links(string zone, long ts, string want)
    {
        Assert.True(Time.IsTimezone(zone));
        var (weekday, hour) = Time.LocalWeekdayHour(ts, zone);
        Assert.Equal(want, Time.LocalDate(ts, zone) + " " + weekday + " " + hour);
    }

    [Fact]
    public void Instants_around_every_offset_change()
    {
        var failures = new List<string>();
        var instants = Load("time").Arr("instants")!;
        foreach (List<object?> c in instants)
        {
            string zone = (string)c[0]!;
            long ts = (long)Js.Num(c[1]);
            if (Newer(zone))
            {
                continue;
            }
            var (weekday, hour) = Time.LocalWeekdayHour(ts, zone);
            string got = Time.LocalDate(ts, zone) + " " + weekday + " " + hour;
            string want = c[2] + " " + Js.String(c[3]) + " " + Js.String(c[4]);
            if (got != want)
            {
                failures.Add(zone + " " + ts + ": " + got + " not " + want);
            }
        }
        Assert.True(instants.Count > 10000);
        NoFailures(failures, 30);
    }

    [Fact]
    public void Day_starts()
    {
        var fixture = Load("time");
        var failures = new List<string>();
        foreach (List<object?> c in fixture.Arr("starts")!)
        {
            if (Newer((string)c[0]!))
            {
                continue;
            }
            long got = Time.StartOf((string)c[1]!, (string)c[0]!, (long)Js.Num(c[2]));
            if (got != (long)Js.Num(c[3]))
            {
                failures.Add(c[0] + " " + c[1] + " " + Js.String(c[2]) + ": " + got + " not " + Js.String(c[3]));
            }
        }
        foreach (List<object?> c in fixture.Arr("dayStarts")!)
        {
            string zone = (string)c[0]!;
            long year = (long)Js.Num(c[1]);
            if (Newer(zone))
            {
                continue;
            }
            var days = new List<object?>();
            string end = (year + 1) + "-01-01";
            for (string d = year + "-01-01"; string.CompareOrdinal(d, end) < 0; d = Time.AddDays(d, 1))
            {
                days.Add(Time.StartOf(d, zone));
            }
            if (Hash.Sha256(Json.Stringify(days)) != (string)c[2]!)
            {
                failures.Add(zone + " " + year + ": every day's start");
            }
        }
        NoFailures(failures, 30);
    }

    [Fact]
    public void Date_math()
    {
        var fixture = Load("time");
        long[] plus = [-400, -366, -365, -31, -1, 0, 1, 28, 29, 31, 365, 366, 1000];
        long[] months = [-25, -12, -11, -1, 0, 1, 11, 12, 13];
        foreach (JsObject c in fixture.Arr("dates")!)
        {
            string date = c.Str("date")!;
            Assert.True(c.Bool("isDate") == Time.IsDate(date), date);
            if (c.Get("plus") != null)
            {
                Assert.Equal(J(c.Get("plus")), J(plus.Select(n => Time.AddDays(date, n)).ToList()));
                Assert.Equal(J(c.Get("months")), J(months.Select(n => Time.AddMonths(date, n)).ToList()));
            }
        }
        Assert.Equal(J(fixture.Get("periods")), J(Time.Periods));
    }

    [Fact]
    public void Ranges_and_buckets()
    {
        var failures = new List<string>();
        var ranges = Load("time").Arr("ranges")!;
        foreach (JsObject c in ranges)
        {
            string zone = c.Str("zone")!;
            var range = Resolve(c.Obj("input")!, zone, (long)c.Num("now"), c.Str("firstDate"));
            var got = new JsObject { ["range"] = range };
            var want = new JsObject { ["range"] = c.Get("range") };
            if (range != null)
            {
                var buckets = Time.Buckets(range, zone);
                got["buckets"] = new JsObject { ["count"] = buckets.Count, ["first"] = buckets.Count > 0 ? buckets[0] : null, ["sha256"] = Hash.Sha256(Json.Stringify(buckets)) };
                want["buckets"] = c.Get("buckets");
                if (c.Has("compare"))
                {
                    var compare = new JsObject();
                    foreach (string mode in new[] { "previous", "year", "off", "custom", "nope" })
                    {
                        compare[mode] = Time.CompareRange(range, mode, zone, "2025-02-28", "2025-03-31");
                    }
                    got["compare"] = compare;
                    want["compare"] = c.Get("compare");
                }
            }
            if (J(got) != J(want))
            {
                failures.Add(Label(c) + " gave " + Label(got));
            }
        }
        Assert.True(ranges.Count > 2000);
        NoFailures(failures, 20);
    }

    [Fact]
    public void Compare_ranges()
    {
        foreach (JsObject c in Load("time").Arr("compares")!)
        {
            var custom = c.Obj("custom");
            var got = Time.CompareRange(c.Obj("range")!, c.Str("mode")!, c.Str("zone")!, custom?.Str("from"), custom?.Str("to"));
            Assert.Equal(J(c.Get("compare")), J(got));
        }
    }
}
