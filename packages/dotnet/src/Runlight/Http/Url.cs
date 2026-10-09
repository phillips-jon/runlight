using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Runlight.Http;

/// <summary>
/// An absolute http or https URL, parsed the way browsers and JavaScript's URL do for those
/// schemes: the host lowercased, backslashes read as slashes, dot segments resolved, and the
/// path and query percent-encoded with the WHATWG sets, so a path recorded here matches what the
/// tracker sent and what the TypeScript SDK stores.
/// </summary>
public sealed class Url
{
    public string Protocol { get; private set; } = "";
    public string Username { get; private set; } = "";
    public string Password { get; private set; } = "";
    public string Hostname { get; set; } = "";
    public string Port { get; set; } = "";
    public string Pathname { get; private set; } = "";
    public string Search { get; private set; } = "";
    public string Hash { get; set; } = "";

    /// <summary>A URL of another scheme written with an authority, such as android-app://com.google.android.gm/.</summary>
    private bool _hasAuthority;

    private static readonly Dictionary<string, string> DefaultPorts = new(StringComparer.Ordinal)
    {
        ["http:"] = "80",
        ["https:"] = "443",
        ["ws:"] = "80",
        ["wss:"] = "443",
        ["ftp:"] = "21",
    };

    private static readonly IdnMapping Idn = new() { AllowUnassigned = true, UseStd3AsciiRules = false };

    /// <summary>Throws <see cref="ArgumentException"/> when <paramref name="input"/> is not a URL, as <c>new URL()</c> throws a TypeError.</summary>
    public Url(string input, string? baseUrl = null)
    {
        input = input.Trim(C0AndSpace());
        input = input.Replace("\t", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal).Replace("\r", "", StringComparison.Ordinal);
        int colon = SchemeEnd(input);
        if (colon < 0)
        {
            if (baseUrl == null)
            {
                throw new ArgumentException("Invalid URL: " + input);
            }
            Resolve(input, new Url(baseUrl));
            return;
        }
        Protocol = input[..colon].ToLowerInvariant() + ":";
        string rest = input[(colon + 1)..];
        if (!DefaultPorts.ContainsKey(Protocol))
        {
            // Not a special scheme (mailto:, data:, javascript:): kept as it came.
            Hostname = "";
            Port = "";
            if (rest.StartsWith("//", StringComparison.Ordinal))
            {
                // An authority after the scheme is an opaque host, kept in its case.
                rest = rest[2..];
                int stop = IndexOfAny(rest, "/?#");
                OpaqueAuthority(rest[..stop]);
                _hasAuthority = true;
                Tail(rest[stop..], "");
                return;
            }
            (rest, string hash) = Cut(rest, '#');
            Hash = hash;
            (string path, string search) = Cut(rest, '?');
            Pathname = path;
            Search = search;
            return;
        }
        rest = rest.Replace('\\', '/').TrimStart('/');
        int end = IndexOfAny(rest, "/?#");
        Authority(rest[..end]);
        Tail(rest[end..], "/");
    }

    private static char[] C0AndSpace()
    {
        var chars = new char[0x21];
        for (int i = 0; i <= 0x20; i++)
        {
            chars[i] = (char)i;
        }
        return chars;
    }

    /// <summary>The index of the colon after a scheme (<c>[a-zA-Z][a-zA-Z0-9+.-]*:</c>), or -1.</summary>
    private static int SchemeEnd(string input)
    {
        if (input.Length == 0 || !char.IsAsciiLetter(input[0]))
        {
            return -1;
        }
        for (int i = 1; i < input.Length; i++)
        {
            char c = input[i];
            if (c == ':')
            {
                return i;
            }
            if (!char.IsAsciiLetterOrDigit(c) && c != '+' && c != '.' && c != '-')
            {
                return -1;
            }
        }
        return -1;
    }

    private static int IndexOfAny(string text, string marks)
    {
        int at = text.AsSpan().IndexOfAny(marks);
        return at < 0 ? text.Length : at;
    }

