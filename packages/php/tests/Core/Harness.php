<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use Runlight\Http\Request;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Store\SqlStore;
use Runlight\Tests\Store\Databases;
use Runlight\Time;

/**
 * A Runlight on a fresh database with a clock the test moves, as helpers.ts's setup() is. Tracker hits go
 * straight to collect(), and reports are read from the store, so nothing here needs the routes.
 */
final class Harness
{
    public const CHROME_MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
    public const SAFARI_IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
    public const DAY = 86_400_000;
    public const HOUR = 3_600_000;
    public const MIN = 60_000;
    /** Date.UTC(2026, 9, 6, 12), where the TS tests start the clock. */
    public const START = 1_791_288_000_000;

    public Runlight $rl;
    public int $now = self::START;

    /** @param array<string, mixed> $options */
    public function __construct(string|SqlStore $kind, array $options = [])
    {
        $store = $kind instanceof SqlStore ? $kind : Databases::fresh($kind);
        $this->rl = new Runlight(['store' => $store, 'now' => fn (): int => $this->now, ...$options]);
    }

    public function store(): SqlStore
    {
        return $this->rl->store;
    }

    public function advance(int $ms): void
    {
        $this->now += $ms;
    }

    /**
     * A tracker hit, as the routes pass it to collect().
     *
     * @param array{ua?: string, ip?: string, headers?: array<string, string>} $init
     */
    public function send(array $body, array $init = []): void
    {
        $this->rl->collect(self::hit('https://example.com/runlight/e', $body, $init));
    }

    /** @param array{ua?: string, ip?: string, headers?: array<string, string>} $init */
    public static function hit(string $url, array $body, array $init = []): Request
    {
        $headers = ['user-agent' => $init['ua'] ?? self::CHROME_MAC, 'x-forwarded-for' => $init['ip'] ?? '203.0.113.1', 'content-type' => 'text/plain;charset=UTF-8', ...($init['headers'] ?? [])];
        return new Request($url, 'POST', $headers, Json::encode($body));
    }

    /** A query over local dates of a site, as the dashboard's from and to make one. */
    public function query(string $from, string $to, ?string $site = null, array $filters = []): array
    {
        $row = $this->rl->site($site);
        $tz = $row['timezone'];
        return ['site' => $row['id'], 'from' => Time::startOf($from, $tz), 'to' => Time::startOf(Time::addDays($to, 1), $tz), 'filters' => $filters];
    }

    /** Today in the site's timezone, as period=today. */
    public function today(?string $site = null, array $filters = []): array
    {
        $this->rl->init();
        $day = Time::localDate($this->now, $this->rl->site($site)['timezone']);
        return $this->query($day, $day, $site, $filters);
    }

    /** Everything, as period=all reads it, wide enough for any test. */
    public function all(?string $site = null): array
    {
        $this->rl->init();
        return ['site' => $this->rl->site($site)['id'], 'from' => 0, 'to' => $this->now + self::DAY, 'filters' => []];
    }

    public function stats(array $query): array
    {
        return $this->store()->stats($query);
    }

    /** @return list<mixed> one field of each breakdown row */
    public function values(array $query, string $dimension, string $field = 'value', int $limit = 10): array
    {
        return array_map(static fn (array $r): mixed => $r[$field], $this->store()->breakdown($query, $dimension, $limit, 0));
    }

    public function count(string $sql, array $params = []): int
    {
        return (int) $this->store()->db->all($sql, $params)[0]['n'];
    }
}
