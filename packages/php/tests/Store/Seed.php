<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use Runlight\Store\SqlStore;

/**
 * Visits written through the store as the tracker writes them (a session, then its rows, each counted into
 * the session), for store tests that cannot go through runlight()/routes() yet.
 */
final class Seed
{
    public const DAY = 86_400_000;
    public const HOUR = 3_600_000;
    public const MIN = 60_000;

    /**
     * A session with its fields, then its rows in order. A row is one of:
     * ['pageview', path, ts, pageviewId] (optional fifth: hostname),
     * ['event', name, ts, props|null] (optional fifth: path),
     * ['engagement', pageviewId, ts, ms, scroll|null].
     *
     * @param array<string, string> $fields SessionRow fields beyond the defaults
     * @param list<array> $rows
     */
    public static function visit(SqlStore $store, string $id, string $visitor, int $startedAt, array $fields = [], array $rows = [], string $site = 'default'): void
    {
        $store->insertSession([
            'id' => $id, 'site' => $site, 'visitor' => $visitor, 'startedAt' => $startedAt, 'hostname' => 'example.com', 'referrerHost' => '', 'referrerPath' => '',
            'source' => '', 'channel' => 'Direct', 'utmSource' => '', 'utmMedium' => '', 'utmCampaign' => '', 'utmTerm' => '', 'utmContent' => '',
            'country' => '', 'region' => '', 'city' => '', 'browser' => 'Chrome', 'browserVersion' => '129', 'os' => 'macOS', 'osVersion' => '', 'device' => 'Desktop',
            'screen' => '', 'language' => 'en', ...$fields,
        ]);
        $paths = [];
        $last = '/';
        foreach ($rows as $row) {
            $event = ['site' => $site, 'visitor' => $visitor, 'session' => $id, 'pageview' => '', 'path' => $last, 'hostname' => $fields['hostname'] ?? 'example.com', 'title' => '', 'name' => '', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => ''];
            if ($row[0] === 'pageview') {
                [, $path, $ts, $pv] = $row;
                $paths[$pv] = $path;
                $last = $path;
                $store->insertEvent([...$event, 'ts' => $ts, 'kind' => 'pageview', 'pageview' => $pv, 'path' => $path, 'hostname' => $row[4] ?? $event['hostname'], 'title' => mb_substr("Title $path", 0, 500)]);
                $store->touchSession($id, $ts, 'pageview', $path);
            } elseif ($row[0] === 'event') {
                [, $name, $ts, $props] = $row;
                $store->insertEvent([...$event, 'ts' => $ts, 'kind' => 'event', 'name' => $name, 'props' => $props, 'path' => $row[4] ?? $last]);
                $store->touchSession($id, $ts, 'event', $row[4] ?? $last);
            } else {
                [, $pv, $ts, $ms, $scroll] = $row;
                $store->insertEvent([...$event, 'ts' => $ts, 'kind' => 'engagement', 'pageview' => $pv, 'path' => $paths[$pv] ?? $last, 'engagedMs' => $ms, 'scroll' => $scroll]);
                $store->addEngagement($id, $ms);
            }
        }
    }

    /**
     * A site's days built as the core builds them, a UTC day at a time, for every whole day before `$before`
     * that has a visit.
     */
    public static function buildDays(SqlStore $store, string $site, int $from, int $before): int
    {
        $built = 0;
        for ($day = intdiv($from, self::DAY) * self::DAY; $day + self::DAY <= $before; $day += self::DAY) {
            $store->buildRollupDay($site, gmdate('Y-m-d', intdiv($day, 1000)), $day, $day + self::DAY);
            $built++;
        }
        return $built;
    }

