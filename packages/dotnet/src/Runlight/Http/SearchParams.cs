using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Runlight.Http;

/// <summary>
/// Query parameters as JavaScript's URLSearchParams reads and writes them: pairs kept in order,
/// <c>+</c> read as a space, and written back in the application/x-www-form-urlencoded form.
/// </summary>
public sealed class SearchParams : IEnumerable<KeyValuePair<string, string>>
{
    private List<KeyValuePair<string, string>> _pairs = [];

    public SearchParams()
    {
    }

    public SearchParams(string init)
    {
        if (init.StartsWith('?'))
        {
            init = init[1..];
        }
        if (init.Length == 0)
        {
            return;
        }
        foreach (string part in init.Split('&'))
        {
            if (part.Length == 0)
            {
                continue;
            }
            int at = part.IndexOf('=', StringComparison.Ordinal);
            string name = at < 0 ? part : part[..at];
            string value = at < 0 ? "" : part[(at + 1)..];
            _pairs.Add(new(Decode(name), Decode(value)));
        }
    }

    public SearchParams(IEnumerable<KeyValuePair<string, string>> init)
    {
        foreach (var e in init)
        {
            _pairs.Add(e);
        }
    }

    /// <summary>For a collection initializer.</summary>
    public void Add(string name, string value) => Append(name, value);

    public string? Get(string name)
    {
        foreach (var p in _pairs)
        {
            if (p.Key == name)
            {
                return p.Value;
            }
        }
        return null;
    }

    public List<string> GetAll(string name) => [.. _pairs.Where(p => p.Key == name).Select(p => p.Value)];

    public bool Has(string name) => _pairs.Any(p => p.Key == name);

    public void Set(string name, string value)
    {
        bool found = false;
        var pairs = new List<KeyValuePair<string, string>>();
        foreach (var p in _pairs)
        {
            if (p.Key != name)
            {
                pairs.Add(p);
            }
            else if (!found)
            {
                pairs.Add(new(name, value));
                found = true;
            }
        }
        if (!found)
        {
            pairs.Add(new(name, value));
        }
        _pairs = pairs;
    }

    public void Append(string name, string value) => _pairs.Add(new(name, value));

    public void Delete(string name) => _pairs.RemoveAll(p => p.Key == name);

    public List<string> Keys() => [.. _pairs.Select(p => p.Key)];

    public int Size => _pairs.Count;

    public IEnumerator<KeyValuePair<string, string>> GetEnumerator() => _pairs.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public override string ToString() => string.Join('&', _pairs.Select(p => Encode(p.Key) + "=" + Encode(p.Value)));

    private static string Decode(string text)
    {
        text = text.Replace('+', ' ');
        if (!text.Contains('%', StringComparison.Ordinal))
        {
            return text;
        }
        // Escapes become bytes; bytes that are not UTF-8 become U+FFFD, as URLSearchParams decodes them.
        var bytes = new List<byte>(text.Length);
        int i = 0;
        while (i < text.Length)
        {
            char c = text[i];
            if (c == '%' && i + 2 < text.Length && Js.HexDigit(text[i + 1]) >= 0 && Js.HexDigit(text[i + 2]) >= 0)
            {
                bytes.Add((byte)((Js.HexDigit(text[i + 1]) << 4) | Js.HexDigit(text[i + 2])));
                i += 3;
                continue;
            }
            int width = char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]) ? 2 : 1;
            bytes.AddRange(Js.Utf8(text.Substring(i, width)));
            i += width;
        }
        return Js.Decode([.. bytes]);
    }

    /// <summary>The form encoding: letters, digits, and <c>*-._</c> as they are, spaces as +, the rest escaped.</summary>
    public static string Encode(string text)
    {
        var b = new StringBuilder(text.Length);
        foreach (byte x in Js.Utf8(text))
        {
            char c = (char)x;
            if (char.IsAsciiLetterOrDigit(c) || c is '*' or '-' or '.' or '_')
            {
                b.Append(c);
            }
            else if (c == ' ')
            {
                b.Append('+');
            }
            else
            {
                b.Append('%').Append("0123456789ABCDEF"[x >> 4]).Append("0123456789ABCDEF"[x & 15]);
            }
        }
        return b.ToString();
    }
}
