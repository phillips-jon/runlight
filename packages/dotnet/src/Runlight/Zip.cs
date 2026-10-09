using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace Runlight;

/// <summary>
/// A ZIP file of text files, stored without compression, and the CSV that goes in it. Small and
/// plain, so it needs no library.
/// </summary>
public static class Zip
{
    private static readonly uint[] Table = MakeTable();

    private static readonly Regex Number = new("^-?[0-9]+(\\.[0-9]+)?\\z", RegexOptions.CultureInvariant);

    private static uint[] MakeTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
            }
            table[n] = c;
        }
        return table;
    }

    private static uint Crc32(byte[] bytes)
    {
        uint crc = 0xffffffff;
        foreach (byte b in bytes)
        {
            crc = Table[(crc ^ b) & 0xff] ^ (crc >> 8);
        }
        return crc ^ 0xffffffff;
    }

    /// <summary>DOS date and time, as ZIP stores them.</summary>
    private static (ushort Time, ushort Day) DosTime(long ms)
    {
        var at = DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;
        return (
            (ushort)(((at.Hour << 11) | (at.Minute << 5) | (at.Second / 2)) & 0xFFFF),
            (ushort)((((at.Year - 1980) << 9) | (at.Month << 5) | at.Day) & 0xFFFF));
    }

    /// <summary>
    /// The ZIP's bytes (TypeScript's zip()). Every entry carries the time <paramref name="now"/>
    /// (epoch milliseconds), in UTC.
    /// </summary>
    public static byte[] Archive(IEnumerable<(string Name, string Text)> files, long now)
    {
        ArgumentNullException.ThrowIfNull(files);
        var (time, day) = DosTime(now);
        using var parts = new MemoryStream();
        using var central = new MemoryStream();
        uint offset = 0;
        int count = 0;
        foreach (var file in files)
        {
            // TextEncoder writes UTF-8, with U+FFFD for anything that is not text.
            byte[] name = Js.Utf8(file.Name);
            byte[] data = Js.Utf8(file.Text);
            uint crc = Crc32(data);
            var local = new byte[30];
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(0), 0x04034b50);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(4), 20);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(6), 0x0800); // names are UTF-8
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(8), 0); // stored
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(10), time);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(12), day);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(14), crc);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(18), (uint)data.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(local.AsSpan(22), (uint)data.Length);
            BinaryPrimitives.WriteUInt16LittleEndian(local.AsSpan(26), (ushort)name.Length);
            parts.Write(local);
            parts.Write(name);
            parts.Write(data);

            var entry = new byte[46];
            BinaryPrimitives.WriteUInt32LittleEndian(entry.AsSpan(0), 0x02014b50);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(4), 20);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(6), 20);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(8), 0x0800);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(10), 0);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(12), time);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(14), day);
            BinaryPrimitives.WriteUInt32LittleEndian(entry.AsSpan(16), crc);
            BinaryPrimitives.WriteUInt32LittleEndian(entry.AsSpan(20), (uint)data.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(entry.AsSpan(24), (uint)data.Length);
            BinaryPrimitives.WriteUInt16LittleEndian(entry.AsSpan(28), (ushort)name.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(entry.AsSpan(42), offset);
            central.Write(entry);
            central.Write(name);
            offset += (uint)(30 + name.Length + data.Length);
            count++;
        }
        var end = new byte[22];
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(0), 0x06054b50);
        BinaryPrimitives.WriteUInt16LittleEndian(end.AsSpan(8), (ushort)count);
        BinaryPrimitives.WriteUInt16LittleEndian(end.AsSpan(10), (ushort)count);
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(12), (uint)central.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(end.AsSpan(16), offset);
        parts.Write(central.ToArray());
        parts.Write(end);
        return parts.ToArray();
    }

    /// <summary>One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a spreadsheet will not run it.</summary>
    public static string CsvRow(IEnumerable<object?> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        return string.Join(',', values.Select(v =>
        {
            string s = v is null or Undefined ? "" : Js.String(v);
            if (s.Length > 0 && s[0] is '=' or '+' or '-' or '@' or '\t' or '\r' && !Number.IsMatch(s))
            {
                s = "'" + s;
            }
            return s.AsSpan().IndexOfAny("\",\n\r") >= 0 ? "\"" + s.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : s;
        }));
    }

    /// <summary>A CSV file: the header, then each row, every line ending in CRLF.</summary>
    public static string Csv(IEnumerable<string> header, IEnumerable<IEnumerable<object?>> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return string.Join("\r\n", new[] { CsvRow(header) }.Concat(rows.Select(CsvRow))) + "\r\n";
    }
}
