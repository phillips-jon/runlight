using System;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace Runlight;

/// <summary>
/// Counts tracker requests per address in fixed one-minute windows, in memory. Addresses are
/// hashed with a key made at start, so the map never holds an IP, and the whole map is dropped at
/// the end of each window. Several servers behind a load balancer each count on their own. Safe to
/// use from several threads at once.
/// </summary>
public sealed class RateLimit
{
    private readonly long _perMinute;
    private readonly Func<long> _now;
    private readonly byte[] _key = RandomNumberGenerator.GetBytes(16);
    private readonly Dictionary<string, long> _counts = new(StringComparer.Ordinal);
    private readonly object _lock = new();
    private long _window;

    /// <param name="perMinute">How many requests an address may make in a minute.</param>
    /// <param name="now">The clock, in epoch milliseconds.</param>
    public RateLimit(long perMinute, Func<long> now)
    {
        _perMinute = perMinute;
        _now = now;
    }

    /// <summary>True while this address is under its limit for the current minute.</summary>
    public bool Allow(string ip)
    {
        // No address (a bare adapter with no context) cannot be told apart, so it is not limited.
        if (string.IsNullOrEmpty(ip))
        {
            return true;
        }
        long window = (long)Math.Floor(_now() / 60_000.0);
        string id = Hash(ip);
        lock (_lock)
        {
            if (window != _window)
            {
                _window = window;
                _counts.Clear();
            }
            long count = (_counts.TryGetValue(id, out long c) ? c : 0) + 1;
            _counts[id] = count;
            return count <= _perMinute;
        }
    }

    private string Hash(string ip)
    {
        byte[] text = Js.Utf8(ip);
        var bytes = new byte[_key.Length + text.Length];
        _key.CopyTo(bytes, 0);
        text.CopyTo(bytes, _key.Length);
        return Convert.ToHexStringLower(SHA256.HashData(bytes), 0, 8);
    }
}