    public static Url? Parse(string input, string? baseUrl = null)
    {
        try
        {
            return new Url(input, baseUrl);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    public static bool CanParse(string input, string? baseUrl = null) => Parse(input, baseUrl) != null;

    public string Host => Port.Length == 0 ? Hostname : Hostname + ":" + Port;

    public string Origin => DefaultPorts.ContainsKey(Protocol) ? Protocol + "//" + Host : "null";

    public string Href
    {
        get
        {
            if (!DefaultPorts.ContainsKey(Protocol) && !_hasAuthority)
            {
                return Protocol + Pathname + Search + Hash;
            }
            string auth = Username.Length > 0 || Password.Length > 0 ? Username + (Password.Length > 0 ? ":" + Password : "") + "@" : "";
            return Protocol + "//" + auth + Host + Pathname + Search + Hash;
        }
    }

    public override string ToString() => Href;

    public SearchParams SearchParams => new(Search);

    /// <summary>Replaces the query with these parameters, as assigning url.search does.</summary>
    public void SetSearchParams(SearchParams parameters)
    {
        string text = parameters.ToString();
        Search = text.Length == 0 ? "" : "?" + text;
    }

    /// <summary>Replaces the path, as assigning url.pathname does.</summary>
    public void SetPathname(string path)
    {
        path = path.Replace("\t", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal).Replace("\r", "", StringComparison.Ordinal);
        if (DefaultPorts.ContainsKey(Protocol))
        {
            path = path.Replace('\\', '/');
        }
        Pathname = PathOf(path.Length == 0 || path[0] != '/' ? "/" + path : path);
    }

    /// <summary>
    /// Replaces the query, as assigning url.search does for http and https: one leading "?" is
    /// dropped and the rest percent-encoded, and an empty value removes the query.
    /// </summary>
    public void SetSearch(string search)
    {
        if (search.Length == 0)
        {
            Search = "";
            return;
        }
        search = search.Replace("\t", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal).Replace("\r", "", StringComparison.Ordinal);
        Search = "?" + Query(search.StartsWith('?') ? search[1..] : search);
    }

    private void Resolve(string input, Url baseUrl)
    {
        Protocol = baseUrl.Protocol;
        bool special = DefaultPorts.ContainsKey(Protocol);
        if (special)
        {
            input = input.Replace('\\', '/');
        }
        if (input.StartsWith("//", StringComparison.Ordinal))
        {
            // A special scheme skips any further slashes before the host: ///x is the host x.
            string rest = special ? input.TrimStart('/') : input[2..];
            int end = IndexOfAny(rest, "/?#");
            Authority(rest[..end]);
            Tail(rest[end..], "/");
            return;
        }
        Username = baseUrl.Username;
        Password = baseUrl.Password;
        Hostname = baseUrl.Hostname;
        Port = baseUrl.Port;
        if (input.Length == 0)
        {
            Pathname = baseUrl.Pathname;
            Search = baseUrl.Search;
            Hash = "";
            return;
        }
        if (input[0] == '#')
        {
            Pathname = baseUrl.Pathname;
            Search = baseUrl.Search;
            Hash = input.Length > 1 ? "#" + Fragment(input[1..]) : "";
            return;
        }
        if (input[0] == '?')
        {
            Pathname = baseUrl.Pathname;
            var (query, hash) = Cut(input[1..], '#');
            Search = query.Length == 0 ? "" : "?" + Query(query);
            Hash = hash.Length == 0 ? "" : "#" + Fragment(hash[1..]);
            return;
        }
        if (input[0] == '/')
        {
            Tail(input, "/");
            return;
        }
        string dir = baseUrl.Pathname[..(baseUrl.Pathname.LastIndexOf('/') + 1)];
        Tail(dir + input, "/");
    }

    private void Authority(string authority)
    {
        int at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            string user = authority[..at];
            authority = authority[(at + 1)..];
            var (name, pass) = Cut(user, ':');
            Username = Encode(name, Userinfo);
            Password = pass.Length == 0 ? "" : Encode(pass[1..], Userinfo);
        }
        string port = "";
        string host;
        if (authority.StartsWith('['))
        {
            int close = authority.IndexOf(']', StringComparison.Ordinal);
            if (close < 0)
            {
                throw new ArgumentException("Invalid URL");
            }
            host = authority[..(close + 1)].ToLowerInvariant();
            string after = authority[(close + 1)..];
            if (after.Length > 0)
            {
                if (after[0] != ':')
                {
                    throw new ArgumentException("Invalid URL");
                }
                port = after[1..];
            }
        }
        else
        {
            int colon = authority.LastIndexOf(':');
            host = colon < 0 ? authority : authority[..colon];
            port = colon < 0 ? "" : authority[(colon + 1)..];
            host = Domain(host);
        }
        if (host.Length == 0)
        {
            throw new ArgumentException("Invalid URL");
        }
        if (port.Length > 0)
        {
            port = PortNumber(port);
            if (port == DefaultPorts[Protocol])
            {
                port = "";
            }
        }
        Hostname = host;
        Port = port;
    }

    /// <summary>A port of digits up to 65535, written without leading zeros.</summary>
    private static string PortNumber(string port)
    {
        foreach (char c in port)
        {
            if (!char.IsAsciiDigit(c))
            {
                throw new ArgumentException("Invalid URL");
            }
        }
        string trimmed = port.TrimStart('0');
        if (trimmed.Length > 5 || (trimmed.Length > 0 && int.Parse(trimmed, CultureInfo.InvariantCulture) > 65535))
        {
            throw new ArgumentException("Invalid URL");
        }
        return trimmed.Length == 0 ? "0" : trimmed;
    }

    private void OpaqueAuthority(string authority)
    {
        int at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            var (name, pass) = Cut(authority[..at], ':');
            Username = Encode(name, Userinfo);
            Password = pass.Length == 0 ? "" : Encode(pass[1..], Userinfo);
            authority = authority[(at + 1)..];
        }
        int colon = authority.LastIndexOf(':');
        string host = colon < 0 ? authority : authority[..colon];
        string port = colon < 0 ? "" : authority[(colon + 1)..];
        if (host.AsSpan().IndexOfAny("\0 #/:<>?@[\\]^|") >= 0)
        {
            throw new ArgumentException("Invalid URL");
        }
        Hostname = Encode(host, "");
        Port = port.Length == 0 ? "" : PortNumber(port);
    }

