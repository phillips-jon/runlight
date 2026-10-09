using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>ZIP reading as http-conformance.ts does it, and writing, for the fake that replays answers.</summary>
public static class TestZip
{
    /// <summary>The files in a ZIP, stored or deflated, by their local headers.</summary>
    public static List<(string Name, string Text)> Unzip(byte[] bytes)
    {
        var files = new List<(string, string)>();
        int at = 0;
        while (at + 30 <= bytes.Length && BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(at)) == 0x04034b50)
        {
            int method = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(at + 8));
            int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(at + 18));
            int nameLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(at + 26));
            int extra = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(at + 28));
            string name = Body.Utf8(bytes.AsSpan(at + 30, nameLength).ToArray());
            int start = at + 30 + nameLength + extra;
            byte[] data = bytes.AsSpan(start, Math.Min(size, bytes.Length - start)).ToArray();
            if (method == 8)
            {
                try
                {
                    using var input = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress);
                    using var output = new MemoryStream();
                    input.CopyTo(output);
                    data = output.ToArray();
                }
                catch (InvalidDataException error)
                {
                    throw new InvalidOperationException("The ZIP's " + name + " does not inflate", error);
                }
            }
            files.Add((name, Body.Utf8(data)));
            at = start + size;
        }
        return files;
    }

    /// <summary>A ZIP of these files, each deflated or stored as <paramref name="deflate"/> says, with a central directory.</summary>
    public static byte[] Zip(IEnumerable<(string Name, string Text)> files, bool deflate = true)
    {
        using var local = new MemoryStream();
        using var central = new MemoryStream();
        var w = new BinaryWriter(local);
        var c = new BinaryWriter(central);
        int count = 0;
        foreach (var (name, text) in files)
        {
            count++;
            byte[] raw = Encoding.UTF8.GetBytes(text);
            byte[] nameBytes = Encoding.UTF8.GetBytes(name);
            byte[] data = raw;
            if (deflate)
            {
                using var output = new MemoryStream();
                using (var d = new DeflateStream(output, CompressionLevel.Optimal, leaveOpen: true))
                {
                    d.Write(raw);
                }
                data = output.ToArray();
            }
            ushort method = (ushort)(deflate ? 8 : 0);
            uint crc = Crc32(raw);
            uint offset = (uint)local.Length;
            w.Write(0x04034b50u);
            w.Write((ushort)20);
            w.Write((ushort)0x0800);
            w.Write(method);
            w.Write((ushort)0);
            w.Write((ushort)0);
            w.Write(crc);
            w.Write((uint)data.Length);
            w.Write((uint)raw.Length);
            w.Write((ushort)nameBytes.Length);
            w.Write((ushort)0);
            w.Write(nameBytes);
            w.Write(data);
            c.Write(0x02014b50u);
            c.Write((ushort)20);
            c.Write((ushort)20);
            c.Write((ushort)0x0800);
            c.Write(method);
            c.Write((ushort)0);
            c.Write((ushort)0);
            c.Write(crc);
            c.Write((uint)data.Length);
            c.Write((uint)raw.Length);
            c.Write((ushort)nameBytes.Length);
            c.Write((ushort)0);
            c.Write((ushort)0);
            c.Write((ushort)0);
            c.Write((ushort)0);
            c.Write(0u);
            c.Write(offset);
            c.Write(nameBytes);
        }
        w.Flush();
        c.Flush();
        using var end = new MemoryStream();
        var e = new BinaryWriter(end);
        e.Write(0x06054b50u);
        e.Write((ushort)0);
        e.Write((ushort)0);
        e.Write((ushort)count);
        e.Write((ushort)count);
        e.Write((uint)central.Length);
        e.Write((uint)local.Length);
        e.Write((ushort)0);
        e.Flush();
        return [.. local.ToArray(), .. central.ToArray(), .. end.ToArray()];
    }

    private static uint Crc32(byte[] bytes)
    {
        uint crc = 0xffffffff;
        foreach (byte b in bytes)
        {
            crc ^= b;
            for (int k = 0; k < 8; k++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
            }
        }
        return crc ^ 0xffffffff;
    }
}
