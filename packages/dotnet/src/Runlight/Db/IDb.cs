using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Db;

/// <summary>
/// The little a store needs from a database. SQL uses <c>?</c> placeholders on every dialect. Rows
/// come back as objects keyed by column name, numbers as long or double, so the store reads what
/// it needs as JavaScript's Number() would.
/// </summary>
public interface IDb : IAsyncDisposable
{
    /// <summary>"sqlite", "postgres", or "mysql".</summary>
    string Dialect { get; }

    Task<List<JsObject>> AllAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default);

    Task RunAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default);

    /// <summary>Runs an UPDATE or DELETE and says how many rows it matched.</summary>
    Task<long> AffectedAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default);

    /// <summary>
    /// Runs <paramref name="fn"/> in one transaction, committed when it returns and rolled back when
    /// it throws. A transaction already open is joined, not nested.
    /// </summary>
    Task<T> TransactionAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default);

    /// <summary>
    /// Runs <paramref name="fn"/> while holding a database-wide lock, so two processes starting at
    /// once do not race to create the same tables.
    /// </summary>
    Task<T> ExclusiveAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default);
}

/// <summary>Helpers over <see cref="IDb"/>.</summary>
public static class DbExtensions
{
    public static Task TransactionAsync(this IDb db, Func<IDb, Task> fn, CancellationToken cancellationToken = default) =>
        db.TransactionAsync<bool>(
            async d =>
            {
                await fn(d).ConfigureAwait(false);
                return true;
            },
            cancellationToken);

    /// <summary>The first row, or null.</summary>
    public static async Task<JsObject?> FirstAsync(this IDb db, string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default)
    {
        var rows = await db.AllAsync(sql, args, cancellationToken).ConfigureAwait(false);
        return rows.Count > 0 ? rows[0] : null;
    }
}
