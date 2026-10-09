using System;
using System.Security.Cryptography;
using System.Text;

namespace Runlight.Mail;

/// <summary>
/// Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
/// installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
/// <c>RUNLIGHT_SECRET</c>, or else the dashboard token. A copied database alone does not give them away.
/// The label says "mail" because mail came first; changing it would make every saved key unreadable.
/// </summary>
/// <remarks>
/// The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
/// by its 16 byte tag, so either implementation opens what the other sealed.
/// </remarks>
public static class Secret
{
    private const int TagBytes = 16;

    private static byte[] KeyFor(string secret) => SHA256.HashData(Js.Utf8("runlight-mail:" + secret));

    /// <summary><c>v1:&lt;iv&gt;:&lt;ciphertext&gt;</c>, or <c>plain:&lt;json&gt;</c> when the server has no secret to encrypt with.</summary>
    public static string Seal(string value, string? secret)
    {
        if (string.IsNullOrEmpty(secret))
        {
            return "plain:" + value;
        }
        byte[] iv = RandomNumberGenerator.GetBytes(12);
        byte[] plain = Js.Utf8(value);
        byte[] data = new byte[plain.Length + TagBytes];
        using (var aes = new AesGcm(KeyFor(secret), TagBytes))
        {
            aes.Encrypt(iv, plain, data.AsSpan(0, plain.Length), data.AsSpan(plain.Length));
        }
        return "v1:" + Convert.ToBase64String(iv) + ":" + Convert.ToBase64String(data);
    }

    /// <summary>The sealed value, or null when it cannot be opened (a different secret, or damaged).</summary>
    public static string? Unseal(string sealedValue, string? secret)
    {
        if (sealedValue.StartsWith("plain:", StringComparison.Ordinal))
        {
            return sealedValue[6..];
        }
        string[] parts = sealedValue.Split(':');
        string version = parts[0];
        string ivText = parts.Length > 1 ? parts[1] : "";
        string dataText = parts.Length > 2 ? parts[2] : "";
        if (version != "v1" || ivText.Length == 0 || dataText.Length == 0 || string.IsNullOrEmpty(secret))
        {
            return null;
        }
        byte[]? iv = Atob(ivText);
        byte[]? data = Atob(dataText);
        // Web Crypto refuses an AES-GCM IV under 12 bytes, so such a value opens nowhere. AesGcm
        // also takes no longer one, which Web Crypto would.
        if (iv == null || iv.Length != 12 || data == null || data.Length < TagBytes)
        {
            return null;
        }
        byte[] plain = new byte[data.Length - TagBytes];
        try
        {
            using var aes = new AesGcm(KeyFor(secret), TagBytes);
            aes.Decrypt(iv, data.AsSpan(0, plain.Length), data.AsSpan(plain.Length), plain);
        }
        catch (CryptographicException)
        {
            return null;
        }
        return Js.Decode(plain);
    }

    /// <summary>atob(): ASCII whitespace dropped, padding optional; null for text that is not base64.</summary>
    private static byte[]? Atob(string text)
    {
        var b = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (c is not (' ' or '\t' or '\n' or '\f' or '\r'))
            {
                b.Append(c);
            }
        }
        string s = b.ToString();
        if (s.Length % 4 == 0 && s.EndsWith('='))
        {
            s = s.EndsWith("==", StringComparison.Ordinal) ? s[..^2] : s[..^1];
        }
        if (s.Length % 4 == 1)
        {
            return null;
        }
        foreach (char c in s)
        {
            if (!(char.IsAsciiLetterOrDigit(c) || c == '+' || c == '/'))
            {
                return null;
            }
        }
        s += new string('=', (4 - (s.Length % 4)) % 4);
        try
        {
            return Convert.FromBase64String(s);
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
