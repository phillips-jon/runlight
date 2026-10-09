<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\TestCase;
use Runlight\Store\SqlStore;

/** Store tests that run on every database at hand (see Databases). */
abstract class StoreTestCase extends TestCase
{
    public const DAY = Seed::DAY;
    public const HOUR = Seed::HOUR;
    public const MIN = Seed::MIN;

    /** Date.UTC(2026, 9, 6, 12), the clock the TypeScript tests start from. */
    public const NOW = 1_791_288_000_000;

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    protected function tearDown(): void
    {
        Databases::cleanup();
    }

    /** A fresh store with its tables and the site "default" in UTC. */
    protected function store(string $kind, string $timezone = 'UTC'): SqlStore
    {
        $store = Databases::fresh($kind);
        $store->migrate();
        $store->upsertSite(['id' => 'default', 'name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => $timezone], self::NOW);
        return $store;
    }

    /** A query over a range, with filters given as [dimension, op, value]. */
    protected static function q(int $from, int $to, array ...$filters): array
    {
        return ['site' => 'default', 'from' => $from, 'to' => $to, 'filters' => array_map(static fn (array $f): array => ['dimension' => $f[0], 'op' => $f[1], 'value' => $f[2]], $filters)];
    }

    /** The UTC day holding NOW, as a query. */
    protected static function today(array ...$filters): array
    {
        return self::q(self::NOW - 12 * self::HOUR, self::NOW + 12 * self::HOUR, ...$filters);
    }

    protected static function goal(string $id, array $fields): array
    {
        return ['id' => $id, 'site' => 'default', 'name' => $id, 'kind' => 'event', 'match' => '', 'clickBy' => '', 'valueMode' => 'none', 'value' => 0, 'valueProp' => '', 'currency' => 'USD', 'createdAt' => 0, ...$fields];
    }
}
