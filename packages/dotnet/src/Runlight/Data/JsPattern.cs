using System.Text;
using System.Text.RegularExpressions;

namespace Runlight.Data;

/// <summary>
/// A JavaScript regular expression from the SDK's data lists, run as JavaScript runs it: <c>\d</c>,
/// <c>\w</c>, and <c>\b</c> ASCII (.NET's ECMAScript mode), <c>$</c> only at the very end, and
/// <c>i</c> folding ASCII letters alone, done by lowering the input's ASCII letters (the patterns
/// are written in lowercase).
/// </summary>
public sealed class JsPattern
{
    private readonly Regex _regex;
    private readonly bool _ignoreCase;

    public JsPattern(string source, string flags = "")
    {
        _ignoreCase = flags.Contains('i', System.StringComparison.Ordinal);
        _regex = new Regex(Convert(source), RegexOptions.ECMAScript);
    }

    public bool IsMatch(string input) => _regex.IsMatch(_ignoreCase ? AsciiLower(input) : input);

    /// <summary>Lowers ASCII letters alone, as JavaScript's /i folds them for these patterns.</summary>
    public static string AsciiLower(string s)
    {
        var b = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            b.Append(c is >= 'A' and <= 'Z' ? (char)(c + 32) : c);
        }
        return b.ToString();
    }

    /// <summary>A JavaScript source with <c>$</c> outside a class written as <c>\z</c>, which is what JavaScript's means without m.</summary>
    private static string Convert(string source)
    {
        var b = new StringBuilder(source.Length + 8);
        bool inClass = false;
        for (int i = 0; i < source.Length; i++)
        {
            char c = source[i];
            if (c == '\\' && i + 1 < source.Length)
            {
                b.Append(c).Append(source[++i]);
                continue;
            }
            if (c == '[')
            {
                inClass = true;
            }
            else if (c == ']')
            {
                inClass = false;
            }
            else if (c == '$' && !inClass)
            {
                b.Append("\\z");
                continue;
            }
            b.Append(c);
        }
        return b.ToString();
    }
}
