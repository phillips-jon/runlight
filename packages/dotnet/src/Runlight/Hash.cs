using System;
using System.Security.Cryptography;

namespace Runlight;

public static class Hash
{
    public static string Sha256(string text) => Convert.ToHexStringLower(SHA256.HashData(Js.Utf8(text)));

    public static string Sha256(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    /// <summary>HMAC-SHA-256 of text under key, as hex.</summary>
    public static string Hmac(string key, string text) => Convert.ToHexStringLower(HMACSHA256.HashData(Js.Utf8(key), Js.Utf8(text)));

    /// <summary>
    /// The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to 64 bits. The salt
    /// changes every day and old salts are deleted, so the hash cannot be recomputed and does not
    /// follow anyone across days.
    /// </summary>
    public static string VisitorHash(string salt, string site, string ip, string ua) =>
        Sha256(salt + "\n" + site + "\n" + ip + "\n" + ua)[..16];

    public static string RandomId(int bytes = 12) => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(bytes));

    public static string RandomSalt() => RandomId(32);
}