    /**
     * A database with a bit of everything, written through the PHP store, and the reads to compare over it.
     *
     * @return list<array{method: string, args: list<mixed>}>
     */
    public static function everything(SqlStore $store): array
    {
        $store->migrate();
        $now = gmmktime(12, 0, 0, 10, 6, 2026) * 1000;
        $store->upsertSite(['id' => 'default', 'name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => 'UTC'], $now);
        $store->upsertSite(['id' => 'b', 'name' => 'Bee', 'hostnames' => [], 'timezone' => 'Asia/Tokyo'], $now);
        $store->setSiteOverrides('b', ['name' => 'Renamed']);
        $pages = ['/', '/pricing', '/blog/one', '/caf%C3%A9', '/%C3%9Cber-uns', '/thanks', '/#/cart'];
        $countries = ['GB', 'US', 'DE', 'FR'];
        $campaigns = ['alpha', 'Zeta', 'émile', 'Émile', 'a-b', 'ab', ''];
        $n = 0;
        for ($day = 9; $day >= 0; $day--) {
            for ($v = 0; $v < 5; $v++) {
                $n++;
                $start = $now - $day * self::DAY - 10 * self::HOUR + $v * 2 * self::HOUR + $n * 1000;
                $rows = [];
                $t = $start;
                for ($p = 0; $p < 1 + $n % 3; $p++) {
                    $rows[] = ['pageview', $pages[($n + $p) % count($pages)], $t, "pv{$n}x$p"];
                    if ($n % 2 === 0) {
                        $rows[] = ['engagement', "pv{$n}x$p", $t + 5000, 8000 + $n * 100, $n % 3 ? 30 + $n % 50 : null];
                    }
                    if ($n % 3 === 0) {
                        $rows[] = ['event', 'Signup', $t + 6000, ['plan' => $n % 2 ? 'pro' : 'team', 'amount' => (string) (5 + $n % 4) . '.5']];
                    }
                    $t += 30_000;
                }
                self::visit($store, "s$n", 'v' . ($n % 17), $start, [
                    'country' => $countries[$n % 4], 'source' => $n % 2 ? 'Google' : '', 'channel' => $n % 2 ? 'Search' : 'Direct',
                    'utmCampaign' => $campaigns[$n % count($campaigns)], 'device' => $n % 3 ? 'Desktop' : 'Mobile', 'browser' => $n % 4 ? 'Chrome' : 'Safari',
                ], $rows);
            }
        }
        $store->saveGoal(['id' => str_repeat('a', 24), 'site' => 'default', 'name' => 'Signup', 'kind' => 'event', 'match' => 'Signup', 'clickBy' => '', 'valueMode' => 'prop', 'value' => 0, 'valueProp' => 'amount', 'currency' => 'USD', 'createdAt' => $now]);
        $store->saveGoal(['id' => str_repeat('b', 24), 'site' => 'default', 'name' => 'Thanks', 'kind' => 'page', 'match' => '/th*', 'clickBy' => '', 'valueMode' => 'fixed', 'value' => 4.25, 'valueProp' => '', 'currency' => 'EUR', 'createdAt' => $now]);
        $store->saveGoal(['id' => str_repeat('c', 24), 'site' => 'default', 'name' => 'Cart', 'kind' => 'page', 'match' => '/#/cart', 'clickBy' => '', 'valueMode' => 'none', 'value' => 0, 'valueProp' => '', 'currency' => 'USD', 'createdAt' => $now]);
        $store->saveFunnel(['id' => str_repeat('f', 24), 'site' => 'default', 'name' => 'F', 'steps' => [['kind' => 'page', 'match' => '/'], ['kind' => 'page', 'match' => '/pricing'], ['kind' => 'event', 'match' => 'Signup']], 'createdAt' => $now]);
        $store->insertLink(['id' => str_repeat('l', 24), 'site' => 'default', 'domain' => '', 'slug' => 'go', 'name' => 'Go', 'url' => 'https://example.com/', 'createdAt' => $now - self::DAY, 'updatedAt' => $now - self::DAY]);
        $store->addLinkDomain('go.example.com', 'default', $now);
        for ($i = 0; $i < 6; $i++) {
            $store->insertEvent(['site' => 'default', 'ts' => $now - $i * 7 * self::HOUR, 'kind' => 'click', 'visitor' => $i % 2 ? "cv$i" : '', 'session' => '', 'pageview' => '', 'path' => '', 'hostname' => '', 'title' => '', 'name' => '', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => str_repeat('l', 24)]);
            $store->insertEvent(['site' => 'default', 'ts' => $now - $i * 5 * self::HOUR, 'kind' => 'fetch', 'visitor' => '', 'session' => '', 'pageview' => '', 'path' => $pages[$i % 3], 'hostname' => 'example.com', 'title' => '', 'name' => $i % 2 ? 'GPTBot' : 'ClaudeBot', 'props' => ['company' => 'X'], 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        }
        $store->insertShare(['id' => str_repeat('s', 24), 'site' => 'default', 'name' => 'Client', 'createdAt' => $now]);
        $store->insertToken(['id' => str_repeat('k', 24), 'name' => 'Script', 'site' => '', 'scope' => 'manage', 'hash' => str_repeat('h', 64), 'hint' => 'abcd', 'createdAt' => $now, 'lastUsedAt' => null]);
        $store->insertReport(['id' => str_repeat('r', 24), 'site' => 'default', 'email' => 'a@example.com', 'frequency' => 'weekly', 'lang' => 'en', 'token' => str_repeat('q', 32), 'origin' => '', 'lastPeriod' => '', 'lastSentAt' => null, 'createdAt' => $now]);
        $store->setSetting('remote:a', '1');
        $store->salt('2026-10-06', str_repeat('9', 64));
        self::buildDays($store, 'default', $now - 7 * self::DAY, $now - 3 * self::DAY);

        $calls = [];
        $add = static function (string $method, mixed ...$args) use (&$calls): void {
            $calls[] = ['method' => $method, 'args' => $args];
        };
        $add('sites');
        $add('siteOverrides');
        $add('rollupDays', 'default');
        $filters = [[], [['dimension' => 'country', 'op' => 'is', 'value' => 'GB']], [['dimension' => 'page', 'op' => 'contains', 'value' => 'über']], [['dimension' => 'event', 'op' => 'not', 'value' => 'Signup']], [['dimension' => 'utm_campaign', 'op' => 'contains', 'value' => 'ÉMILE']]];
        foreach ([[$now - 8 * self::DAY, $now + self::DAY], [$now - 5 * self::DAY - 3 * self::HOUR, $now - self::DAY]] as [$from, $to]) {
            foreach ($filters as $f) {
                $query = ['site' => 'default', 'from' => $from, 'to' => $to, 'filters' => $f];
                $add('stats', $query);
                $add('hourly', $query);
                foreach (['page', 'hostname', 'event', 'entry', 'exit', 'source', 'channel', 'utm_campaign', 'country', 'device', 'browser', 'ai_agent', 'ai_page'] as $dimension) {
                    $add('breakdown', $query, $dimension, 5, 0);
                }
                $add('goalTotalsAll', $query, $store->goals('default'));
                $add('funnelCounts', $query, $store->funnels('default')[0]);
                $add('journeyPages', $query, 3);
                $add('eventPropKeys', $query, 'Signup');
                $add('eventPropValues', $query, 'Signup', 'plan', 5);
                foreach ($store->goals('default') as $g) {
                    $add('goalBreakdown', $query, $g, 'path', 5);
                }
            }
            $add('links', 'default', $from, $to);
        }
        $buckets = [];
        for ($i = 0; $i < 12; $i++) {
            $buckets[] = ['start' => $now - (11 - $i) * self::DAY, 'end' => $now - (10 - $i) * self::DAY];
        }
        foreach ($filters as $f) {
            $add('series', ['site' => 'default', 'filters' => $f], $buckets);
            $add('goalSeries', ['site' => 'default', 'filters' => $f], $store->goals('default')[0], $buckets);
        }
        $add('linkSeries', 'default', str_repeat('l', 24), $buckets);
        $add('realtime', 'default', $now - 9 * self::HOUR);
        $add('goals');
        $add('funnels', 'default');
        $add('linkBySlug', 'go');
        $add('linkDomains');
        $add('shares', 'default');
        $add('tokens');
        $add('reports');
        $add('settingsStartingWith', 'remote:');
        $add('saltIfExists', '2026-10-06');
        $add('pageview', 'default', 'pv3x1');
        return $calls;
    }
}
