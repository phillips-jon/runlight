using System;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Runlight.Server;

namespace Runlight.AspNetCore;

/// <summary>
/// The standalone server on Kestrel, as <c>runlight serve</c> runs it: every request answered by the
/// <see cref="Standalone"/>, on PORT (3000) at HOST (0.0.0.0), until the process is stopped (SIGINT or SIGTERM)
/// or the token given fires.
/// </summary>
public static class StandaloneHost
{
    /// <summary>Serves until stopped. The schedule is the caller's, as <see cref="Cli"/> starts it.</summary>
    /// <param name="config">The settings, for PORT and HOST.</param>
    /// <param name="server">The server to answer with.</param>
    /// <param name="output">Where it says it is listening.</param>
    /// <param name="stopping">Stops the server, beside the process's own signals.</param>
    public static async Task RunAsync(Config config, Standalone server, TextWriter output, CancellationToken stopping = default)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(server);
        ArgumentNullException.ThrowIfNull(output);
        double port = Js.Number(config.Get("PORT") ?? "3000");
        if (!(port >= 0 && port <= 65_535 && Math.Floor(port) == port))
        {
            throw new InvalidOperationException("set PORT to a port number, such as 3000");
        }
        string host = config.Get("HOST") ?? "0.0.0.0";
        IPAddress? address = host == "localhost" ? null : IPAddress.TryParse(host.Trim('[', ']'), out var parsed) ? parsed : throw new InvalidOperationException("set HOST to an address to listen on, such as 0.0.0.0 or 127.0.0.1");

        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [], ContentRootPath = config.Root });
        builder.Logging.ClearProviders();
        builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(5));
        builder.WebHost.UseKestrel(k =>
        {
            k.AddServerHeader = false;
            if (address == null)
            {
                k.ListenLocalhost((int)port);
            }
            else
            {
                k.Listen(address, (int)port);
            }
        });
        WebApplication app = builder.Build();
        await using (app.ConfigureAwait(false))
        {
            app.Run(context => RunlightHttp.ServeAsync(context, server.Handler(), server.Runlight.IdleAsync));
            await app.StartAsync(stopping).ConfigureAwait(false);
            string shown = host is "0.0.0.0" or "::" or "[::]" ? "localhost" : host;
            await Cli.AnnounceAsync(config, server, "http://" + shown + ":" + Js.Str((long)port), output).ConfigureAwait(false);
            try
            {
                await app.WaitForShutdownAsync(stopping).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested)
            {
            }
            await app.StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
    }
}
