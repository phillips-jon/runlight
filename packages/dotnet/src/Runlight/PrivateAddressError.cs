using System;

namespace Runlight;

/// <summary>Refused before anything was fetched, because the address is not on the public internet.</summary>
public sealed class PrivateAddressError : Exception
{
    public PrivateAddressError()
    {
    }

    /// <param name="what">The address or name, which the message names.</param>
    public PrivateAddressError(string what)
        : base(what + " is not a public address")
    {
    }

    public PrivateAddressError(string message, Exception inner)
        : base(message, inner)
    {
    }
}
