using System;

namespace Runlight.Server;

/// <summary>A failure to reach Runlight or have it take a batch, told apart from a failure to read the log.</summary>
public sealed class SendError : Exception
{
    public SendError()
    {
    }

    public SendError(string message)
        : base(message)
    {
    }

    public SendError(string message, Exception inner)
        : base(message, inner)
    {
    }
}
