using System;
using System.Threading;
using System.Threading.Tasks;

namespace Runlight.Importers;

/// <summary>
/// One shortener. <see cref="StepAsync"/> does a bounded slice of work (a few links) and hands
/// back a cursor, so imports run in small requests that fit any host's time limit and can show
/// progress. Credentials come with every step and are never stored.
/// </summary>
/// <remarks>
/// The shapes are TS's, as <see cref="JsObject"/>s with the same keys:
/// <list type="bullet">
/// <item>ForeignLink: <c>sourceId</c> (the other service's id, so a re-run recognises the link), <c>slug</c>,
/// <c>domain</c> (the short link's domain there; shortener-owned domains such as bit.ly and dub.sh are not kept),
/// <c>name</c>, <c>url</c>, <c>createdAt</c> (ms).</item>
/// <item>ForeignClick: <c>ts</c> (ms), and whichever of <c>visit</c> (groups clicks into one visit), <c>referrer</c>,
/// <c>path</c>, <c>query</c> (path and query of the short URL as clicked, for campaign tags), <c>country</c>,
/// <c>region</c>, <c>city</c>, <c>browser</c>, <c>os</c>, <c>device</c>, <c>screen</c>, and <c>language</c> the
/// service knows. A field it does not know is left out.</item>
/// <item>DailyClicks: <c>day</c> (YYYY-MM-DD, UTC) and <c>clicks</c>, for services that only keep counts.</item>
/// <item>A step: <c>cursor</c>, <c>total</c>, and <c>links</c>, each <c>{ link, clicks?, daily?, known? }</c>.</item>
/// </list>
/// </remarks>
public interface IImporter
{
    /// <param name="credentials">The fields typed in the dashboard, every value a string.</param>
    /// <param name="cursor">Where the last step stopped; null to start.</param>
    /// <param name="known">
    /// Whether a link from this source is already in Runlight, so its history need not be fetched
    /// again: imported from this source before, or the same slug to the same destination brought in
    /// some other way. Called with the source id, the slug, and the destination.
    /// </param>
    /// <param name="cancellationToken">Stops the step.</param>
    Task<JsObject> StepAsync(JsObject credentials, string? cursor, Func<string, string?, string?, Task<bool>> known, CancellationToken cancellationToken = default);
}
