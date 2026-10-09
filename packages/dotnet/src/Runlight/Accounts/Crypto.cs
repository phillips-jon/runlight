using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace Runlight.Accounts;

/// <summary>
/// The cryptography accounts need. Passwords use scrypt, as the standalone server always has, in a plain C#
/// scrypt that gives the same bytes as Node's; a PBKDF2 hash made on an edge runtime checks out too.
/// </summary>
/// <remarks>
/// Text is turned into bytes as UTF-8, as TextEncoder does. The two-factor pieces that live in auth.ts in
/// TypeScript (base32, TOTP, the otpauth address, recovery codes, and the signature on session cookies) are
/// here too, as functions of their inputs alone, so the accounts class can call them.
/// </remarks>
public static class Crypto
{
    private const int ScryptN = 16384;
    private const int ScryptR = 8;
    private const int ScryptP = 1;

    /// <summary>As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on.</summary>
    public const int Pbkdf2Rounds = 100_000;

    // Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
    public const long StepMs = 30_000;
    private const string Base32Letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// <summary>The shortest stored key accepted. Ours are 32 bytes.</summary>
    public const int MinKeyBytes = 16;

    public static byte[] RandomBytes(int length) => RandomNumberGenerator.GetBytes(length);

    public static string Base64url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>
    /// Bytes from base64url (or plain base64), read as atob() reads them: white space is skipped, padding is
    /// optional, and anything else that is not base64 throws.
    /// </summary>
    /// <exception cref="ArgumentException">for text atob() refuses</exception>
    public static byte[] FromBase64url(string text)
    {
        var plain = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (c is '\t' or '\n' or '\f' or '\r' or ' ')
            {
                continue;
            }
            plain.Append(c switch
            {
                '-' => '+',
                '_' => '/',
                _ => c,
            });
        }
        string s = plain.ToString();
        if (s.Length % 4 == 0)
        {
            if (s.EndsWith("==", StringComparison.Ordinal))
            {
                s = s[..^2];
            }
            else if (s.EndsWith('='))
            {
                s = s[..^1];
            }
        }
        if (s.Length % 4 == 1)
        {
            throw new ArgumentException("The string to be decoded is not correctly encoded.");
        }
        var bytes = new List<byte>(s.Length * 3 / 4);
        int bits = 0;
        int value = 0;
        foreach (char c in s)
        {
            int v = c switch
            {
                >= 'A' and <= 'Z' => c - 'A',
                >= 'a' and <= 'z' => c - 'a' + 26,
                >= '0' and <= '9' => c - '0' + 52,
                '+' => 62,
                '/' => 63,
                _ => -1,
            };
            if (v < 0)
            {
                throw new ArgumentException("The string to be decoded is not correctly encoded.");
            }
            value = ((value << 6) | v) & 0xffff;
            bits += 6;
            if (bits >= 8)
            {
                bytes.Add((byte)((value >> (bits - 8)) & 255));
                bits -= 8;
            }
        }
        return [.. bytes];
    }

    public static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);

    public static byte[] Sha256(byte[] value) => SHA256.HashData(value);

    public static byte[] Sha256(string value) => SHA256.HashData(Js.Utf8(value));

    /// <summary>HMAC with "SHA-1" or "SHA-256".</summary>
    /// <exception cref="ArgumentException">for an empty key, which WebCrypto will not import</exception>
    public static byte[] Hmac(string hash, byte[] key, byte[] data)
    {
        if (key.Length == 0)
        {
            // WebCrypto will not import an empty HMAC key.
            throw new ArgumentException("An HMAC key must not be empty");
        }
        // SHA-1 is what TOTP and every authenticator app use (RFC 6238); it is never used for anything else here.
#pragma warning disable CA5350
        return hash == "SHA-1" ? HMACSHA1.HashData(key, data) : HMACSHA256.HashData(key, data);
#pragma warning restore CA5350
    }

    /// <summary>Compares two strings in time that does not depend on where they differ.</summary>
    public static bool SameText(string a, string b) => SameBytes(Js.Utf8(a), Js.Utf8(b));

    /// <summary>A password hash, in the scrypt form the standalone server has always written.</summary>
    public static string HashPassword(string password)
    {
        byte[] salt = RandomBytes(16);
        return "scrypt$" + Base64url(salt) + "$" + Base64url(ScryptKey(password, salt, 32));
    }

    /// <summary>
    /// Whether a password matches a hash, scrypt or PBKDF2. A stored key under <see cref="MinKeyBytes"/> is
    /// refused, since an empty or cut key would match too easily, or anything.
    /// </summary>
    public static bool CheckPassword(string password, string stored)
    {
        string[] parts = stored.Split('$');
        if (parts[0] == "scrypt" && parts.Length == 3)
        {
            byte[]? expected = Decode(parts[2]);
            byte[]? salt = Decode(parts[1]);
            if (expected == null || salt == null || expected.Length < MinKeyBytes)
            {
                return false;
            }
            return SameBytes(ScryptKey(password, salt, expected.Length), expected);
        }
        if (parts[0] == "pbkdf2" && parts.Length == 4)
        {
            double rounds = Js.Number(parts[1]);
            if (!Js.IsInteger(rounds) || rounds < 1 || rounds > 10_000_000)
            {
                return false;
            }
            byte[]? expected = Decode(parts[3]);
            byte[]? salt = Decode(parts[2]);
            if (expected == null || salt == null || expected.Length < MinKeyBytes)
            {
                return false;
            }
            return SameBytes(Pbkdf2(password, salt, (int)rounds, expected.Length), expected);
        }
        return false;
    }

    /// <summary>A stored hash whose salt or key is not base64url matches nothing, rather than failing the sign-in.</summary>
    private static byte[]? Decode(string text)
    {
        try
        {
            return FromBase64url(text);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static byte[] ScryptKey(string password, byte[] salt, int length) =>
        length == 0 ? [] : Scrypt.Derive(Js.Utf8(password), salt, ScryptN, ScryptR, ScryptP, length);

    private static byte[] Pbkdf2(string password, byte[] salt, int rounds, int length) =>
        length == 0 ? [] : Rfc2898DeriveBytes.Pbkdf2(Js.Utf8(password), salt, rounds, HashAlgorithmName.SHA256, length);

    private static bool SameBytes(byte[] a, byte[] b)
    {
        int diff = a.Length ^ b.Length;
        int length = Math.Max(a.Length, b.Length);
        for (int i = 0; i < length; i++)
        {
            diff |= (i < a.Length ? a[i] : 0) ^ (i < b.Length ? b[i] : 0);
        }
        return diff == 0;
    }

    private static byte[] SealKey(string secret) => Sha256("totp:" + secret);

    /// <summary>
    /// Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
    /// standalone server has always stored two-factor secrets in. <paramref name="iv"/> is for tests; leave it out.
    /// </summary>
    public static string SealText(string text, string secret, byte[]? iv = null)
    {
        iv ??= RandomBytes(12);
        byte[] plain = Js.Utf8(text);
        var (body, tag) = Gcm(SealKey(secret), iv, plain, encrypt: true);
        return Base64url(iv) + "." + Base64url(body) + "." + Base64url(tag);
    }

    public static string? UnsealText(string sealedText, string secret)
    {
        try
        {
            string[] parts = sealedText.Split('.');
            string iv = parts[0];
            string? body = parts.Length > 1 ? parts[1] : null;
            string? tag = parts.Length > 2 ? parts[2] : null;
            if (iv.Length == 0 || body == null || string.IsNullOrEmpty(tag))
            {
                return null;
            }
            // WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell.
            byte[] bodyBytes = FromBase64url(body);
            byte[] tagBytes = FromBase64url(tag);
            byte[] joined = [.. bodyBytes, .. tagBytes];
            byte[] ivBytes = FromBase64url(iv);
            // WebCrypto refuses an IV shorter than 12 bytes.
            if (joined.Length < 16 || ivBytes.Length < 12)
            {
                return null;
            }
            var (plain, _) = Gcm(SealKey(secret), ivBytes, joined[..^16], encrypt: false, expectedTag: joined[^16..]);
            return DecodeUtf8(plain);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>TextDecoder's reading: bytes that are not UTF-8 become U+FFFD, and a leading byte order mark goes.</summary>
    private static string DecodeUtf8(byte[] bytes)
    {
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        {
            bytes = bytes[3..];
        }
        return Js.Decode(bytes);
    }

    /// <summary>
    /// AES-256-GCM with a 16-byte tag. A 12-byte IV goes through the platform's AesGcm; any other length (which
    /// WebCrypto and OpenSSL take, and AesGcm does not) through GCM written out from NIST SP 800-38D.
    /// Decrypting throws <see cref="CryptographicException"/> when the tag does not match.
    /// </summary>
    private static (byte[] Output, byte[] Tag) Gcm(byte[] key, byte[] iv, byte[] input, bool encrypt, byte[]? expectedTag = null)
    {
        var output = new byte[input.Length];
        if (iv.Length == 12)
        {
            using var aes = new AesGcm(key, 16);
            if (encrypt)
            {
                var tag = new byte[16];
                aes.Encrypt(iv, input, output, tag);
                return (output, tag);
            }
            aes.Decrypt(iv, input, expectedTag!, output);
            return (output, expectedTag!);
        }
        using var block = Aes.Create();
        block.Key = key;
        byte[] h = block.EncryptEcb(new byte[16], PaddingMode.None);
        // J0 = GHASH(IV, zero padded to a block, then a block holding the IV's length in bits).
        var j0 = new byte[16];
        GhashBlocks(h, j0, iv);
        var lengths = new byte[16];
        BinaryPrimitives.WriteUInt64BigEndian(lengths.AsSpan(8), (ulong)iv.Length * 8);
        GhashBlocks(h, j0, lengths);
        // CTR from inc32(J0).
        var counter = (byte[])j0.Clone();
        for (int at = 0; at < input.Length; at += 16)
        {
            Inc32(counter);
            byte[] stream = block.EncryptEcb(counter, PaddingMode.None);
            for (int i = 0; i < 16 && at + i < input.Length; i++)
            {
                output[at + i] = (byte)(input[at + i] ^ stream[i]);
            }
        }
        byte[] cipher = encrypt ? output : input;
        var s = new byte[16];
        GhashBlocks(h, s, cipher);
        var sizes = new byte[16];
        BinaryPrimitives.WriteUInt64BigEndian(sizes.AsSpan(8), (ulong)cipher.Length * 8);
        GhashBlocks(h, s, sizes);
        byte[] mask = block.EncryptEcb(j0, PaddingMode.None);
        var computed = new byte[16];
        for (int i = 0; i < 16; i++)
        {
            computed[i] = (byte)(s[i] ^ mask[i]);
        }
        if (!encrypt && !CryptographicOperations.FixedTimeEquals(computed, expectedTag))
        {
            Array.Clear(output);
            throw new CryptographicException("The computed authentication tag did not match the input authentication tag.");
        }
        return (output, computed);
    }

    private static void Inc32(byte[] block)
    {
        uint low = BinaryPrimitives.ReadUInt32BigEndian(block.AsSpan(12));
        BinaryPrimitives.WriteUInt32BigEndian(block.AsSpan(12), low + 1);
    }

    /// <summary>Folds data, zero padded to whole blocks, into the running GHASH value <paramref name="y"/>.</summary>
    private static void GhashBlocks(byte[] h, byte[] y, byte[] data)
    {
        ulong hHi = BinaryPrimitives.ReadUInt64BigEndian(h);
        ulong hLo = BinaryPrimitives.ReadUInt64BigEndian(h.AsSpan(8));
        var chunk = new byte[16];
        for (int at = 0; at < data.Length; at += 16)
        {
            Array.Clear(chunk);
            Array.Copy(data, at, chunk, 0, Math.Min(16, data.Length - at));
            for (int i = 0; i < 16; i++)
            {
                y[i] ^= chunk[i];
            }
            ulong xHi = BinaryPrimitives.ReadUInt64BigEndian(y);
            ulong xLo = BinaryPrimitives.ReadUInt64BigEndian(y.AsSpan(8));
            ulong zHi = 0, zLo = 0, vHi = hHi, vLo = hLo;
            for (int bit = 0; bit < 128; bit++)
            {
                ulong word = bit < 64 ? xHi : xLo;
                if (((word >> (63 - (bit & 63))) & 1) != 0)
                {
                    zHi ^= vHi;
                    zLo ^= vLo;
                }
                bool carry = (vLo & 1) != 0;
                vLo = (vLo >> 1) | (vHi << 63);
                vHi >>= 1;
                if (carry)
                {
                    vHi ^= 0xE100000000000000UL;
                }
            }
            BinaryPrimitives.WriteUInt64BigEndian(y, zHi);
            BinaryPrimitives.WriteUInt64BigEndian(y.AsSpan(8), zLo);
        }
    }

    public static string Base32(byte[] bytes)
    {
        int bits = 0;
        int value = 0;
        var output = new StringBuilder();
        foreach (byte b in bytes)
        {
            // Only the low bits are ever read, so the rest are dropped before they grow.
            value = ((value << 8) | b) & 0xffff;
            bits += 8;
            while (bits >= 5)
            {
                output.Append(Base32Letters[(value >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0)
        {
            output.Append(Base32Letters[(value << (5 - bits)) & 31]);
        }
        return output.ToString();
    }

    /// <summary>Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets come.</summary>
    public static byte[] Unbase32(string text)
    {
        int bits = 0;
        int value = 0;
        var output = new List<byte>();
        string upper = Js.Upper(text.TrimEnd('='));
        foreach (char c in upper)
        {
            int i = Base32Letters.IndexOf(c, StringComparison.Ordinal);
            if (i < 0)
            {
                continue;
            }
            value = ((value << 5) | i) & 0xffff;
            bits += 5;
            if (bits >= 8)
            {
                output.Add((byte)((value >> (bits - 8)) & 255));
                bits -= 8;
            }
        }
        return [.. output];
    }

    /// <summary>The six-digit code for a secret at a time step.</summary>
    public static string Totp(string secret, long step)
    {
        var counter = new byte[8];
        BinaryPrimitives.WriteInt64BigEndian(counter, step);
        byte[] mac = Hmac("SHA-1", Unbase32(secret), counter);
        int at = mac[19] & 15;
        long n = ((long)(mac[at] & 127) << 24) | ((long)mac[at + 1] << 16) | ((long)mac[at + 2] << 8) | mac[at + 3];
        return Js.Pad(n % 1_000_000, 6);
    }

    /// <summary>The time step a code matches, one step either side for clocks that drift, newer than <paramref name="after"/>; else null.</summary>
    public static long? MatchStep(string secret, string code, long now, long after)
    {
        long current = now / StepMs - (now < 0 && now % StepMs != 0 ? 1 : 0);
        foreach (long step in new[] { current, current - 1, current + 1 })
        {
            if (step > after && Totp(secret, step) == code)
            {
                return step;
            }
        }
        return null;
    }

    /// <summary>The address an authenticator app reads from the QR code.</summary>
    public static string OtpauthUri(string secret, string email, string host)
    {
        string label = Js.EncodeURIComponent("Runlight (" + host + "):" + email);
        return "otpauth://totp/" + label + "?secret=" + secret + "&issuer=" + Js.EncodeURIComponent("Runlight (" + host + ")") + "&algorithm=SHA1&digits=6&period=30";
    }

    /// <summary>Ten one-use recovery codes, like "k7dq-2mfa".</summary>
    public static List<string> RecoveryCodes()
    {
        var codes = new List<string>();
        for (int i = 0; i < 10; i++)
        {
            string raw = Base32(RandomBytes(5)).ToLowerInvariant();
            codes.Add(raw[..4] + "-" + raw.Substring(4, 4));
        }
        return codes;
    }

    /// <summary>What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and case do not matter.</summary>
    public static string RecoveryHash(string code)
    {
        var kept = new StringBuilder(code.Length);
        foreach (char c in code)
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                kept.Append(char.ToLowerInvariant(c));
            }
        }
        return Hex(Sha256(kept.ToString()));
    }

    /// <summary>The signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the install's secret.</summary>
    public static string Signature(string secret, string body, string hash) =>
        Base64url(Hmac("SHA-256", Js.Utf8(secret), Js.Utf8(body + "." + hash)));
}
