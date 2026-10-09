using System;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Server;

/// <summary>
/// What the Node adapter does for an app, as one answer: a link domain added in Settings first (it leaves the
/// dashboard's own paths alone), then <c>{linkPath}/{slug}</c> on the app's own domain, then the routes. An
/// adapter sends the answer, then calls the Runlight's IdleAsync for the work TS does after answering (a
/// retention change's deletions).
/// </summary>
public static class FrontController
{
    /// <summary>The answer to one request. <paramref name="ip"/> is the connection's address, when known.</summary>
    public static async Task<Response> AnswerAsync(global::Runlight.Runlight rl, Routes routes, Request request, string? ip = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(rl);
        ArgumentNullException.ThrowIfNull(routes);
        ArgumentNullException.ThrowIfNull(request);
        ip ??= request.RemoteAddress;
        try
        {
            var linked = await rl.LinkDomainResponseAsync(request, ip, cancellationToken).ConfigureAwait(false);
            if (linked != null)
            {
                return linked;
            }
            string path = new Url(request.Url).Pathname;
            if (request.Method == "GET" && Regex.IsMatch(path, "^" + Regex.Escape(rl.LinkPath) + "/[^/]+/?\\z", RegexOptions.CultureInvariant))
            {
                return await rl.LinkHandler()(request, ip, cancellationToken).ConfigureAwait(false);
            }
            return await routes.HandleAsync(request, ip, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            await Console.Error.WriteLineAsync("Runlight: " + error.Message).ConfigureAwait(false);
            return Routes.Coded("Internal error", "internal", 500);
        }
    }
}
