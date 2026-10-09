using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight;

/// <summary>What <see cref="Safefetch.PublicFetchAsync"/> takes besides the URL.</summary>
public sealed class PublicFetchInit
{
    /// <summary>The time every hop together may take.</summary>
    public int TimeoutMs { get; set; }

    public Headers Headers { get; set; } = new();

    /// <summary>How many redirects to follow; a redirect past the last comes back as it is.</summary>
    public int Redirects { get; set; }

    /// <summary>Passed to the fetcher, for a capped read.</summary>
    public long? MaxBytes { get; set; }

    /// <summary>Passed to the fetcher, with MaxBytes, to hand back the start of a long body.</summary>
    public bool Truncate { get; set; }

    /// <summary>Stands in for DNS in tests: every address a name resolves to.</summary>
    public Func<string, Task<IReadOnlyList<string>>>? Lookup { get; set; }
}

/// <summary>
/// Fetches from addresses that other people's input names, such as the icon links on a site's
/// home page or a link domain, and only from the public internet. Only https is fetched, never a
/// private, loopback, link-local, or metadata address, and redirects are followed by hand under
/// the same rules. The name is resolved and every address it gives is checked before each hop,
/// and the request is pinned to the checked addresses (the fetcher's Resolve), so a name that
/// answers differently a moment later gets nowhere.
/// </summary>
public static class Safefetch
{
    private static readonly Regex Brackets = new("^\\[|\\]\\z", RegexOptions.CultureInvariant);
    private static readonly Regex TrailingV4 = new("([0-9]{1,3}(?:\\.[0-9]{1,3}){3})\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Octet = new("^[0-9]{1,3}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Group = new("^[0-9a-f]{1,4}\\z", RegexOptions.CultureInvariant);

    private static int[]? V4(string text)
    {
        string[] parts = text.Split('.');
        if (parts.Length != 4)
        {
            return null;
        }
        foreach (string p in parts)
        {
            if (!Octet.IsMatch(p) || int.Parse(p, CultureInfo.InvariantCulture) > 255)
            {
                return null;
            }
        }
        return parts.Select(p => int.Parse(p, CultureInfo.InvariantCulture)).ToArray();
    }

    private static bool PublicV4(int[] four)
    {
        int a = four[0], b = four[1], c = four[2];
        if (a == 0 || a == 10 || a == 127 || a >= 224)
        {
            return false;
        }
        if (a == 100 && b >= 64 && b < 128)
        {
            return false;
        }
        if (a == 169 && b == 254)
        {
            return false;
        }
        if (a == 172 && b >= 16 && b < 32)
        {
            return false;
        }
        if (a == 192 && b == 168)
        {
            return false;
        }
        if (a == 192 && b == 0 && (c == 0 || c == 2))
        {
            return false;
        }
        if (a == 198 && (b == 18 || b == 19))
        {
            return false;
        }
        if (a == 198 && b == 51 && c == 100)
        {
            return false;
        }
        if (a == 203 && b == 0 && c == 113)
        {
            return false;
        }
        return true;
    }

    /// <summary>An IPv6 address as eight 16-bit groups, or null when it is not one.</summary>
    private static int[]? V6(string text)
    {
        string address = Brackets.Replace(text, "").Split('%')[0].ToLowerInvariant();
        // A trailing IPv4 address becomes the last two groups.
        var tail = TrailingV4.Match(address);
        if (tail.Success)
        {
            int[]? four = V4(tail.Groups[1].Value);
            if (four == null)
            {
                return null;
            }
            address = address[..^tail.Groups[1].Value.Length]
                + ((four[0] << 8) | four[1]).ToString("x", CultureInfo.InvariantCulture) + ":"
                + ((four[2] << 8) | four[3]).ToString("x", CultureInfo.InvariantCulture);
        }
        string[] halves = address.Split("::");
        if (halves.Length > 2)
        {
            return null;
        }
        string[] head = halves[0].Length > 0 ? halves[0].Split(':') : [];
        string[] rest = halves.Length == 2 && halves[1].Length > 0 ? halves[1].Split(':') : [];
        int missing = 8 - head.Length - rest.Length;
        if (halves.Length == 1 ? missing != 0 : missing < 1)
        {
            return null;
        }
        var groups = new List<string>(head);
        groups.AddRange(Enumerable.Repeat("0", halves.Length == 2 ? missing : 0));
        groups.AddRange(rest);
        foreach (string g in groups)
        {
            if (!Group.IsMatch(g))
            {
                return null;
            }
        }
        return groups.Select(g => int.Parse(g, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture)).ToArray();
    }

    /// <summary>Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not.</summary>
    public static bool PublicAddress(string ip)
    {
        ArgumentNullException.ThrowIfNull(ip);
        int[]? four = V4(ip);
        if (four != null)
        {
            return PublicV4(four);
        }
        int[]? g = V6(ip);
        if (g == null)
        {
            return false;
        }
        static int[] Embedded(int hi, int lo) => [hi >> 8, hi & 255, lo >> 8, lo & 255];
        static bool Zero(IEnumerable<int> groups) => groups.All(x => x == 0);
        // IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
        if (Zero(g.Take(5)) && (g[5] == 0xffff || g[5] == 0))
        {
            return g[5] == 0 && g[6] == 0 && g[7] <= 1 ? false : PublicV4(Embedded(g[6], g[7]));
        }
        if (g[0] == 0x64 && g[1] == 0xff9b && Zero(g.Skip(2).Take(4)))
        {
            return PublicV4(Embedded(g[6], g[7]));
        }
        // 6to4 carries an IPv4 address in its second and third groups.
        if (g[0] == 0x2002)
        {
            return PublicV4(Embedded(g[1], g[2]));
        }
        if ((g[0] & 0xfe00) == 0xfc00 || (g[0] & 0xffc0) == 0xfe80 || (g[0] & 0xff00) == 0xff00)
        {
            return false;
        }
        // Teredo, documentation, and discard prefixes.
        if (g[0] == 0x2001 && (g[1] == 0 || g[1] == 0xdb8))
        {
            return false;
        }
        if (g[0] == 0x100 && Zero(g.Skip(1).Take(3)))
        {
            return false;
        }
        return true;
    }

    /// <summary>
    /// Every address a name resolves to, v4 and v6, as getaddrinfo() would give them (the hosts
    /// file included). Empty when it does not resolve.
    /// </summary>
    public static async Task<IReadOnlyList<string>> LookupAsync(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        string bare = Brackets.Replace(name, "");
        if (V4(bare) != null || V6(bare) != null)
        {
            return [bare];
        }
        try
        {
            var found = await Dns.GetHostAddressesAsync(bare).ConfigureAwait(false);
            return found.Select(a => a.IsIPv4MappedToIPv6 ? a.MapToIPv4().ToString() : a.ToString()).Distinct(StringComparer.Ordinal).ToList();
        }
        catch (Exception e) when (e is SocketException or ArgumentException)
        {
            return [];
        }
    }

    /// <summary>The public addresses a name resolves to, for setting up DNS records. None where it does not resolve.</summary>
    /// <param name="name">The name.</param>
    /// <param name="lookup">Stands in for DNS in tests.</param>
    public static async Task<IReadOnlyList<string>> PublicAddressesAsync(string name, Func<string, Task<IReadOnlyList<string>>>? lookup = null)
    {
        IReadOnlyList<string> addresses;
        try
        {
            addresses = await (lookup ?? LookupAsync)(name).ConfigureAwait(false);
        }
#pragma warning disable CA1031 // Any failure to resolve means no addresses, as the TypeScript's catch.
        catch (Exception)
#pragma warning restore CA1031
        {
            return [];
        }
        return addresses.Where(PublicAddress).Distinct(StringComparer.Ordinal).ToList();
    }

    /// <summary>Whether a name resolves to an address off the public internet. False when it does not resolve.</summary>
    /// <param name="name">The name.</param>
    /// <param name="lookup">Stands in for DNS in tests.</param>
    public static async Task<bool> ResolvesPrivatelyAsync(string name, Func<string, Task<IReadOnlyList<string>>>? lookup = null)
    {
        IReadOnlyList<string> addresses;
        try
        {
            addresses = await (lookup ?? LookupAsync)(name).ConfigureAwait(false);
        }
#pragma warning disable CA1031 // Any failure to resolve means it does not resolve privately, as the TypeScript's catch.
        catch (Exception)
#pragma warning restore CA1031
        {
            return false;
        }
        return addresses.Any(a => !PublicAddress(a));
    }

    /// <summary>
    /// GETs an https URL on the public internet, following up to Redirects redirects that stay on
    /// it, within TimeoutMs in all. Throws a <see cref="PrivateAddressError"/> for an address off
    /// it, and a <see cref="FetchException"/> with TimedOut when time runs out. A redirect past the
    /// last one comes back as it is. MaxBytes and Truncate go to the fetcher, for a capped read.
    /// </summary>
    public static async Task<Response> PublicFetchAsync(string target, PublicFetchInit init, IFetcher fetcher, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(init);
        ArgumentNullException.ThrowIfNull(fetcher);
        var lookup = init.Lookup ?? LookupAsync;
        var clock = Stopwatch.StartNew();
        var url = new Url(target);
        for (int hop = 0; ; hop++)
        {
            if (url.Protocol != "https:")
            {
                throw new PrivateAddressError(url.Href);
            }
            string host = Brackets.Replace(url.Hostname, "").ToLowerInvariant();
            bool literal = V4(host) != null || V6(host) != null;
            if (literal && !PublicAddress(host))
            {
                throw new PrivateAddressError(host);
            }
            if (host == "localhost" || host.EndsWith(".localhost", StringComparison.Ordinal))
            {
                throw new PrivateAddressError(host);
            }
            var pin = new List<string>();
            if (!literal)
            {
                // The address checked is the address used: every one the name gives must be public, and the
                // connection is pinned to them, so a second lookup cannot hand back another.
                var addresses = await lookup(host).ConfigureAwait(false);
                if (addresses.Count == 0)
                {
                    throw new FetchException("getaddrinfo ENOTFOUND " + host);
                }
                foreach (string address in addresses)
                {
                    if (!PublicAddress(address))
                    {
                        throw new PrivateAddressError(host);
                    }
                }
                string port = url.Port.Length > 0 ? url.Port : "443";
                pin.Add(host + ":" + port + ":" + string.Join(',', addresses.Select(a => a.Contains(':', StringComparison.Ordinal) ? "[" + a + "]" : a)));
            }
            long left = init.TimeoutMs - clock.ElapsedMilliseconds;
            if (left <= 0)
            {
                throw TimedOut();
            }
            var options = new FetchInit
            {
                Headers = new Headers(init.Headers),
                Redirect = "manual",
                TimeoutMs = (int)left,
                MaxBytes = init.MaxBytes,
                Truncate = init.Truncate,
                Resolve = pin,
            };
            Response answer;
            try
            {
                answer = await fetcher.FetchAsync(url.Href, options, cancellationToken).ConfigureAwait(false);
            }
            catch (FetchException error)
            {
                // Whichever way the request gave up, the caller hears that time ran out.
                if (error.TimedOut || clock.ElapsedMilliseconds >= init.TimeoutMs)
                {
                    throw TimedOut();
                }
                throw;
            }
            string? location = answer.Headers.Get("location");
            if (answer.Status < 300 || answer.Status >= 400 || string.IsNullOrEmpty(location) || hop >= init.Redirects)
            {
                return answer;
            }
            url = new Url(location, url.Href);
        }
    }

    private static FetchException TimedOut() => new("The operation was aborted due to timeout", true);
}
