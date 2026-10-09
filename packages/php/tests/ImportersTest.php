<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Http\FetchError;
use Runlight\Http\Response;
use Runlight\Importers\Bitly;
use Runlight\Importers\Dub;
use Runlight\Importers\Http;
use Runlight\Importers\Importer;
use Runlight\Importers\ImportError;
use Runlight\Importers\Rebrandly;
use Runlight\Importers\Shortio;
use Runlight\Importers\Umami;
use Runlight\Json;
use Runlight\Tests\Support\FakeFetcher;

/**
 * Replays the importer scenarios in tests/fixtures/outbound.json (the cases of importers.test.ts and
 * more): each importer, run step by step against the same answers, must send the TypeScript SDK's
 * exact requests, wait as long between retries, ask about the same known links, and hand back the
 * same steps, cursors included. The store side of an import (importStep, writeLink) comes with the store.
 */
final class ImportersTest extends TestCase
{
    private static ?\stdClass $objects = null;

    /** @return list<\stdClass> */
    private static function steps(string $name): array
    {
        self::$objects ??= Json::decode((string) file_get_contents(__DIR__ . '/fixtures/outbound.json'));
        foreach (self::$objects->importers as $scenario) {
            if ($scenario->name === $name) {
                return $scenario->steps;
            }
        }
        return [];
    }

    public static function scenarios(): iterable
    {
        foreach (MailTest::fixture()['importers'] as $scenario) {
            yield $scenario['name'] => [$scenario];
        }
    }

    #[DataProvider('scenarios')]
    public function testScenarioMatchesTypeScript(array $scenario): void
    {
        $now = MailTest::fixture()['now'];
        $left = array_map(static fn ($r) => $r['times'] ?? PHP_INT_MAX, $scenario['routes']);
        $fetcher = new FakeFetcher(static function (string $url) use ($scenario, &$left): Response {
            foreach ($scenario['routes'] as $i => $route) {
                if ($left[$i] <= 0 || !preg_match('~' . $route['pattern'] . '~', $url)) {
                    continue;
                }
                $left[$i]--;
                if (!empty($route['unreachable'])) {
                    throw new FetchError('fetch failed');
                }
                return new Response(Json::encode($route['body']), $route['status'] ?? 200, ['content-type' => 'application/json', ...($route['headers'] ?? [])]);
            }
            return new Response('{}', 404);
        });
        $waits = [];
        $http = new Http($fetcher, static function (int|float $ms) use (&$waits): void {
            $waits[] = $ms;
        });
        $clock = static fn (): int => $now;
        $importer = match ($scenario['source']) {
            'bitly' => new Bitly($http, $clock),
            'dub' => new Dub($http, $clock),
            'rebrandly' => new Rebrandly($http, $clock),
            'shortio' => new Shortio($http, $clock),
            'umami' => new Umami($http, $clock),
        };
        $this->assertInstanceOf(Importer::class, $importer);
        $knownCalls = [];
        $known = static function (string $sourceId, ?string $slug = null, ?string $url = null) use ($scenario, &$knownCalls): bool {
            $knownCalls[] = [$sourceId, $slug, $url];
            return in_array($sourceId, $scenario['known'], true) || in_array("$slug $url", $scenario['known'], true);
        };

        // The fixture's steps decoded to objects, so each is written back as the JSON TypeScript wrote.
        $expected = self::steps($scenario['name']);
        $cursor = $expected[0]->cursor ?? null;
        foreach ($expected as $i => $want) {
            $this->assertSame($want->cursor, $cursor, "step $i starts from the same cursor");
            try {
                $result = $importer->step($scenario['credentials'], $cursor, $known);
            } catch (ImportError $error) {
                $this->assertTrue(isset($want->error), "step $i should not fail: {$error->getMessage()}");
                $this->assertSame(Json::encode($want->error), Json::encode([
                    'message' => $error->getMessage(),
                    'code' => $error->code,
                    'params' => (object) $error->params,
                    ...($error instanceof \Runlight\Importers\HttpError ? ['status' => $error->status] : []),
                    'name' => (new \ReflectionClass($error))->getShortName(),
                ]));
                continue;
            }
            $this->assertFalse(isset($want->error), "step $i should fail");
            $this->assertSame(Json::encode($want->result), Json::encode($result), "step $i");
            $cursor = $result['cursor'];
        }

        $sent = $fetcher->requests;
        $requests = $scenario['requests'];
        if (!$scenario['ordered']) {
            // Umami asks for a link's events and sessions at once in TS; here one follows the other.
            $order = static fn (array $list) => array_map('json_encode', $list);
            $sent = $order($sent);
            $requests = $order($requests);
            sort($sent);
            sort($requests);
        }
        $this->assertSame($requests, $sent);
        $this->assertSame($scenario['waits'], $waits);
        $this->assertSame($scenario['knownCalls'], $knownCalls);
    }

