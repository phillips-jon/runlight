using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Threading;

namespace Runlight;

/// <summary>
/// A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and DB-IP's free
/// databases use), so location needs no library. It answers what the TypeScript server's mmdb-lib
/// answers: the record for an address, maps as <see cref="JsObject"/>, or null when the address is
/// not in the database.
/// </summary>
/// <remarks>
/// A database opened from a file is read a page at a time as lookups need it, so a 130 MB city
/// database costs each lookup a few hundred kilobytes of reads. Format:
/// https://maxmind.github.io/MaxMind-DB/
/// </remarks>
public sealed class Mmdb : IDisposable
{
    private static readonly byte[] MetadataMarker = [0xAB, 0xCD, 0xEF, .. "MaxMind.com"u8];

    /// <summary>The metadata sits in the file's last 128 KiB.</summary>
    private const int MetadataMax = 131072;

    private const int Page = 4096;

    /// <summary>Pages kept from a file at once; a lookup reads a few dozen.</summary>
    private const int PagesKept = 256;

    private readonly byte[]? _bytes;
    private readonly FileStream? _file;
    private readonly long _size;
    private readonly Dictionary<long, byte[]> _pages = [];
    private readonly Lock _lock = new();
    private readonly long _nodeCount;
    private readonly int _recordSize;
    private readonly int _nodeBytes;
    private readonly long _dataStart;
    private long _ipv4Start = -1;

    public JsObject Metadata { get; }

    /// <summary>A database held whole in memory.</summary>
    public Mmdb(byte[] bytes)
        : this(bytes, null)
    {
    }

    private Mmdb(byte[]? bytes, FileStream? file)
    {
        _bytes = bytes;
        _file = file;
        _size = file?.Length ?? bytes!.Length;
        long tailStart = Math.Max(0, _size - MetadataMax);
        byte[] tail = Read(tailStart, (int)(_size - tailStart));
        int at = tail.AsSpan().LastIndexOf(MetadataMarker);
        if (at < 0)
        {
            throw new ArgumentException("Not a MaxMind DB file: no metadata");
        }
        long start = tailStart + at + MetadataMarker.Length;
        var (metadata, _) = Decode(start, start);
        if (metadata is not JsObject m || !m.Has("node_count") || !m.Has("record_size") || !m.Has("ip_version"))
        {
            throw new ArgumentException("Not a MaxMind DB file: bad metadata");
        }
        Metadata = m;
        _nodeCount = m.Long("node_count");
        _recordSize = (int)m.Long("record_size");
        if (_recordSize is not (24 or 28 or 32))
        {
            throw new ArgumentException("Unsupported record size " + Js.Str(_recordSize));
        }
        _nodeBytes = _recordSize / 4;
        _dataStart = _nodeCount * _nodeBytes + 16;
    }

