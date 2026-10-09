<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Routes;
use Runlight\Runlight;

/**
 * What the Node adapter does for an app, for PHP's own server: one front controller (index.php) that
 * serves Runlight beside the app.
 *
 *   $rl = new Runlight([...]);
 *   FrontController::serve($rl, $rl->routes(['basePath' => '/runlight']));
 *
 * The request is read from PHP's globals with the client's address, then answered in the order the
 * standalone server answers: a link domain added in Settings first (it leaves the dashboard's own paths
 * alone), then `{linkPath}/{slug}` on the app's own domain, then the routes. Once the answer is sent, the
 * work TS does after answering (a retention change's deletions) runs in idle().
 */
final class FrontController
{
    public static function serve(Runlight $rl, Routes $routes): void
    {
        $request = Request::fromGlobals();
        $response = self::answer($rl, $routes, $request);
        $response->emit($request->method !== 'HEAD');
        // The visitor has the answer; whatever is left runs without keeping them waiting.
        if (function_exists('fastcgi_finish_request')) {
            fastcgi_finish_request();
        } elseif (function_exists('litespeed_finish_request')) {
            litespeed_finish_request();
        }
        $rl->idle();
    }

    /** The answer to one request, as serve() sends it. */
    public static function answer(Runlight $rl, Routes $routes, Request $request): Response
    {
        $context = ['ip' => $request->remoteAddress];
        try {
            $linked = $rl->linkDomainResponse($request, $context);
            if ($linked !== null) {
                return $linked;
            }
            $path = (string) parse_url($request->url, PHP_URL_PATH);
            if ($request->method === 'GET' && preg_match('#^' . preg_quote($rl->linkPath, '#') . '/[^/]+/?$#D', $path)) {
                return ($rl->linkHandler())($request, $context);
            }
            return $routes->handle($request);
        } catch (\Throwable $error) {
            error_log('Runlight: ' . $error->getMessage());
            return new Response(Json::encode(['error' => 'Internal error', 'code' => 'internal']), 500, [
                'content-type' => 'application/json; charset=utf-8',
                'cache-control' => 'no-store',
                'x-content-type-options' => 'nosniff',
            ]);
        }
    }
}
