<?php

declare(strict_types=1);

namespace Runlight\Tests\Support;

use Runlight\Http\Fetcher;
use Runlight\Http\Headers;
use Runlight\Http\Response;

/**
 * A Fetcher that records every request and answers from a closure, so a test
 * can require the exact method, URL, headers, and body a service is sent.
 * Headers are recorded as the TS fixtures record them: lowercase names in
 * order, as iterating Fetch Headers gives them.
 */
final class FakeFetcher implements Fetcher
{
    /** @var list<array{method: string, url: string, headers: array<string, string>, body: string}> */
    public array $requests = [];
    /** @var list<array<string, mixed>> the init each request came with */
    public array $inits = [];

    /** @param \Closure(string, array): Response $answer */
    public function __construct(private readonly \Closure $answer)
    {
    }

    public function fetch(string $url, array $init = []): Response
    {
        $headers = [];
        foreach (new Headers($init['headers'] ?? []) as $name => $value) {
            $headers[$name] = $value;
        }
        $this->requests[] = ['method' => $init['method'] ?? 'GET', 'url' => $url, 'headers' => $headers, 'body' => (string) ($init['body'] ?? '')];
        $this->inits[] = $init;
        return ($this->answer)($url, $init);
    }
}
