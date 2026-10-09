using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Runlight;

/// <summary>
/// Why text is not JSON, with <c>JSON.parse</c>'s wording and the position in UTF-16 units.
/// Named apart from <c>System.Text.Json.JsonException</c>, so an app importing both namespaces
/// can name either.
/// </summary>
public sealed class JsonParseException : Exception
{
    public JsonParseException()
    {
    }

    public JsonParseException(string message)
        : base(message)
    {
    }

    public JsonParseException(string message, Exception inner)
        : base(message, inner)
    {
    }
}

/// <summary>A value that writes itself as JSON through the value it gives back, as toJSON() does.</summary>
public interface IJsonValue
{
    /// <summary>The value written in its place.</summary>
    object? ToJsonValue();
}

/// <summary>
/// JSON written exactly as JavaScript's JSON.stringify writes it, so answers match the
/// TypeScript SDK byte for byte: slashes and Unicode as they are, whole numbers without a
/// decimal point, numbers in JavaScript's own form, and NaN or infinity as null.
/// </summary>
/// <remarks>
/// Values are <c>null</c>, <see cref="Undefined"/> (a field holding it is left out), a
/// <see cref="bool"/>, a number, a <see cref="string"/>, a <see cref="JsObject"/> (or any
/// dictionary with string keys), or a list. Parsing gives numbers as <see cref="double"/>,
/// objects as <see cref="JsObject"/>, and arrays as <c>List&lt;object?&gt;</c>.
/// </remarks>
public static class Json
{
    /// <summary>How deep arrays and objects may nest when written.</summary>
    public const int MaxDepth = 512;

    /// <summary>How deep arrays and objects may nest when read: past anything a body of a few megabytes holds.</summary>
    public const int MaxParseDepth = 10_000_000;

    /// <summary><c>JSON.stringify(value)</c>, or with <paramref name="pretty"/> <c>JSON.stringify(value, null, 2)</c>.</summary>
    public static string Stringify(object? value, bool pretty = false)
    {
        var b = new StringBuilder();
        if (pretty)
        {
            WritePretty(b, value, "", 0);
        }
        else
        {
            Write(b, value, 0);
        }
        return b.ToString();
    }

    /// <summary>A number as JavaScript's String(number) writes it.</summary>
    public static string Number(double n) => double.IsFinite(n) ? Js.FormatNumber(n) : "null";

    /// <summary>The value as JSON sees it: a typed value given as the plain value it stands for.</summary>
    private static object? Plain(object? v) => v is IJsonValue j ? j.ToJsonValue() : v;

