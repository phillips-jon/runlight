using System.Threading.Tasks;
using Runlight.Http;

namespace Runlight.Tests.ConformanceRunner;

/// <summary>The entry points a scenario's steps go to: the .NET core (<see cref="CoreTarget"/>), or a fake that proves the runner.</summary>
public interface ITarget
{
    /// <summary>The routes' handler, rl.Routes(...).HandleAsync().</summary>
    Task<Response> HandleAsync(Request request);

    /// <summary>The app's own short-link path, rl.LinkHandler().</summary>
    Task<Response> LinksAsync(Request request);

    /// <summary>The link-domain middleware, rl.LinkDomainResponseAsync(); null lets the request pass on to the app.</summary>
    Task<Response?> LinkDomainAsync(Request request);

    /// <summary>Finishes work a request started after answering (retention), as <c>await rl.idle()</c> does in TypeScript.</summary>
    Task IdleAsync();
}
