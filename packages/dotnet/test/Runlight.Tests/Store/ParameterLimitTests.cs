using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Store.Seed;

namespace Runlight.Tests.Store;

/// <summary>
/// d1-limits.test.ts at the store: no statement binds more than 100 values, as Cloudflare D1
/// requires, over a year of data, on SQLite as D1 runs it and on MySQL, whose statements for the
/// same reports are written differently.
/// </summary>
public sealed class ParameterLimitTests : StoreTestCase
{
    public static Xunit.TheoryData<string> Limited() => [.. Databases.Kinds().Where(k => k != "postgres")];

    [Theory]
    [MemberData(nameof(Limited))]
    public async Task No_statement_binds_more_than_100_parameters(string kind)
    {
        var store = await StoreAsync(kind);
        // A visit every third day for a year, so a year of days can be built.
        await store.TransactionAsync(async tx =>
        {
            for (int d = 0; d < 365; d += 3)
            {
                long t = NOW - 365 * DAY + d * DAY;
                await VisitAsync(tx, "y" + d, "v" + d, t, new JsObject { ["country"] = "GB" }, [Pv("/p" + (d % 40), t, "y" + d), Ev("Goal" + (d % 30), t + 1, new JsObject { ["amount"] = (long)d })]);
            }
        });
        await BuildDaysAsync(store, "default", NOW - 366 * DAY, NOW - DAY);
        for (int g = 0; g < 30; g++)
        {
            await store.SaveGoalAsync(Goal(g.ToString("x", CultureInfo.InvariantCulture).PadLeft(24, '0'), new JsObject { ["name"] = "Goal " + g, ["match"] = "Goal" + g, ["valueMode"] = g % 2 != 0 ? "prop" : "fixed", ["value"] = 5L, ["valueProp"] = "amount" }));
        }
        var funnel = new JsObject { ["id"] = new string('f', 24), ["site"] = "default", ["name"] = "Funnel", ["steps"] = L(new JsObject { ["kind"] = "page", ["match"] = "/p1" }, new JsObject { ["kind"] = "event", ["match"] = "Goal1" }), ["createdAt"] = 0L };
        await store.SaveFunnelAsync(funnel);
        // Days not built, scattered through the last month, as late engagement or an import leaves them.
        for (int d = 2; d < 30; d += 3)
        {
            await store.ClearRollupsAsync("default", from: NOW - d * DAY, to: NOW - d * DAY + 1);
        }

        // Every statement from here on is checked.
        var watched = new WatchedDb(store.Db);
        int most = 0;
        watched.Before = (sql, parameters) =>
        {
            most = Math.Max(most, parameters.Count);
            if (parameters.Count > 100)
            {
                throw new InvalidOperationException("a statement bound " + parameters.Count + " parameters");
            }
            return Task.CompletedTask;
        };
        var view = new SqlStore(watched);
        var goals = await view.GoalsAsync("default");
        static List<JsObject> Days(long from, long to, long size)
        {
            var output = new List<JsObject>();
            for (long at = from; at < to; at += size)
            {
                output.Add(new JsObject { ["start"] = at, ["end"] = Math.Min(at + size, to) });
            }
            return output;
        }
        // As many filters as a query takes, each of the kind that binds the most.
        string[][] many = [F("page", "contains", "/P"), F("page", "contains", "é"), F("event", "contains", "goal"), F("hostname", "contains", "example"), F("page", "not", "/x"), F("country", "not", "XX")];
        // Path filters in mixed case are tried in several forms, each a value of its own.
        string[][] paths = [F("page", "contains", "/pÉ"), F("page", "contains", "/Pé"), F("page", "contains", "/xÜ"), F("page", "contains", "/üX"), F("page", "contains", "/ÉtÉ"), F("hostname", "contains", "eXa")];
        var ranges = new (long From, long To, long Size)[]
        {
            (NOW - 365 * DAY, NOW + DAY, DAY),
            (NOW - 400 * DAY, NOW + DAY, 30 * DAY),
            (NOW - 90 * DAY, NOW + DAY, DAY),
            (NOW - 30 * DAY, NOW + DAY, DAY),
            (NOW - 7 * DAY, NOW + DAY, HOUR),
        };
        foreach (var (from, to, size) in ranges)
        {
            foreach (var filters in new[] { Array.Empty<string[]>(), [F("page", "contains", "/p")], [F("country", "not", "XX")], many, paths })
            {
                var query = Q(from, to, filters);
                await view.StatsAsync(query);
                await view.SeriesAsync(query, Days(from, to, size));
                await view.HourlyAsync(query);
                await view.BreakdownAsync(query, "page", 1000, 0);
                await view.BreakdownAsync(query, "source", 1000, 0);
                await view.BreakdownAsync(query, "event", 1000, 0);
                Assert.Equal(30, (await view.GoalTotalsAllAsync(query, goals)).Count);
                foreach (var goal in new[] { goals[1], goals[2] })
                {
                    await view.GoalTotalsAsync(query, goal);
                    await view.GoalSeriesAsync(query, goal, Days(from, to, size));
                    await view.GoalBreakdownAsync(query, goal, "path");
                }
                await view.FunnelCountsAsync(query, funnel);
                await view.JourneyPagesAsync(query, 5);
                await view.EventPropKeysAsync(query, "Goal1");
                await view.EventPropValuesAsync(query, "Goal1", "amount", 10);
            }
        }
        Assert.True(most <= 100);
        Assert.True(most > 50, "the reads came close: " + most);
    }
}