    private static void Write(StringBuilder b, object? v, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new ArgumentException("JSON nested too deeply");
        }
        v = Plain(v);
        switch (v)
        {
            case null:
            case Undefined:
                b.Append("null");
                break;
            case bool x:
                b.Append(x ? "true" : "false");
                break;
            case double d:
                b.Append(double.IsFinite(d) ? Js.FormatNumber(d) : "null");
                break;
            case float f:
                b.Append(float.IsFinite(f) ? Js.FormatNumber(f) : "null");
                break;
            case long l:
                b.Append(Js.FormatLong(l));
                break;
            case int i:
                b.Append(i.ToString(CultureInfo.InvariantCulture));
                break;
            case short s:
                b.Append(s.ToString(CultureInfo.InvariantCulture));
                break;
            case byte y:
                b.Append(y.ToString(CultureInfo.InvariantCulture));
                break;
            case uint ui:
                b.Append(ui.ToString(CultureInfo.InvariantCulture));
                break;
            case decimal m:
                b.Append(Js.FormatNumber((double)m));
                break;
            case string s:
                QuoteInto(b, s);
                break;
            case JsObject o:
                {
                    b.Append('{');
                    bool first = true;
                    foreach (var e in o)
                    {
                        object? item = Plain(e.Value);
                        if (item is Undefined)
                        {
                            continue;
                        }
                        if (!first)
                        {
                            b.Append(',');
                        }
                        first = false;
                        QuoteInto(b, e.Key);
                        b.Append(':');
                        Write(b, item, depth + 1);
                    }
                    b.Append('}');
                    break;
                }
            case IEnumerable<KeyValuePair<string, object?>> map:
                Write(b, JsObject.From(map), depth);
                break;
            case IDictionary dict:
                {
                    var o = new JsObject();
                    foreach (DictionaryEntry e in dict)
                    {
                        o.Set(Convert.ToString(e.Key, CultureInfo.InvariantCulture) ?? "", e.Value);
                    }
                    Write(b, o, depth);
                    break;
                }
            case IEnumerable list:
                {
                    b.Append('[');
                    bool first = true;
                    foreach (var x in list)
                    {
                        if (!first)
                        {
                            b.Append(',');
                        }
                        first = false;
                        Write(b, x, depth + 1);
                    }
                    b.Append(']');
                    break;
                }
            default:
                throw new ArgumentException("cannot write a " + v.GetType().Name + " as JSON");
        }
    }

    private static void WritePretty(StringBuilder b, object? v, string indent, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new ArgumentException("JSON nested too deeply");
        }
        v = Plain(v);
        string inner = indent + "  ";
        if (v is IEnumerable<KeyValuePair<string, object?>> map and not JsObject)
        {
            v = JsObject.From(map);
        }
        if (v is JsObject o)
        {
            bool any = false;
            foreach (var e in o)
            {
                object? item = Plain(e.Value);
                if (item is Undefined)
                {
                    continue;
                }
                b.Append(any ? ",\n" : "{\n");
                any = true;
                b.Append(inner);
                QuoteInto(b, e.Key);
                b.Append(": ");
                WritePretty(b, item, inner, depth + 1);
            }
            b.Append(any ? "\n" + indent + "}" : "{}");
            return;
        }
        if (v is IEnumerable list and not string)
        {
            bool any = false;
            foreach (var x in list)
            {
                b.Append(any ? ",\n" : "[\n");
                any = true;
                b.Append(inner);
                WritePretty(b, x, inner, depth + 1);
            }
            b.Append(any ? "\n" + indent + "]" : "[]");
            return;
        }
        Write(b, v, depth);
    }

    /// <summary><c>JSON.stringify</c> of a string.</summary>
    public static string Quote(string s)
    {
        var b = new StringBuilder(s.Length + 2);
        QuoteInto(b, s);
        return b.ToString();
    }

    private const string Hex = "0123456789abcdef";

    private static void QuoteInto(StringBuilder b, string s)
    {
        b.Append('"');
        int n = s.Length;
        int start = 0;
        for (int i = 0; i < n; i++)
        {
            char c = s[i];
            if (c >= 0x20 && c != '"' && c != '\\' && !char.IsSurrogate(c))
            {
                continue;
            }
            if (char.IsHighSurrogate(c) && i + 1 < n && char.IsLowSurrogate(s[i + 1]))
            {
                i++;
                continue;
            }
            b.Append(s, start, i - start);
            switch (c)
            {
                case '"':
                    b.Append("\\\"");
                    break;
                case '\\':
                    b.Append("\\\\");
                    break;
                case '\b':
                    b.Append("\\b");
                    break;
                case '\f':
                    b.Append("\\f");
                    break;
                case '\n':
                    b.Append("\\n");
                    break;
                case '\r':
                    b.Append("\\r");
                    break;
                case '\t':
                    b.Append("\\t");
                    break;
                default:
                    b.Append("\\u").Append(Hex[(c >> 12) & 0xf]).Append(Hex[(c >> 8) & 0xf])
                        .Append(Hex[(c >> 4) & 0xf]).Append(Hex[c & 0xf]);
                    break;
            }
            start = i + 1;
        }
        b.Append(s, start, n - start);
        b.Append('"');
    }

    /// <summary>
    /// <c>JSON.parse</c>: numbers as <see cref="double"/>, objects as <see cref="JsObject"/> in
    /// JavaScript's key order (a key given twice keeps its first place and its last value), arrays
    /// as <c>List&lt;object?&gt;</c>.
    /// </summary>
    /// <exception cref="JsonParseException">When the text is not JSON.</exception>
    public static object? Parse(string text)
    {
        var p = new Parser(text);
        p.Space();
        object? v = p.Value(0);
        p.Space();
        if (p.I < text.Length)
        {
            throw p.Fail("Unexpected non-whitespace character after JSON");
        }
        return v;
    }

    /// <summary>Whether the text parsed, and the value: <see cref="Parse"/> without the throw.</summary>
    public static bool TryParse(string text, out object? value)
    {
        try
        {
            value = Parse(text);
            return true;
        }
        catch (JsonParseException)
        {
            value = null;
            return false;
        }
    }

    /// <summary><see cref="Parse"/>, or null for text that is not JSON.</summary>
    public static object? TryParse(string text) => TryParse(text, out object? v) ? v : null;

    /// <summary>A value's type as JavaScript's <c>typeof</c> names it, for messages.</summary>
    public static string KindOf(object? v) => v switch
    {
        null => "object",
        Undefined => "undefined",
        bool => "boolean",
        double or float or long or int or short or byte or uint or decimal => "number",
        string => "string",
        _ => "object",
    };

    /// <summary>Whether a value is a number, and which.</summary>
    public static bool TryNumberOf(object? v, out double n)
    {
        switch (v)
        {
            case double d:
                n = d;
                return true;
            case long l:
                n = l;
                return true;
            case int i:
                n = i;
                return true;
            case float f:
                n = f;
                return true;
            case short s:
                n = s;
                return true;
            case byte y:
                n = y;
                return true;
            case uint u:
                n = u;
                return true;
            case decimal m:
                n = (double)m;
                return true;
            default:
                n = 0;
                return false;
        }
    }

    private sealed class Parser(string s)
    {
        public int I;

        public JsonParseException Fail(string what) =>
            new(what + " at position " + I.ToString(CultureInfo.InvariantCulture));

        public void Space()
        {
            while (I < s.Length)
            {
                char c = s[I];
                if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
                {
                    return;
                }
                I++;
            }
        }

        private bool At(char c) => I < s.Length && s[I] == c;

        private bool StartsHere(string word) => string.CompareOrdinal(s, I, word, 0, word.Length) == 0;

        public object? Value(int depth)
        {
            // Iterative, so text nested thousands deep (a tracker body may be) reads as JSON.parse
            // reads it without running out of stack.
            var stack = new Stack<object>();
            var keys = new Stack<string>();
            object? done;
            while (true)
            {
                if (I >= s.Length)
                {
                    throw Fail("Unexpected end of JSON input");
                }
                char c = s[I];
                if (c == '{' || c == '[')
                {
                    if (stack.Count + depth >= MaxParseDepth)
                    {
                        throw new JsonParseException("JSON nested too deeply");
                    }
                    I++;
                    Space();
                    if (c == '{')
                    {
                        if (At('}'))
                        {
                            I++;
                            done = new JsObject();
                        }
                        else
                        {
                            stack.Push(new JsObject());
                            keys.Push(Key());
                            continue;
                        }
                    }
                    else if (At(']'))
                    {
                        I++;
                        done = new List<object?>();
                    }
                    else
                    {
                        stack.Push(new List<object?>());
                        continue;
                    }
                }
                else
                {
                    done = Scalar(c);
                }
                // Hand the finished value to the containers that hold it, closing each one that ends.
                while (true)
                {
                    if (stack.Count == 0)
                    {
                        return done;
                    }
                    object top = stack.Peek();
                    Space();
                    if (top is JsObject o)
                    {
                        o.Set(keys.Pop(), done);
                        if (At(','))
                        {
                            I++;
                            keys.Push(Key());
                            break;
                        }
                        if (At('}'))
                        {
                            I++;
                            done = stack.Pop();
                            continue;
                        }
                        throw Fail("Expected ',' or '}' after property value");
                    }
                    var list = (List<object?>)top;
                    list.Add(done);
                    if (At(','))
                    {
                        I++;
                        Space();
                        break;
                    }
                    if (At(']'))
                    {
                        I++;
                        done = stack.Pop();
                        continue;
                    }
                    throw Fail("Expected ',' or ']' after array element");
                }
            }
        }

        /// <summary>An object's key and its colon, the space around them skipped.</summary>
        private string Key()
        {
            Space();
            if (!At('"'))
            {
                throw Fail("Expected property name");
            }
            string k = String();
            Space();
            if (!At(':'))
            {
                throw Fail("Expected ':' after property name");
            }
            I++;
            Space();
            return k;
        }

        private object? Scalar(char c)
        {
            switch (c)
            {
                case '"':
                    return String();
                case 't':
                    if (StartsHere("true"))
                    {
                        I += 4;
                        return true;
                    }
                    throw Fail("Unexpected token");
                case 'f':
                    if (StartsHere("false"))
                    {
                        I += 5;
                        return false;
                    }
                    throw Fail("Unexpected token");
                case 'n':
                    if (StartsHere("null"))
                    {
                        I += 4;
                        return null;
                    }
                    throw Fail("Unexpected token");
                default:
                    if (c == '-' || (c >= '0' && c <= '9'))
                    {
                        return Number();
                    }
                    throw Fail("Unexpected token");
            }
        }

        private int Digits()
        {
            int from = I;
            while (I < s.Length && s[I] >= '0' && s[I] <= '9')
            {
                I++;
            }
            return I - from;
        }

        private double Number()
        {
            int start = I;
            if (At('-'))
            {
                I++;
            }
            if (At('0'))
            {
                I++;
            }
            else if (Digits() == 0)
            {
                throw Fail("No number after minus sign");
            }
            if (At('.'))
            {
                I++;
                if (Digits() == 0)
                {
                    throw Fail("Unterminated fractional number");
                }
            }
            if (At('e') || At('E'))
            {
                I++;
                if (At('+') || At('-'))
                {
                    I++;
                }
                if (Digits() == 0)
                {
                    throw Fail("Exponent part is missing a number");
                }
            }
            // Out of range reads as JavaScript reads it: Infinity or 0.
            return double.Parse(s.AsSpan(start, I - start), NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        private int Hex4()
        {
            if (I + 4 > s.Length)
            {
                return -1;
            }
            int n = 0;
            for (int k = 0; k < 4; k++)
            {
                char ch = s[I + k];
                int d = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
                if (d < 0)
                {
                    return -1;
                }
                n = n * 16 + d;
            }
            I += 4;
            return n;
        }

        private string String()
        {
            I++; // the opening quote
            var b = new StringBuilder();
            int start = I;
            while (I < s.Length)
            {
                char c = s[I];
                if (c == '"')
                {
                    b.Append(s, start, I - start);
                    I++;
                    return b.ToString();
                }
                if (c < 0x20)
                {
                    throw Fail("Bad control character in string literal");
                }
                if (c == '\\')
                {
                    b.Append(s, start, I - start);
                    I++;
                    if (I >= s.Length)
                    {
                        throw Fail("Unterminated string");
                    }
                    char e = s[I++];
                    switch (e)
                    {
                        case '"':
                        case '\\':
                        case '/':
                            b.Append(e);
                            break;
                        case 'b':
                            b.Append('\b');
                            break;
                        case 'f':
                            b.Append('\f');
                            break;
                        case 'n':
                            b.Append('\n');
                            break;
                        case 'r':
                            b.Append('\r');
                            break;
                        case 't':
                            b.Append('\t');
                            break;
                        case 'u':
                            int u = Hex4();
                            if (u < 0)
                            {
                                throw Fail("Bad Unicode escape");
                            }
                            b.Append((char)u);
                            break;
                        default:
                            throw Fail("Bad escaped character");
                    }
                    start = I;
                    continue;
                }
                I++;
            }
            throw Fail("Unterminated string");
        }
    }
}