    public function testDatesParseAsJavaScriptParsesThem(): void
    {
        $this->assertSame(1767225600000, Http::parseDate('2026-01-01T00:00:00Z'));
        $this->assertSame(1767225600000, Http::parseDate('2026-01-01T00:00:00+0000'));
        $this->assertSame(1767225600000, Http::parseDate('2026-01-01'));
        $this->assertSame(1767225600500, Http::parseDate('2026-01-01T02:00:00.5+02:00'));
        $this->assertSame(1767225600000, Http::parseDate('2026-01-01T00:00:00'), 'local time, and the tests run in UTC');
        $this->assertSame(0, Http::parseDate('1970-01-01T00:00:00.000Z'));
        $this->assertNan(Http::parseDate('nope'));
        $this->assertNan(Http::parseDate('2026-02-30'));
        $this->assertNan(Http::parseDate(null));
        $this->assertSame('2026-03-02T00:00:00.000Z', Http::isoString(1772409600000));
        $this->assertSame('1969-12-31T23:59:59.999Z', Http::isoString(-1));
        $this->expectException(\RangeException::class);
        Http::isoString(NAN);
    }

    public function testJavaScriptValuesReadAsTheyDo(): void
    {
        $this->assertSame([false, false, false, true, true, false, true], array_map(Http::truthy(...), [null, '', 0, '0', [], NAN, 0.5]));
        $this->assertSame(['7', '7', 'null', 'undefined', 'a,b', '1e+21'], array_map(Http::str(...), [7, 7.0, null, \Runlight\Undefined::value(), ['a', 'b'], 1e21]));
        $this->assertSame([0.0, 2.0, 1.5, 31.0], array_map(Http::number(...), [null, ' 2 ', '1.5', '0x1f']));
        $this->assertNan(Http::number('soon'));
        $this->assertSame("a%20b%2Fc!'()*~", Http::encodeURIComponent("a b/c!'()*~"));
    }

    /** Names JavaScript objects carry on their prototype are just names, as edges.test.ts checks in the SDK. */
    public function testNamesLikeObjectPropertiesAreJustNames(): void
    {
        $runlight = new \Runlight\Runlight(['store' => \Runlight\Store\Stores::sqlite(':memory:')]);
        foreach (['constructor', 'toString', '__proto__', 'hasOwnProperty'] as $source) {
            try {
                \Runlight\Importers\Index::importStep($runlight, 'default', $source, [], null, 0);
                $this->fail("$source imported");
            } catch (ImportError $e) {
                $this->assertSame('import_source', $e->code, $source);
            }
        }
        $this->assertSame(['Constructor', '__proto__', 'ToString'], array_map(\Runlight\Importers\Write::browser(...), ['constructor', '__proto__', 'toString']));
        $this->assertSame(['constructor', 'toString'], array_map(\Runlight\Importers\Write::system(...), ['constructor', 'toString']));
        $this->assertSame(['', ''], array_map(\Runlight\Importers\Write::device(...), ['constructor', 'valueOf']));
    }
}
