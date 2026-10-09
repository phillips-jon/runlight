using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Runlight;
using Runlight.AspNetCore;
using Runlight.Http;
using RunlightInstance = Runlight.Runlight;

namespace Microsoft.AspNetCore.Builder;

/// <summary>
/// Runlight on ASP.NET Core: <see cref="MapRunlight(IEndpointRouteBuilder, RunlightInstance, RoutesOptions?, bool)"/>
/// on endpoint routing and <see cref="UseRunlight(IApplicationBuilder, RunlightInstance, RoutesOptions?, bool)"/> as
/// middleware. Both answer the dashboard, the API, and the tracker under the routes' base path (<c>/runlight</c> by
/// default), short links at <c>{linkPath}/{slug}</c> (<c>/go</c>), and every request to a link domain added in
/// Settings, and record the fetches of known AI agents on the app's own pages. The Runlight is the one given, or
/// the app's singleton. They are in Microsoft's namespace, as <c>MapHealthChecks</c> is, so they need no
/// <c>using</c>.
/// </summary>
public static class RunlightAspNetCoreExtensions
{
    private const string Rest = "runlightRest";

    /// <summary>
    /// Maps the routes at their base path and everything beneath it, for every method, and short links at
    /// <c>GET {linkPath}/{slug}</c>. The endpoints skip antiforgery (Runlight checks its own requests, and the
    /// tracker cannot send a token) and are left out of OpenAPI documents. They allow anonymous requests, so an
    /// app whose fallback policy requires a signed-in user still reaches the tracker, the short links, and the
    /// dashboard's own sign-in; routes left open on purpose (<c>Token = null</c>) take the app's authorization
    /// policy, apart from the short links. On a <see cref="WebApplication"/> it also adds a middleware, where it
    /// is called, that answers link domains and records AI agent fetches (<paramref name="observe"/>).
    /// </summary>
    /// <param name="endpoints">The app.</param>
    /// <param name="runlight">The Runlight to serve.</param>
    /// <param name="options">The routes' options, such as BasePath and Token.</param>
    /// <param name="observe">Whether to record the fetches of known AI agents on the app's other pages.</param>
    public static IEndpointConventionBuilder MapRunlight(this IEndpointRouteBuilder endpoints, RunlightInstance runlight, RoutesOptions? options = null, bool observe = true)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        ArgumentNullException.ThrowIfNull(runlight);
        options ??= endpoints.ServiceProvider.GetService<RoutesOptions>() ?? new RoutesOptions();
        Routes routes = runlight.Routes(options);
        string @base = Routes.NormaliseBase(options.BasePath ?? "/runlight");
        RequestDelegate serve = context => RunlightHttp.ServeAsync(context, runlight, routes);

        var built = new List<IEndpointConventionBuilder>();
        if (@base.Length > 0)
        {
            built.Add(endpoints.Map(@base, serve));
        }
        built.Add(endpoints.Map(@base + "/{**" + Rest + "}", serve));
        var dashboard = new Conventions(built);
        dashboard.DisableAntiforgery();
        dashboard.ExcludeFromDescription();
        if (!(options.TokenGiven && options.Token == null))
        {
            dashboard.AllowAnonymous();
        }

        IEndpointConventionBuilder links = endpoints.MapGet(runlight.LinkPath + "/{slug}", serve);
        links.ExcludeFromDescription();
        links.AllowAnonymous();

