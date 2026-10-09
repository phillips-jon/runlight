using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Store;

namespace Runlight.Accounts;

/// <summary>
/// Counts failed sign-ins under a key and refuses more than a few in a while. Keys are hashed with a key
/// made on first use, so the counts never hold an address or an email as it was given.
/// </summary>
/// <remarks>
/// TypeScript keeps the counts in its process. Here, as in PHP, they live in the database's settings, as
/// "throttle:&lt;name&gt;:&lt;id&gt;" holding {count, until}, and the hashing key as "throttle-key", so every
/// process of an install shares the same counts and both implementations can serve one database.
/// </remarks>
public sealed class Throttle
{
    private const string Key = "throttle-key";

    private readonly SqlStore _store;
    private readonly string _name;
    private readonly int _limit;
    private readonly long _windowMs;

    public Throttle(SqlStore store, string name, int limit = 10, long windowMs = 15 * 60_000)
    {
        _store = store;
        _name = name;
        _limit = limit;
        _windowMs = windowMs;
    }

    private async Task<string> SaltAsync(CancellationToken cancellationToken)
    {
        string? saved = await _store.SettingAsync(Key, cancellationToken).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(saved))
        {
            return saved;
        }
        string made = Hash.RandomId(16);
        await _store.SetSettingAsync(Key, made, cancellationToken).ConfigureAwait(false);
        return made;
    }

    private async Task<string> IdAsync(string key, CancellationToken cancellationToken)
    {
        string salt = await SaltAsync(cancellationToken).ConfigureAwait(false);
        return Crypto.Base64url(Crypto.Hmac("SHA-256", Js.Utf8(salt), Js.Utf8(key)))[..22];
    }

    private string Prefix => "throttle:" + _name + ":";

    private static (long Count, long Until) Read(object? entry) =>
        entry is JsObject o
            ? (Js.ToLong(Js.Number(o.Get("count") ?? 0L)), Js.ToLong(Js.Number(o.Get("until") ?? 0L)))
            : (0, 0);

    private async Task<(long Count, long Until)?> EntryAsync(string id, CancellationToken cancellationToken)
    {
        string? saved = await _store.SettingAsync(Prefix + id, cancellationToken).ConfigureAwait(false);
        object? entry = saved == null ? null : Json.TryParse(saved);
        return entry is JsObject ? Read(entry) : null;
    }

    private Task SaveAsync(string id, (long Count, long Until) entry, CancellationToken cancellationToken) =>
        _store.SetSettingAsync(Prefix + id, Json.Stringify(new JsObject { ["count"] = entry.Count, ["until"] = entry.Until }), cancellationToken);

    public async Task<bool> BlockedAsync(string key, long now, CancellationToken cancellationToken = default) =>
        await IsBlockedAsync(await IdAsync(key, cancellationToken).ConfigureAwait(false), now, cancellationToken).ConfigureAwait(false);

    private async Task<bool> IsBlockedAsync(string id, long now, CancellationToken cancellationToken)
    {
        var entry = await EntryAsync(id, cancellationToken).ConfigureAwait(false);
        if (entry == null || entry.Value.Until <= now)
        {
            return false;
        }
        return entry.Value.Count >= _limit;
    }

    /// <summary>
    /// Counts a try before the slow check it guards, so a burst that arrives while earlier tries are still
    /// being checked cannot get past the limit. False, counting nothing, when the key is already at its
    /// limit. A try that turns out right is taken back with <see cref="ForgiveAsync"/>.
    /// </summary>
    public async Task<bool> TakeAsync(string key, long now, CancellationToken cancellationToken = default)
    {
        string id = await IdAsync(key, cancellationToken).ConfigureAwait(false);
        if (await IsBlockedAsync(id, now, cancellationToken).ConfigureAwait(false))
        {
            return false;
        }
        await CountAsync(id, now, cancellationToken).ConfigureAwait(false);
        return true;
    }

    /// <summary>Takes back one counted try, for one that turned out right.</summary>
    public async Task ForgiveAsync(string key, CancellationToken cancellationToken = default)
    {
        string id = await IdAsync(key, cancellationToken).ConfigureAwait(false);
        var entry = await EntryAsync(id, cancellationToken).ConfigureAwait(false);
        if (entry != null && entry.Value.Count > 0)
        {
            await SaveAsync(id, (entry.Value.Count - 1, entry.Value.Until), cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task FailAsync(string key, long now, CancellationToken cancellationToken = default) =>
        await CountAsync(await IdAsync(key, cancellationToken).ConfigureAwait(false), now, cancellationToken).ConfigureAwait(false);

    private async Task CountAsync(string id, long now, CancellationToken cancellationToken)
    {
        var entry = await EntryAsync(id, cancellationToken).ConfigureAwait(false);
        if (entry == null || entry.Value.Until <= now)
        {
            await SaveAsync(id, (1, now + _windowMs), cancellationToken).ConfigureAwait(false);
            await PruneAsync(now, cancellationToken).ConfigureAwait(false);
            return;
        }
        await SaveAsync(id, (entry.Value.Count + 1, entry.Value.Until), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the counts
    /// have a hard ceiling and a flood of made-up names cannot wipe out a real block. Run when a new entry is
    /// made, since only then can there be more.
    /// </summary>
    private async Task PruneAsync(long now, CancellationToken cancellationToken)
    {
        var entries = new List<(string Key, long Until, bool Blocked)>();
        foreach (var row in await _store.SettingsStartingWithAsync(Prefix, cancellationToken).ConfigureAwait(false))
        {
            string key = row.Str("key")!;
            object? entry = Json.TryParse(row.Str("value") ?? "");
            var (count, until) = Read(entry);
            if (until <= now)
            {
                await _store.SetSettingAsync(key, null, cancellationToken).ConfigureAwait(false);
                continue;
            }
            entries.Add((key, until, entry is JsObject && count >= _limit));
        }
        int size = entries.Count;
        if (size <= Accounts.MaxThrottled)
        {
            return;
        }
        // Oldest first: each entry's window started windowMs before its end.
        var oldest = entries.OrderBy(e => e.Until).ToList();
        foreach (bool blocked in new[] { false, true })
        {
            foreach (var entry in oldest)
            {
                if (size <= Accounts.MaxThrottled)
                {
                    return;
                }
                if (entry.Blocked == blocked)
                {
                    await _store.SetSettingAsync(entry.Key, null, cancellationToken).ConfigureAwait(false);
                    size--;
                }
            }
        }
    }

    public async Task ClearAsync(string key, CancellationToken cancellationToken = default) =>
        await _store.SetSettingAsync(Prefix + await IdAsync(key, cancellationToken).ConfigureAwait(false), null, cancellationToken).ConfigureAwait(false);
}
