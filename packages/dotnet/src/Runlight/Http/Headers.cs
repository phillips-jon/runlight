using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

namespace Runlight.Http;

/// <summary>
/// Header names are matched without regard to case, as the Fetch API's Headers are. Get joins
/// repeated values with ", "; Set-Cookie is kept apart, since its values may hold commas, and
/// read back with GetSetCookie.
/// </summary>
public sealed class Headers : IEnumerable<KeyValuePair<string, string>>
{
    // Lowercase name to values, in the order names were first set.
    private readonly OrderedDictionary<string, List<string>> _values = new(StringComparer.Ordinal);

    public Headers()
    {
    }

    public Headers(Headers init)
    {
        foreach (var e in init._values)
        {
            _values[e.Key] = [.. e.Value];
        }
    }

    public Headers(IEnumerable<KeyValuePair<string, string>> init)
    {
        foreach (var e in init)
        {
            Append(e.Key, e.Value);
        }
    }

    /// <summary>For a collection initializer: <c>new Headers { ["content-type"] = "text/plain" }</c> or <c>{ { "a", "b" } }</c>.</summary>
    public void Add(string name, string value) => Append(name, value);

    /// <summary>Get and set.</summary>
    public string? this[string name]
    {
        get => Get(name);
        set
        {
            if (value == null)
            {
                Delete(name);
            }
            else
            {
                Set(name, value);
            }
        }
    }

    public string? Get(string name)
    {
        return _values.TryGetValue(Lower(name), out var v) ? string.Join(", ", v) : null;
    }

    public bool Has(string name) => _values.ContainsKey(Lower(name));

    public void Set(string name, string value) => _values[Lower(name)] = [Clean(value)];

    public void Append(string name, string value)
    {
        string key = Lower(name);
        if (!_values.TryGetValue(key, out var list))
        {
            list = [];
            _values[key] = list;
        }
        list.Add(Clean(value));
    }

    public void Delete(string name) => _values.Remove(Lower(name));

    public IReadOnlyList<string> GetSetCookie() => _values.TryGetValue("set-cookie", out var v) ? v : [];

    /// <summary>Every lowercase name with its values, in the order the names were first set.</summary>
    public IEnumerable<KeyValuePair<string, IReadOnlyList<string>>> All() =>
        _values.Select(e => new KeyValuePair<string, IReadOnlyList<string>>(e.Key, e.Value));

    /// <summary>Name and joined value pairs in name order, as iterating Fetch Headers gives them.</summary>
    public IEnumerator<KeyValuePair<string, string>> GetEnumerator()
    {
        foreach (string name in _values.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (name == "set-cookie")
            {
                foreach (string value in _values[name])
                {
                    yield return new(name, value);
                }
            }
            else
            {
                yield return new(name, string.Join(", ", _values[name]));
            }
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    private static string Lower(string name) => name.ToLowerInvariant();

    /// <summary>Header values never carry a line break, so nothing a caller passes can add a header of its own.</summary>
    private static string Clean(string value)
    {
        if (value.AsSpan().IndexOfAny('\r', '\n', '\0') >= 0)
        {
            value = value.Replace("\r", "", StringComparison.Ordinal).Replace("\n", "", StringComparison.Ordinal).Replace("\0", "", StringComparison.Ordinal);
        }
        return value.Trim(' ', '\t', '\n', '\r', '\0', '\v');
    }
}
