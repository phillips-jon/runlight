using System;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight;

/// <summary>
/// Capped reads of an answer's body. The cap belongs on the request: pass
/// <see cref="FetchInit.MaxBytes"/> to the fetcher, which stops reading past it and throws
/// <see cref="BodyTooLongException"/>, so an install or a page that answers without end never fills
/// memory. These check the same limit again on an answer already read, for a fetcher that does not
/// take the option, and decode the text as TextDecoder does.
/// </summary>
public static class Body
{
    /// <summary>The body as text, up to maxBytes; past that, <see cref="BodyTooLongException"/>.</summary>
    public static async Task<string> ReadTextCappedAsync(Response response, long maxBytes, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(response);
        string? declared = response.Headers.Get("content-length");
        if (Js.Number(declared) > maxBytes)
        {
            throw TooLong(maxBytes);
        }
        byte[] bytes = await response.BytesAsync(cancellationToken).ConfigureAwait(false);
        if (bytes.Length > maxBytes)
        {
            throw TooLong(maxBytes);
        }
        return Utf8(bytes);
    }

    /// <summary>The body as JSON, up to maxBytes, as <see cref="ReadTextCappedAsync"/> reads it.</summary>
    public static async Task<object?> ReadJsonCappedAsync(Response response, long maxBytes, CancellationToken cancellationToken = default) =>
        Json.Parse(await ReadTextCappedAsync(response, maxBytes, cancellationToken).ConfigureAwait(false));

    /// <summary>Text as TextDecoder gives it: U+FFFD where the bytes are not UTF-8, and no byte order mark.</summary>
    public static string Utf8(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        ReadOnlySpan<byte> span = bytes;
        if (span.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]))
        {
            span = span[3..];
        }
        return Js.Decode(span);
    }

    private static BodyTooLongException TooLong(long maxBytes) =>
        new("Body over " + maxBytes.ToString(CultureInfo.InvariantCulture) + " bytes");
}