    /// <summary>A database read from its file as lookups need it.</summary>
    public static Mmdb Open(string file)
    {
        FileStream stream;
        try
        {
            stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new IOException("Could not read " + file, e);
        }
        try
        {
            return new Mmdb(null, stream);
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    public void Dispose() => _file?.Dispose();

    /// <summary><paramref name="length"/> bytes from <paramref name="at"/>, fewer at the end of the database.</summary>
    private byte[] Read(long at, int length)
    {
        long end = Math.Min(at + length, _size);
        if (at >= end)
        {
            return [];
        }
        if (_bytes != null)
        {
            return _bytes.AsSpan((int)at, (int)(end - at)).ToArray();
        }
        var output = new byte[end - at];
        int filled = 0;
        lock (_lock)
        {
            while (at < end)
            {
                long number = at / Page;
                if (!_pages.TryGetValue(number, out var page))
                {
                    if (_pages.Count >= PagesKept)
                    {
                        _pages.Clear();
                    }
                    _file!.Seek(number * Page, SeekOrigin.Begin);
                    var buffer = new byte[Page];
                    int read = 0;
                    while (read < Page)
                    {
                        int n = _file.Read(buffer, read, Page - read);
                        if (n == 0)
                        {
                            break;
                        }
                        read += n;
                    }
                    page = buffer.AsSpan(0, read).ToArray();
                    _pages[number] = page;
                }
                int offset = (int)(at - number * Page);
                int take = (int)Math.Min(page.Length - offset, end - at);
                if (take <= 0)
                {
                    break;
                }
                page.AsSpan(offset, take).CopyTo(output.AsSpan(filled));
                filled += take;
                at += take;
            }
        }
        return filled == output.Length ? output : output[..filled];
    }

    private int Byte(long at)
    {
        byte[] b = Read(at, 1);
        if (b.Length == 0)
        {
            throw new InvalidDataException("Invalid MaxMind DB: read past the end");
        }
        return b[0];
    }

    /// <summary>The record for an address, or null. Throws <see cref="ArgumentException"/> for text that is not an IP address.</summary>
    public object? Get(string ip)
    {
        byte[] packed = Pton(ip) ?? throw new ArgumentException("Not an IP address: " + ip);
        bool v6 = packed.Length == 16;
        long version = Metadata.Long("ip_version");
        if (v6 && version == 4)
        {
            throw new ArgumentException("An IPv6 address cannot be looked up in an IPv4-only database: " + ip);
        }
        long node = v6 || version == 4 ? 0 : Ipv4Start();
        int bits = packed.Length * 8;
        for (int i = 0; i < bits && node < _nodeCount; i++)
        {
            int bit = (packed[i >> 3] >> (7 - (i & 7))) & 1;
            node = Record(node, bit);
        }
        // The node count itself means no record, and so does a tree that ends before the address does.
        if (node <= _nodeCount)
        {
            return null;
        }
        var (value, _) = Decode(_dataStart + node - _nodeCount - 16, _dataStart);
        return value;
    }

    /// <summary>IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down.</summary>
    private long Ipv4Start()
    {
        if (_ipv4Start < 0)
        {
            long node = 0;
            for (int i = 0; i < 96 && node < _nodeCount; i++)
            {
                node = Record(node, 0);
            }
            _ipv4Start = node;
        }
        return _ipv4Start;
    }

    private long Record(long node, int right)
    {
        byte[] b = Read(node * _nodeBytes, _nodeBytes);
        if (b.Length < _nodeBytes)
        {
            throw new InvalidDataException("Invalid MaxMind DB: read past the end");
        }
        switch (_recordSize)
        {
            case 24:
                {
                    int at = right * 3;
                    return (b[at] << 16) | (b[at + 1] << 8) | b[at + 2];
                }
            case 28:
                if (right == 0)
                {
                    return ((long)(b[3] & 0xF0) << 20) | ((long)b[0] << 16) | ((long)b[1] << 8) | b[2];
                }
                return ((long)(b[3] & 0x0F) << 24) | ((long)b[4] << 16) | ((long)b[5] << 8) | b[6];
            default:
                return BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(right * 4, 4));
        }
    }

    /// <summary>Decodes the value at <paramref name="at"/>; pointers are offsets from <paramref name="baseAt"/>.</summary>
    private (object? Value, long Next) Decode(long at, long baseAt)
    {
        int control = Byte(at++);
        int type = control >> 5;
        if (type == 1)
        {
            // A pointer: up to four more bytes of offset, then the value found there.
            int ss = (control >> 3) & 3;
            long vvv = control & 7;
            long pointer = ss switch
            {
                0 => (vvv << 8) | (long)Byte(at),
                1 => ((vvv << 16) | ((long)Byte(at) << 8) | (long)Byte(at + 1)) + 2048,
                2 => ((vvv << 24) | ((long)Byte(at) << 16) | ((long)Byte(at + 1) << 8) | (long)Byte(at + 2)) + 526336,
                _ => (long)Unsigned(Read(at, 4)),
            };
            var (value, _) = Decode(baseAt + pointer, baseAt);
            return (value, at + ss + 1);
        }
        if (type == 0)
        {
            type = 7 + Byte(at++);
        }
        long size = control & 0x1F;
        if (size >= 29)
        {
            int extra = (int)size - 28;
            long n = 0;
            for (int i = 0; i < extra; i++)
            {
                n = (n << 8) | (long)Byte(at + i);
            }
            size = (size switch
            {
                29 => 29L,
                30 => 285L,
                _ => 65821L,
            }) + n;
            at += extra;
        }
        switch (type)
        {
            case 2: // UTF-8 string
                return (Js.Decode(Read(at, (int)size)), at + size);
            case 3: // double
                return (BinaryPrimitives.ReadDoubleBigEndian(Read(at, 8)), at + 8);
            case 4: // bytes
                return (Read(at, (int)size), at + size);
            case 5: // uint16
            case 6: // uint32
                return ((long)Unsigned(Read(at, (int)size)), at + size);
            case 7: // map
                {
                    var map = new JsObject();
                    for (long i = 0; i < size; i++)
                    {
                        var (key, afterKey) = Decode(at, baseAt);
                        var (value, afterValue) = Decode(afterKey, baseAt);
                        map.Set(key is string k ? k : Js.String(key), value);
                        at = afterValue;
                    }
                    return (map, at);
                }
            case 8: // int32
                {
                    long n = (long)Unsigned(Read(at, (int)size));
                    if (size == 4 && n >= 0x80000000L)
                    {
                        n -= 0x100000000L;
                    }
                    return (n, at + size);
                }
            case 9: // uint64
            case 10: // uint128
                {
                    var n = Unsigned(Read(at, (int)size));
                    return (n <= long.MaxValue ? (long)n : n.ToString(System.Globalization.CultureInfo.InvariantCulture), at + size);
                }
            case 11: // array
                {
                    var list = new List<object?>();
                    for (long i = 0; i < size; i++)
                    {
                        var (value, next) = Decode(at, baseAt);
                        list.Add(value);
                        at = next;
                    }
                    return (list, at);
                }
            case 14: // boolean, its value in the size
                return (size != 0, at);
            case 15: // float
                return ((double)BinaryPrimitives.ReadSingleBigEndian(Read(at, 4)), at + 4);
            default:
                throw new InvalidDataException("Invalid MaxMind DB: unknown data type " + Js.Str(type));
        }
    }

    /// <summary>inet_pton: dotted decimal IPv4 (four parts, no leading zeros) or IPv6, else null.</summary>
    public static byte[]? Pton(string ip)
    {
        if (ip.Contains(':', StringComparison.Ordinal))
        {
            if (ip.Contains('%', StringComparison.Ordinal) || ip.Contains('/', StringComparison.Ordinal) || ip.StartsWith('[')
                || !IPAddress.TryParse(ip, out var v6) || v6.AddressFamily != AddressFamily.InterNetworkV6)
            {
                return null;
            }
            return v6.GetAddressBytes();
        }
        string[] parts = ip.Split('.');
        if (parts.Length != 4)
        {
            return null;
        }
        var output = new byte[4];
        for (int i = 0; i < 4; i++)
        {
            string p = parts[i];
            if (p.Length == 0 || p.Length > 3 || (p.Length > 1 && p[0] == '0'))
            {
                return null;
            }
            int n = 0;
            foreach (char c in p)
            {
                if (!char.IsAsciiDigit(c))
                {
                    return null;
                }
                n = n * 10 + (c - '0');
            }
            if (n > 255)
            {
                return null;
            }
            output[i] = (byte)n;
        }
        return output;
    }

    private static BigInteger Unsigned(byte[] bytes) => new(bytes, isUnsigned: true, isBigEndian: true);
}