        if (endpoints is IApplicationBuilder app)
        {
            app.Use(Front(runlight, routes, observe, owns: null));
        }
        return new Conventions([.. built, links]);
    }

    /// <summary>
    /// As <see cref="MapRunlight(IEndpointRouteBuilder, RunlightInstance, RoutesOptions?, bool)"/>, with the app's
    /// Runlight singleton.
    /// </summary>
    public static IEndpointConventionBuilder MapRunlight(this IEndpointRouteBuilder endpoints, RoutesOptions? options = null, bool observe = true)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        return endpoints.MapRunlight(endpoints.ServiceProvider.GetRequiredService<RunlightInstance>(), options, observe);
    }

    /// <summary>
    /// Runlight as middleware, ahead of whatever follows it: link domains first (they leave the dashboard's own
    /// paths alone), then short links at <c>{linkPath}/{slug}</c>, then the routes under their base path. Every
    /// other request goes on to the app, after a page fetched by a known AI agent is recorded
    /// (<paramref name="observe"/>). For an app that wants Runlight ahead of its other middleware, or has no
    /// endpoint routing. Middleware carries no endpoint authorization, so routes left open on purpose
    /// (<c>Token = null</c>) sit behind the app's sign-in only when <c>UseAuthentication</c> and
    /// <c>UseAuthorization</c> come before this.
    /// </summary>
    public static IApplicationBuilder UseRunlight(this IApplicationBuilder app, RunlightInstance runlight, RoutesOptions? options = null, bool observe = true)
    {
        ArgumentNullException.ThrowIfNull(app);
        ArgumentNullException.ThrowIfNull(runlight);
        options ??= app.ApplicationServices.GetService<RoutesOptions>() ?? new RoutesOptions();
        Routes routes = runlight.Routes(options);
        string @base = Routes.NormaliseBase(options.BasePath ?? "/runlight");
        var link = new Regex("^" + Regex.Escape(runlight.LinkPath) + "/[^/]+/?\\z", RegexOptions.CultureInvariant);
        return app.Use(Front(runlight, routes, observe, (method, path) =>
            (method == "GET" && link.IsMatch(path)) || @base.Length == 0 || path == @base || path.StartsWith(@base + "/", StringComparison.Ordinal)));
    }

    /// <summary>As <see cref="UseRunlight(IApplicationBuilder, RunlightInstance, RoutesOptions?, bool)"/>, with the app's Runlight singleton.</summary>
    public static IApplicationBuilder UseRunlight(this IApplicationBuilder app, RoutesOptions? options = null, bool observe = true)
    {
        ArgumentNullException.ThrowIfNull(app);
        return app.UseRunlight(app.ApplicationServices.GetRequiredService<RunlightInstance>(), options, observe);
    }

    /// <summary>
    /// The middleware: a link domain answers whatever the path; a request <paramref name="owns"/> says is
    /// Runlight's is answered; anything else goes on, with an AI agent's page fetch recorded first.
    /// </summary>
    private static Func<HttpContext, RequestDelegate, Task> Front(RunlightInstance runlight, Routes routes, bool observe, Func<string, string, bool>? owns) =>
        async (context, next) =>
        {
            Request head = RunlightHttp.HeadOf(context);
            Response? linked;
            try
            {
                linked = await runlight.LinkDomainResponseAsync(head, head.RemoteAddress, context.RequestAborted).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error)
            {
                await Console.Error.WriteLineAsync("Runlight: " + error.Message).ConfigureAwait(false);
                linked = Routes.Coded("Internal error", "internal", 500);
            }
            if (linked != null)
            {
                context.Response.OnCompleted(runlight.IdleAsync);
                await RunlightHttp.WriteAsync(context, linked, context.RequestAborted).ConfigureAwait(false);
                return;
            }
            if (owns != null && owns(head.Method, new Url(head.Url).Pathname))
            {
                await RunlightHttp.ServeAsync(context, runlight, routes).ConfigureAwait(false);
                return;
            }
            if (observe && head.Method == "GET")
            {
                await runlight.ObserveAsync(head, cancellationToken: context.RequestAborted).ConfigureAwait(false);
            }
            await next(context).ConfigureAwait(false);
        };

    /// <summary>Several endpoints' conventions as one, so an app adds its own to all of them at once.</summary>
    private sealed class Conventions(IReadOnlyList<IEndpointConventionBuilder> builders) : IEndpointConventionBuilder
    {
        public void Add(Action<EndpointBuilder> convention)
        {
            foreach (var b in builders)
            {
                b.Add(convention);
            }
        }

        public void Finally(Action<EndpointBuilder> finallyConvention)
        {
            foreach (var b in builders)
            {
                b.Finally(finallyConvention);
            }
        }
    }
}
