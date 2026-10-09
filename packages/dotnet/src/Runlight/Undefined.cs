namespace Runlight;

/// <summary>
/// JavaScript's undefined, for the few answers that build an object with a field that may be
/// left out: <see cref="Json.Stringify(object?, bool)"/> skips a field holding it, and writes
/// it as null in an array.
/// </summary>
public sealed class Undefined
{
    private Undefined()
    {
    }

    /// <summary>The one undefined.</summary>
    public static Undefined Value { get; } = new();

    /// <inheritdoc/>
    public override string ToString() => "undefined";
}
