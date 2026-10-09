using System;

namespace Runlight;

/// <summary>
/// JavaScript's TypeError, thrown where the TypeScript would throw one on a value of the wrong
/// type, and caught where the TypeScript catches it.
/// </summary>
public sealed class JsTypeError : Exception
{
    public JsTypeError()
    {
    }

    public JsTypeError(string message)
        : base(message)
    {
    }

    public JsTypeError(string message, Exception inner)
        : base(message, inner)
    {
    }
}
