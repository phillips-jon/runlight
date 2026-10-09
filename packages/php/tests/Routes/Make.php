<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Store\Stores;

/**
 * What the route tests share: a Runlight on an in-memory SQLite, the real one when the core is here and the
 * stand-in until then, and requests written as the TypeScript tests write them.
 */
final class Make
{
    /** Whether the PHP core (Runlight\Runlight) is here. */
    public static function core(): bool
    {
        return class_exists('Runlight\\Runlight');
    }

    /**
     * A Runlight with these options and an in-memory SQLite unless a store is given.
     *
     * @param array<string, mixed> $options
     * @return \Runlight\Runlight|StandIn
     */
    public static function runlight(array $options = []): object
    {
        $options += ['store' => Stores::sqlite(':memory:')];
        return self::core() ? new \Runlight\Runlight($options) : new StandIn($options);
    }

    /** Skips a test that needs what only the core does: counting visits, links, sites in the dashboard. */
    public static function needsCore(TestCase $test): void
    {
        if (!self::core()) {
            $test->markTestSkipped('This needs the PHP core (Runlight\Runlight), which is not here yet.');
        }
    }

    /** @param array<string, string> $headers */
    public static function req(string $path, string $method = 'GET', array $headers = [], ?string $body = null): Request
    {
        // JavaScript's Request gives a string body this type when none is named.
        if ($body !== null && !isset($headers['content-type'])) {
            $headers['content-type'] = 'text/plain;charset=UTF-8';
        }
        return new Request("https://example.com$path", $method, $headers, $body ?? '');
    }

    /** A JSON request with a bearer token, as the tests' owner sends it. */
    public static function owner(string $path, string $method = 'GET', mixed $body = null, string $token = 'secret'): Request
    {
        $headers = ['authorization' => "Bearer $token"];
        if ($body !== null) {
            $headers['content-type'] = 'application/json';
        }
        return self::req($path, $method, $headers, $body === null ? null : Json::encode($body));
    }

    /** The answer's body as JSON, objects as arrays. */
    public static function body(Response $response): mixed
    {
        return Json::decode($response->text(), true);
    }
}
