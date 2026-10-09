using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Db;

namespace Runlight.Tests.Store;

/// <summary>
/// An <see cref="IDb"/> that lets a test see, and step into, every statement: as the TypeScript
/// tests replace db.run and db.all on a store. Statements inside a transaction or lock go through
/// it too.
/// </summary>
public sealed class WatchedDb(IDb inner) : IDb
{
    public IDb Inner { get; } = inner;

    /// <summary>Called before each statement.</summary>
    public Func<string, IReadOnlyList<object?>, Task>? Before { get; set; }

    /// <summary>Called after each run.</summary>
    public Func<string, IReadOnlyList<object?>, Task>? AfterRun { get; set; }

    public string Dialect => Inner.Dialect;

    private async Task BeforeAsync(string sql, IReadOnlyList<object?>? args)
    {
        if (Before != null)
        {
            await Before(sql, args ?? []);
        }
    }

    public async Task<List<JsObject>> AllAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default)
    {
        await BeforeAsync(sql, args);
        return await Inner.AllAsync(sql, args, cancellationToken);
    }

    public async Task RunAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default)
    {
        await BeforeAsync(sql, args);
        await Inner.RunAsync(sql, args, cancellationToken);
        if (AfterRun != null)
        {
            await AfterRun(sql, args ?? []);
        }
    }

    public async Task<long> AffectedAsync(string sql, IReadOnlyList<object?>? args = null, CancellationToken cancellationToken = default)
    {
        await BeforeAsync(sql, args);
        return await Inner.AffectedAsync(sql, args, cancellationToken);
    }

    public Task<T> TransactionAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default) =>
        Inner.TransactionAsync(_ => fn(this), cancellationToken);

    public Task<T> ExclusiveAsync<T>(Func<IDb, Task<T>> fn, CancellationToken cancellationToken = default) =>
        Inner.ExclusiveAsync(_ => fn(this), cancellationToken);

    /// <summary>The inner database stays open: the test's own store closes it.</summary>
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
