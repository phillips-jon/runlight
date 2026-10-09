using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Runlight.Tests.ConformanceRunner.Fake;

/// <summary>
/// Normalizing run backwards: each placeholder in an expected answer becomes a fresh value of the shape
/// that normalizes to it (24 hex digits for a whole "&lt;k&gt;", 32 for "&lt;hex&gt;" in text, an rl_ key
/// for "&lt;key&gt;", 40 hex digits for a secret query value), so the runner's masking is exercised on
/// values it has never seen. Values are made from a counter, so a run is repeatable.
/// </summary>
public sealed class Denormalizer
{
    private static readonly Regex SecretQuery = new("([?&](?:code|ticket|secret|code_challenge)=)<value>", RegexOptions.CultureInvariant);
    private static readonly Regex Hexes = new("<hex>", RegexOptions.CultureInvariant);
    private static readonly Regex Keys = new("<key>", RegexOptions.CultureInvariant);
    private static readonly Regex CookieValue = new("^([^=;]+)=<value>", RegexOptions.CultureInvariant);

    private int _made;

    public object? Value(object? value, string key = "") => value switch
    {
        List<object?> list => list.Select(v => Value(v, key)).ToList(),
        JsObject obj => JsObject.From(obj.Select(e => new KeyValuePair<string, object?>(e.Key, Value(e.Value, e.Key)))),
        string s => Text(s, key),
        _ => value,
    };

    public string Text(string text, string key = "")
    {
        if (text == "<" + (key.Length > 0 ? key : "value") + ">")
        {
            return Hex(24);
        }
        text = SecretQuery.Replace(text, m => m.Groups[1].Value + Hex(40));
        text = Hexes.Replace(text, _ => Hex(32));
        return Keys.Replace(text, _ => "rl_" + Letters(24));
    }

    /// <summary>A Set-Cookie line with a fresh value where it says &lt;value&gt;.</summary>
    public string Cookie(string line) => CookieValue.Replace(line, m => m.Groups[1].Value + "=" + Letters(16), 1);

    public string Hex(int length)
    {
        var output = new StringBuilder();
        while (output.Length < length)
        {
            output.Append(System.Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("fake " + (_made++).ToString(CultureInfo.InvariantCulture)))));
        }
        return output.ToString()[..length];
    }

    /// <summary>Letters that are never hex digits, so no run of them reads as hex.</summary>
    public string Letters(int length)
    {
        const string alphabet = "GHJKMNPQRSTVWXYZghjkmnpqrstvwxyz";
        string hex = Hex(length);
        var output = new StringBuilder();
        foreach (char c in hex)
        {
            output.Append(alphabet[(int.Parse(c.ToString(), NumberStyles.HexNumber, CultureInfo.InvariantCulture) * 2 % 32) + (_made % 2)]);
        }
        return output.ToString();
    }
}