    private void Tail(string rest, string empty)
    {
        var (beforeHash, hash) = Cut(rest, '#');
        var (path, query) = Cut(beforeHash, '?');
        Pathname = path.Length == 0 && empty.Length == 0 ? "" : PathOf(path.Length == 0 ? empty : path);
        Search = query.Length > 1 ? "?" + Query(query[1..]) : "";
        Hash = hash.Length > 1 ? "#" + Fragment(hash[1..]) : "";
    }

    /// <summary>The part before <paramref name="mark"/>, and the rest starting with it.</summary>
    private static (string, string) Cut(string text, char mark)
    {
        int at = text.IndexOf(mark, StringComparison.Ordinal);
        return at < 0 ? (text, "") : (text[..at], text[at..]);
    }

    private static string Domain(string host)
    {
        host = PercentDecode(host);
        foreach (char c in host)
        {
            if (c <= 0x20 || "#%/:<>?@[\\]^|".Contains(c, StringComparison.Ordinal))
            {
                throw new ArgumentException("Invalid URL");
            }
        }
        string lower = host.ToLowerInvariant();
        bool ascii = true;
        foreach (char c in lower)
        {
            if (c > 0x7f)
            {
                ascii = false;
                break;
            }
        }
        if (!ascii)
        {
            try
            {
                lower = Idn.GetAscii(lower);
            }
            catch (ArgumentException)
            {
                throw new ArgumentException("Invalid URL");
            }
        }
        return Ipv4(lower) ?? lower;
    }

