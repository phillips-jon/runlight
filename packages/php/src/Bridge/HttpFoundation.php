<?php

declare(strict_types=1);

namespace Runlight\Bridge;

use Runlight\Http\BodyTooLarge;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Routes;
use Runlight\Runlight;
use Runlight\Server\FrontController;
use Symfony\Component\HttpFoundation\Request as SymfonyRequest;
use Symfony\Component\HttpFoundation\Response as SymfonyResponse;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Runlight in a framework built on Symfony's HttpFoundation, which Laravel and Symfony both are. It needs
 * symfony/http-foundation, which those frameworks already have; nothing else in Runlight does.
 *
 *   public function __invoke(Request $request, Runlight $rl): Response
 *   {
 *       return HttpFoundation::handle($rl, $rl->routes(), $request);
 *   }
 */
final class HttpFoundation
{
    /**
     * Answers a request for the routes, a short link at /go/{slug}, or a link domain, as FrontController does,
     * and leaves the work TS does after answering (a retention change's deletions) to run once PHP has sent it.
     */
    public static function handle(Runlight $rl, Routes $routes, SymfonyRequest $request): SymfonyResponse
    {
        try {
            $ours = self::request($request);
        } catch (BodyTooLarge) {
            return self::response(Request::tooLarge());
        }
        $answer = FrontController::answer($rl, $routes, $ours);
        register_shutdown_function($rl->idle(...));
        return self::response($answer);
    }

    /**
     * The answer for a short link, for a middleware or a kernel.request listener that runs before the app's
     * routes, or null when the app should answer. As in FrontController, a link domain added in Settings comes
     * first: it gets the link's redirect, or a 404 for a path with no link, except under the dashboard's paths,
     * which reach the app so its owner can always open it. Then a GET for `{linkPath}/{slug}` on any other host
     * gets the redirect when the link exists. Everything else is null, including a slug with no link, so the
     * app's own 404 page answers it. The request's body is never read.
     */
    public static function shortLink(Runlight $rl, SymfonyRequest $request): ?SymfonyResponse
    {
        $ours = new Request(
            $request->getSchemeAndHttpHost() . $request->getRequestUri(),
            $request->getRealMethod(),
            $request->headers->all(),
            '',
            (string) $request->server->get('REMOTE_ADDR', ''),
        );
        $context = ['ip' => $ours->remoteAddress];
        $answer = $rl->linkDomainResponse($ours, $context);
        $path = (string) parse_url($ours->url, PHP_URL_PATH);
        if ($answer === null && $ours->method === 'GET' && preg_match('#^' . preg_quote($rl->linkPath, '#') . '/[^/]+$#D', $path)) {
            try {
                $followed = ($rl->linkHandler())($ours, $context);
                $answer = $followed->status === 404 ? null : $followed;
            } catch (\UnexpectedValueException) {
                // A slug that is not valid percent-encoding is no link, so it is the app's too.
            }
        }
        return $answer === null ? null : self::response($answer);
    }

    /**
     * The request as Runlight reads it. The URL is the one the browser asked for, with its query string as sent
     * (Symfony's getUri() sorts it), and the address is the connection's, since Runlight reads proxy headers
     * itself, only when trustProxy allows. The body is read up to its limit, as Request::fromGlobals() reads it.
     *
     * @throws BodyTooLarge past the limit
     */
    public static function request(SymfonyRequest $request): Request
    {
        $method = $request->getRealMethod();
        $body = '';
        if (!in_array($method, ['GET', 'HEAD'], true)) {
            $stream = $request->getContent(true);
            $body = Request::readBody($stream, $request->getRequestUri(), $request->headers->get('content-length'));
        }
        return new Request(
            $request->getSchemeAndHttpHost() . $request->getRequestUri(),
            $method,
            $request->headers->all(),
            $body,
            (string) $request->server->get('REMOTE_ADDR', ''),
        );
    }

    /** The answer as a framework sends it, streamed when Runlight streams it (exports). */
    public static function response(Response $answer): SymfonyResponse
    {
        $headers = $answer->headers->all();
        if ($answer->streamed()) {
            return new StreamedResponse(static function () use ($answer): void {
                $answer->write();
            }, $answer->status, $headers);
        }
        return new SymfonyResponse($answer->text(), $answer->status, $headers);
    }
}
