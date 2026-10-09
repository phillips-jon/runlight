using System;
using System.Collections.Concurrent;
using System.IO;

namespace Runlight.Tests;

/// <summary>
/// The language-neutral fixtures the TypeScript SDK writes: packages/php/tests/fixtures (from the
/// scripts/php-fixtures-*.mts scripts) and conformance/, read where they are.
/// </summary>
public static class Fixtures
{
    private static readonly ConcurrentDictionary<string, object?> Loaded = new(StringComparer.Ordinal);

    /// <summary>The repository's root, found by walking up to the folder that holds conformance/.</summary>
    public static string Root { get; } = FindRoot();

    private static string FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "conformance")) && Directory.Exists(Path.Combine(dir.FullName, "packages")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new InvalidOperationException("repository root not found");
    }

    public static string FixturePath(string name) => Path.Combine(Root, "packages", "php", "tests", "fixtures", name);

    /// <summary>A fixture from packages/php/tests/fixtures, parsed.</summary>
    public static JsObject Load(string name) =>
        (JsObject)Loaded.GetOrAdd("f:" + name, _ => Json.Parse(File.ReadAllText(FixturePath(name + ".json"))))!;

    /// <summary>A file from conformance/, parsed.</summary>
    public static JsObject Conformance(string name) =>
        (JsObject)Loaded.GetOrAdd("c:" + name, _ => Json.Parse(File.ReadAllText(Path.Combine(Root, "conformance", name + ".json"))))!;

    /// <summary>A short label for a case, for messages.</summary>
    public static string Label(object? value)
    {
        string text = value is string s ? s : Json.Stringify(value);
        return text.Length > 160 ? text[..160] + "..." : text;
    }

    /// <summary>Fails with the first failures written out whole, one to a line.</summary>
    public static void NoFailures(System.Collections.Generic.IReadOnlyCollection<string> failures, int show = 20)
    {
        if (failures.Count > 0)
        {
            Xunit.Assert.Fail(failures.Count + " failures:\n" + string.Join("\n", System.Linq.Enumerable.Take(failures, show)));
        }
    }

    /// <summary>The JSON of a value, for comparing a whole answer with what the fixture holds.</summary>
    public static string J(object? value) => Json.Stringify(value);

    /// <summary>
    /// A value with every string as it reads once written out as UTF-8 (a lone surrogate as U+FFFD),
    /// which is how the PHP fixtures hold text a cut left half a pair of.
    /// </summary>
    public static object? Wf(object? value) => value switch
    {
        string s => Js.WellFormed(s),
        JsObject o => JsObject.From(System.Linq.Enumerable.Select(o, e => new System.Collections.Generic.KeyValuePair<string, object?>(e.Key, Wf(e.Value)))),
        System.Collections.Generic.List<object?> l => System.Linq.Enumerable.ToList(System.Linq.Enumerable.Select(l, Wf)),
        _ => value,
    };
}