    /// <summary>rawurldecode: each %XX as its byte, the bytes read as UTF-8 (U+FFFD where they are not).</summary>
    private static string PercentDecode(string text)
    {
        if (!text.Contains('%', StringComparison.Ordinal))
        {
            return text;
        }
        var bytes = new List<byte>();
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c == '%' && i + 2 < text.Length && Js.HexDigit(text[i + 1]) >= 0 && Js.HexDigit(text[i + 2]) >= 0)
            {
                bytes.Add((byte)((Js.HexDigit(text[i + 1]) << 4) | Js.HexDigit(text[i + 2])));
                i += 2;
                continue;
            }
            int width = char.IsHighSurrogate(c) && i + 1 < text.Length ? 2 : 1;
            bytes.AddRange(Js.Utf8(text.Substring(i, width)));
            i += width - 1;
        }
        return Js.Decode([.. bytes]);
    }

    /// <summary>A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal.</summary>
    private static string? Ipv4(string host)
    {
        var parts = new List<string>(host.Split('.'));
        if (parts[^1].Length == 0)
        {
            parts.RemoveAt(parts.Count - 1);
        }
        if (parts.Count == 0 || parts.Count > 4)
        {
            return null;
        }
        string last = parts[^1];
        if (!IsNumberPart(last))
        {
            return null;
        }
        var numbers = new List<double>();
        foreach (string part in parts)
        {
            if (part.StartsWith("0x", StringComparison.Ordinal) && IsHex(part[2..]))
            {
                numbers.Add(part.Length == 2 ? 0 : ParseRadix(part[2..], 16));
            }
            else if (part.Length > 1 && part[0] == '0' && IsRadix(part, 8))
            {
                numbers.Add(ParseRadix(part, 8));
            }
            else if (part.Length > 0 && IsRadix(part, 10))
            {
                numbers.Add(ParseRadix(part, 10));
            }
            else
            {
                throw new ArgumentException("Invalid URL");
            }
        }
        double value = numbers[^1];
        numbers.RemoveAt(numbers.Count - 1);
        foreach (double n in numbers)
        {
            if (n > 255)
            {
                throw new ArgumentException("Invalid URL");
            }
        }
        if (value >= Math.Pow(256, 5 - parts.Count))
        {
            throw new ArgumentException("Invalid URL");
        }
        for (int i = 0; i < numbers.Count; i++)
        {
            value += numbers[i] * Math.Pow(256, 3 - i);
        }
        long v = (long)value;
        return string.Join('.', (v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255);
    }

    private static bool IsNumberPart(string s)
    {
        if (s.StartsWith("0x", StringComparison.Ordinal))
        {
            return IsHex(s[2..]);
        }
        return s.Length > 0 && IsRadix(s, 10);
    }

    private static bool IsHex(string s)
    {
        foreach (char c in s)
        {
            if (!char.IsAsciiDigit(c) && (c < 'a' || c > 'f'))
            {
                return false;
            }
        }
        return true;
    }

    private static bool IsRadix(string s, int radix)
    {
        foreach (char c in s)
        {
            if (c < '0' || c >= '0' + radix)
            {
                return false;
            }
        }
        return true;
    }

    private static double ParseRadix(string s, int radix)
    {
        double v = 0;
        foreach (char c in s)
        {
            v = v * radix + Js.HexDigit(c);
        }
        return v;
    }

    private const string PathSet = " \"#<>?`{}";
    private const string QuerySet = " \"#<>'";
    private const string FragmentSet = " \"<>`";
    private const string Userinfo = " \"#<>?`{}/:;=@[\\]^|";

    private static string PathOf(string path)
    {
        var output = new List<string>();
        string[] segments = path.Split('/');
        int count = segments.Length - 1;
        for (int i = 1; i < segments.Length; i++)
        {
            string segment = segments[i];
            string lower = segment.ToLowerInvariant();
            bool last = i == count;
            if (lower is ".." or ".%2e" or "%2e." or "%2e%2e")
            {
                if (output.Count > 0)
                {
                    output.RemoveAt(output.Count - 1);
                }
                if (last)
                {
                    output.Add("");
                }
            }
            else if (lower is "." or "%2e")
            {
                if (last)
                {
                    output.Add("");
                }
            }
            else
            {
                output.Add(Encode(segment, PathSet));
            }
        }
        return "/" + string.Join('/', output);
    }

    private static string Query(string query) => Encode(query, QuerySet);

    private static string Fragment(string fragment) => Encode(fragment, FragmentSet);

    /// <summary>Percent-encodes C0 controls, DEL, bytes past ASCII, and <paramref name="extra"/>; existing escapes stay as written.</summary>
    public static string Encode(string text, string extra)
    {
        bool plain = true;
        foreach (char c in text)
        {
            if (c < 0x21 || c > 0x7e || extra.Contains(c, StringComparison.Ordinal))
            {
                plain = false;
                break;
            }
        }
        if (plain)
        {
            return text;
        }
        var b = new StringBuilder(text.Length + 8);
        foreach (byte o in Js.Utf8(text))
        {
            if (o < 0x21 || o > 0x7e || extra.Contains((char)o, StringComparison.Ordinal))
            {
                b.Append('%').Append("0123456789ABCDEF"[o >> 4]).Append("0123456789ABCDEF"[o & 15]);
            }
            else
            {
                b.Append((char)o);
            }
        }
        return b.ToString();
    }
}
