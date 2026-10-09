using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Runlight.Store;
using Xunit;

namespace Runlight.Tests.Store;

/// <summary>Store tests that run on every database at hand (see <see cref="Databases"/>).</summary>
public abstract class StoreTestCase : IAsyncLifetime
{
    public const long DAY = Seed.DAY;
    public const long HOUR = Seed.HOUR;
    public const long MIN = Seed.MIN;

    /// <summary>Date.UTC(2026, 9, 6, 12), the clock the TypeScript tests start from.</summary>
    public const long NOW = 1_791_288_000_000;

    public virtual ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public virtual async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    /// <summary>A fresh store with its tables and the site "default" in UTC.</summary>
    protected static async Task<SqlStore> StoreAsync(string kind, string timezone = "UTC")
    {
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        await store.UpsertSiteAsync(new JsObject { ["id"] = "default", ["name"] = "Example", ["hostnames"] = new List<object?> { "example.com" }, ["timezone"] = timezone }, NOW);
        return store;
    }

    /// <summary>A filter, as [dimension, op, value].</summary>
    protected static string[] F(string dimension, string op, string value) => [dimension, op, value];

    /// <summary>A query over a range, with filters given as [dimension, op, value].</summary>
    protected static JsObject Q(long from, long to, params string[][] filters) => new()
    {
        ["site"] = "default",
        ["from"] = from,
        ["to"] = to,
        ["filters"] = filters.Select(f => (object?)new JsObject { ["dimension"] = f[0], ["op"] = f[1], ["value"] = f[2] }).ToList(),
    };

    /// <summary>The UTC day holding NOW, as a query.</summary>
    protected static JsObject Today(params string[][] filters) => Q(NOW - 12 * HOUR, NOW + 12 * HOUR, filters);

    protected static JsObject Goal(string id, JsObject fields) => new JsObject
    {
        ["id"] = id,
        ["site"] = "default",
        ["name"] = id,
        ["kind"] = "event",
        ["match"] = "",
        ["clickBy"] = "",
        ["valueMode"] = "none",
        ["value"] = 0L,
        ["valueProp"] = "",
        ["currency"] = "USD",
        ["createdAt"] = 0L,
    }.With(fields);

    /// <summary>A list of values, as List&lt;object?&gt; the way the store and JSON hold lists.</summary>
    protected static List<object?> L(params object?[] values) => [.. values];

    /// <summary>The JSON of a value, for comparing whole answers.</summary>
    protected static string J(object? value) => Fixtures.J(value);

    /// <summary>One column of a list of rows.</summary>
    protected static List<object?> Column(IEnumerable<JsObject> rows, string key) => rows.Select(r => r.Get(key)).ToList();

    /// <summary>Asserts two values have the same JSON.</summary>
    protected static void Same(object? expected, object? actual, string? message = null) =>
        Assert.True(J(expected) == J(actual), (message == null ? "" : message + ": ") + "expected " + J(expected) + ", actual " + J(actual));
}
