using System;

namespace Runlight;

/// <summary>A JSON-RPC error with its own code, such as -32602 for an unknown tool, answered with its message as it is.</summary>
public sealed class McpError : Exception
{
    public McpError()
    {
    }

    public McpError(string message)
        : base(message)
    {
    }

    public McpError(string message, Exception inner)
        : base(message, inner)
    {
    }

    public McpError(string message, int code)
        : base(message)
    {
        Code = code;
    }

    /// <summary>The JSON-RPC error code.</summary>
    public int Code { get; }
}
