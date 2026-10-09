<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use Runlight\Http\Fetcher;
use Runlight\Http\Headers;
use Runlight\Http\Response;
use Runlight\Http\Url;
use Runlight\Json;

/**
 * A Fetcher that answers from a table of URL patterns, recording what was asked, as the TS tests' serve()
 * replaces globalThis.fetch. Each answer is a body to send as JSON, or [status, body].
 */
final class Router implements Fetcher
{
    /** @var list<string> "METHOD host/path" of each request */
    public array $calls = [];
    /** @var list<array{url: string, init: array}> */
    public array $requests = [];

    /** @param list<array{string, \Closure(Url, array): mixed}> $routes */
    public function __construct(private readonly array $routes)
    {
    }

    public function fetch(string $url, array $init = []): Response
    {
        $u = new Url($url);
        $this->calls[] = ($init['method'] ?? 'GET') . ' ' . $u->host() . $u->pathname;
        $this->requests[] = ['url' => $url, 'init' => $init];
        foreach ($this->routes as [$pattern, $answer]) {
            if (preg_match($pattern, $u->href())) {
                $result = $answer($u, $init);
                [$status, $body] = is_array($result) && array_is_list($result) && count($result) === 2 && is_int($result[0]) ? $result : [200, $result];
                return new Response(Json::encode($body), $status, ['content-type' => 'application/json']);
            }
        }
        return new Response('{}', 404);
    }

    /** The authorization header a request carried. */
    public static function authorization(array $init): ?string
    {
        return (new Headers($init['headers'] ?? []))->get('authorization');
    }
}
