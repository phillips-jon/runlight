using System;
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace Runlight.Accounts;

/// <summary>
/// scrypt (RFC 7914) in plain C#, since .NET has none built in. It gives the same bytes as Node's
/// crypto.scrypt, so a password hashed by any implementation checks out in the others.
/// </summary>
public static class Scrypt
{
    /// <summary>The derived key for a password and salt.</summary>
    /// <exception cref="ArgumentException">for a cost that is not a power of two above 1, or r or p below 1</exception>
    public static byte[] Derive(byte[] password, byte[] salt, int n, int r, int p, int length)
    {
        if (n < 2 || (n & (n - 1)) != 0)
        {
            throw new ArgumentException("N must be a power of two greater than 1");
        }
        if (r < 1 || p < 1 || length < 1)
        {
            throw new ArgumentException("r, p, and the key length must be at least 1");
        }
        int blockBytes = 128 * r;
        byte[] b = Rfc2898DeriveBytes.Pbkdf2(password, salt, 1, HashAlgorithmName.SHA256, blockBytes * p);
        for (int i = 0; i < p; i++)
        {
            RoMix(b, i * blockBytes, n, r);
        }
        return Rfc2898DeriveBytes.Pbkdf2(password, b, 1, HashAlgorithmName.SHA256, length);
    }

    /// <summary>scryptROMix: fills N blocks, then reads them back in an order that depends on each result.</summary>
    private static void RoMix(byte[] bytes, int offset, int n, int r)
    {
        int words = 32 * r;
        var x = new uint[words];
        var y = new uint[words];
        for (int i = 0; i < words; i++)
        {
            x[i] = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset + i * 4, 4));
        }
        var v = new uint[(long)words * n];
        for (int i = 0; i < n; i++)
        {
            Array.Copy(x, 0, v, (long)i * words, words);
            BlockMix(x, y, r);
        }
        int last = (2 * r - 1) * 16;
        int mask = n - 1;
        for (int i = 0; i < n; i++)
        {
            // Integerify: the first word of the last 64-byte part, which is the low bits of a little-endian number.
            long j = (long)(x[last] & (uint)mask) * words;
            for (int k = 0; k < words; k++)
            {
                x[k] ^= v[j + k];
            }
            BlockMix(x, y, r);
        }
        for (int i = 0; i < words; i++)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset + i * 4, 4), x[i]);
        }
    }

    /// <summary>
    /// scryptBlockMix with Salsa20/8: 2r parts of 16 words, each mixed with the one before, the even
    /// results first and the odd ones after. <paramref name="b"/> is changed in place; <paramref name="y"/> is scratch.
    /// </summary>
    private static void BlockMix(uint[] b, uint[] y, int r)
    {
        int parts = 2 * r;
        Span<uint> x = stackalloc uint[16];
        b.AsSpan((parts - 1) * 16, 16).CopyTo(x);
        for (int k = 0; k < parts; k++)
        {
            int o = k * 16;
            for (int i = 0; i < 16; i++)
            {
                x[i] ^= b[o + i];
            }
            Salsa8(x);
            // Even parts go to the first half, odd ones to the second.
            int to = ((k & 1) == 0 ? k / 2 : r + k / 2) * 16;
            x.CopyTo(y.AsSpan(to, 16));
        }
        Array.Copy(y, b, parts * 16);
    }

    private static void Salsa8(Span<uint> b)
    {
        uint x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7];
        uint x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15];
        for (int round = 0; round < 4; round++)
        {
            // Columns.
            x4 ^= uint.RotateLeft(x0 + x12, 7);
            x8 ^= uint.RotateLeft(x4 + x0, 9);
            x12 ^= uint.RotateLeft(x8 + x4, 13);
            x0 ^= uint.RotateLeft(x12 + x8, 18);
            x9 ^= uint.RotateLeft(x5 + x1, 7);
            x13 ^= uint.RotateLeft(x9 + x5, 9);
            x1 ^= uint.RotateLeft(x13 + x9, 13);
            x5 ^= uint.RotateLeft(x1 + x13, 18);
            x14 ^= uint.RotateLeft(x10 + x6, 7);
            x2 ^= uint.RotateLeft(x14 + x10, 9);
            x6 ^= uint.RotateLeft(x2 + x14, 13);
            x10 ^= uint.RotateLeft(x6 + x2, 18);
            x3 ^= uint.RotateLeft(x15 + x11, 7);
            x7 ^= uint.RotateLeft(x3 + x15, 9);
            x11 ^= uint.RotateLeft(x7 + x3, 13);
            x15 ^= uint.RotateLeft(x11 + x7, 18);
            // Rows.
            x1 ^= uint.RotateLeft(x0 + x3, 7);
            x2 ^= uint.RotateLeft(x1 + x0, 9);
            x3 ^= uint.RotateLeft(x2 + x1, 13);
            x0 ^= uint.RotateLeft(x3 + x2, 18);
            x6 ^= uint.RotateLeft(x5 + x4, 7);
            x7 ^= uint.RotateLeft(x6 + x5, 9);
            x4 ^= uint.RotateLeft(x7 + x6, 13);
            x5 ^= uint.RotateLeft(x4 + x7, 18);
            x11 ^= uint.RotateLeft(x10 + x9, 7);
            x8 ^= uint.RotateLeft(x11 + x10, 9);
            x9 ^= uint.RotateLeft(x8 + x11, 13);
            x10 ^= uint.RotateLeft(x9 + x8, 18);
            x12 ^= uint.RotateLeft(x15 + x14, 7);
            x13 ^= uint.RotateLeft(x12 + x15, 9);
            x14 ^= uint.RotateLeft(x13 + x12, 13);
            x15 ^= uint.RotateLeft(x14 + x13, 18);
        }
        b[0] += x0;
        b[1] += x1;
        b[2] += x2;
        b[3] += x3;
        b[4] += x4;
        b[5] += x5;
        b[6] += x6;
        b[7] += x7;
        b[8] += x8;
        b[9] += x9;
        b[10] += x10;
        b[11] += x11;
        b[12] += x12;
        b[13] += x13;
        b[14] += x14;
        b[15] += x15;
    }
}
