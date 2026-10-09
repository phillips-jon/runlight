<?php

declare(strict_types=1);

namespace Runlight\Tests;

use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Headers;
use Runlight\Http\Response;

/** A Fetcher that records each request and answers from a queue: a Response, or "timeout" or "network" to fail. */
final class RecordingFetcher implements Fetcher
{
    /** @var list<array{url: string, method: string, headers: array<string, string>, body: ?string, timeoutMs: ?int}> */
    public array $requests = [];

    /** @param list<Response|string> $queue */
    public function __construct(private array $queue = [])
    {
    }

    public function fetch(string $url, array $init = []): Response
    {
        $headers = $init['headers'] ?? [];
        $this->requests[] = [
            'url' => $url,
            'method' => $init['method'] ?? 'GET',
            'headers' => $headers instanceof Headers ? array_map(fn ($v) => implode(', ', $v), $headers->all()) : $headers,
            'body' => $init['body'] ?? null,
            'timeoutMs' => $init['timeoutMs'] ?? null,
        ];
        $next = array_shift($this->queue);
        if ($next === null) {
            throw new \RuntimeException('No canned answer left');
        }
        if ($next === 'timeout') {
            throw new FetchError('The operation timed out', true);
        }
        if ($next === 'network') {
            throw new FetchError('Could not connect');
        }
        return $next;
    }
}
