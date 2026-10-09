using System;
using System.Collections.Concurrent;
using System.IO;

namespace Runlight;

/// <summary>
/// The dashboard bundle, CSS, world map, locales, tracker, picker, and data lists, embedded in the
/// assembly by scripts/dotnet-assets.mts (never edit them), with their hashes and the icon in
/// build.json.
/// </summary>
public static class Assets
{
    private static readonly ConcurrentDictionary<string, byte[]> Cache = new(StringComparer.Ordinal);
    private static JsObject? _build;

    /// <summary>An embedded file's bytes.</summary>
    public static byte[] Bytes(string name) => Cache.GetOrAdd(name, static n =>
    {
        using var stream = typeof(Assets).Assembly.GetManifestResourceStream("Runlight.Assets/" + n)
            ?? throw new InvalidOperationException("Runlight asset missing: " + n);
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    });

    /// <summary>An embedded file as text.</summary>
    public static string Text(string name) => Js.Decode(Bytes(name));

    /// <summary>build.json: the version, the hashes, and the icon.</summary>
    public static JsObject Build => _build ??= (JsObject)Json.Parse(Text("build.json"))!;
}
