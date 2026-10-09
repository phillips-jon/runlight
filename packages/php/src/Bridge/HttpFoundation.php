<?php

declare(strict_types=1);

namespace Runlight\Bridge;

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
        $answer = FrontController::answer($rl, $routes, self::request($request));
        register_shutdown_function($rl->idle(...));
        return self::response($answer);
    }

    /**
     * The request as Runlight reads it. The URL is the one the browser asked for, with its query string as sent
     * (Symfony's getUri() sorts it), and the address is the connection's, since Runlight reads proxy headers
     * itself, only when trustProxy allows.
     */
    public static function request(SymfonyRequest $request): Request
    {
        $method = $request->getRealMethod();
        return new Request(
            $request->getSchemeAndHttpHost() . $request->getRequestUri(),
            $method,
            $request->headers->all(),
            in_array($method, ['GET', 'HEAD'], true) ? '' : (string) $request->getContent(),
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
