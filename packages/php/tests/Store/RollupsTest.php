<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Json;
use Runlight\Store\SqlStore;

/** Daily rollups, as rollups.test.ts and counting.test.ts test them at the store. */
final class RollupsTest extends StoreTestCase
{
    private const PAGES = ['/', '/blog/one', '/blog/two', '/pricing', '/about'];
    private const SOURCES = ['Google', 'Hacker News', '', 'ChatGPT', 'Twitter'];
    private const COUNTRIES = ['GB', 'US', 'DE', 'CA'];

    /** Ten days of visits, some running past midnight, ending two hours before NOW. */
    private static function tenDays(SqlStore $store): void
    {
        $now = self::NOW - 10 * self::DAY;
        $n = 0;
        for ($day = 0; $day < 10; $day++) {
            for ($v = 0; $v < 6; $v++) {
                $n++;
                $start = $now;
                $rows = [];
                for ($p = 0; $p < 1 + $n % 3; $p++) {
                    $id = "pv{$n}x$p";
                    $rows[] = ['pageview', self::PAGES[($n + $p) % 5], $now, $id];
                    $now += 20_000 + ($n % 5) * 7_000;
                    if ($n % 2 === 0) {
                        $rows[] = ['engagement', $id, $now, 9_000 + $n * 100, 40 + $n % 60];
                    }
                    if ($n % 4 === 0) {
                        $rows[] = ['event', 'Signup', $now, null];
                    }
                }
                // Visitor ids change every day, as the daily salt changes them.
                Seed::visit($store, "s$n", 'v' . ($n % 4) . gmdate('Ymd', intdiv($start, 1000)), $start, [
                    'source' => self::SOURCES[$n % 5], 'channel' => self::SOURCES[$n % 5] === '' ? 'Direct' : 'Referral', 'referrerHost' => self::SOURCES[$n % 5] === '' ? '' : 'x.example',
                    'country' => self::COUNTRIES[$n % 4], 'device' => $n % 3 === 0 ? 'Mobile' : 'Desktop', 'browser' => $n % 3 === 0 ? 'Safari' : 'Chrome', 'os' => $n % 3 === 0 ? 'iOS' : 'macOS',
                ], $rows);
                $now += 3 * self::HOUR + ($n % 7) * self::MIN;
            }
            // A visit that runs past midnight belongs to the day it started.
            $now += self::DAY - 6 * (3 * self::HOUR) - 30 * self::MIN;
        }
    }

    /** Every report the dashboard asks the store for, as JSON, for comparing before and after. */
    private static function everything(SqlStore $store): array
    {
        $out = [];
        $ranges = [
            '7d' => [self::NOW - 7 * self::DAY, self::NOW + self::DAY],
            '30d' => [self::NOW - 30 * self::DAY, self::NOW + self::DAY],
            'odd' => [self::NOW - 6 * self::DAY - 5 * self::HOUR, self::NOW - 2 * self::DAY + 3 * self::HOUR],
            'today' => [self::NOW - 12 * self::HOUR, self::NOW + 12 * self::HOUR],
            'all' => [0, self::NOW + self::DAY],
        ];
        foreach ($ranges as $name => [$from, $to]) {
            $query = self::q($from, $to);
            $out["stats $name"] = $store->stats($query);
            $buckets = [];
            for ($at = $from === 0 ? self::NOW - 12 * self::DAY : $from; $at < $to; $at += self::DAY) {
                $buckets[] = ['start' => $at, 'end' => min($at + self::DAY, $to)];
            }
            $out["series $name"] = $store->series($query, $buckets);
            $hourly = $store->hourly($query);
            usort($hourly, static fn (array $a, array $b): int => $a['quarter'] <=> $b['quarter']);
            $out["hourly $name"] = $hourly;
            foreach (['page', 'event', 'entry', 'exit', 'source', 'channel', 'referrer', 'country', 'browser', 'device', 'os'] as $dimension) {
                $out["$dimension $name"] = $store->breakdown($query, $dimension, 3, 0);
                $out["$dimension $name page 2"] = $store->breakdown($query, $dimension, 3, 3);
            }
        }
        $out['filtered'] = $store->stats(self::q(self::NOW - 30 * self::DAY, self::NOW + self::DAY, ['country', 'is', 'GB']));
        return array_map(static fn ($v): string => Json::encode($v), $out);
    }

    #[DataProvider('kinds')]
    public function testReportsReadFromDailyRollupsMatchReportsReadFromEveryVisit(string $kind): void
    {
        $store = $this->store($kind);
        self::tenDays($store);
        $before = self::everything($store);
        $this->assertGreaterThanOrEqual(8, Seed::buildDays($store, 'default', self::NOW - 11 * self::DAY, self::NOW));
        $this->assertCount(11, $store->rollupDays('default'));
        $after = self::everything($store);
        foreach ($before as $key => $value) {
            $this->assertSame($value, $after[$key], $key);
        }

        // Proof the reports read the rollups: with the built days' raw visits gone, a long range still adds up.
        $span = $store->db->all('SELECT MIN(start_at) AS s, MAX(end_at) AS e FROM rl_rollup_days')[0];
        $store->db->run('DELETE FROM rl_events WHERE ts >= ? AND ts < ?', [(int) $span['s'], (int) $span['e'] - 2 * self::HOUR]);
        $store->db->run('DELETE FROM rl_sessions WHERE started_at >= ? AND started_at < ?', [(int) $span['s'], (int) $span['e'] - 2 * self::HOUR]);
        $again = self::everything($store);
        foreach (['stats 30d', 'source 30d', 'page 30d', 'event 30d', 'hourly 30d'] as $key) {
            $this->assertSame($before[$key], $again[$key], "$key comes from rollups");
        }
    }

    #[DataProvider('kinds')]
    public function testALateEventAndEngagementOnAnOldPageviewAreCountedOnceTheDayIsBuiltAgain(string $kind): void
    {
        $store = $this->store($kind);
        // Evening of October 5th, then rollups built the next morning.
        $start = gmmktime(20, 0, 0, 10, 5, 2026) * 1000;
        Seed::visit($store, 's1', 'v1', $start, [], [['pageview', '/', $start, 'late1']]);
        $day5 = gmmktime(0, 0, 0, 10, 5, 2026) * 1000;
        $store->buildRollupDay('default', '2026-10-05', $day5, $day5 + self::DAY);
        // The tab was left open overnight: its event and engagement arrive now.
        $late = $start + 7 * self::HOUR;
        $store->insertEvent(['site' => 'default', 'ts' => $late, 'kind' => 'event', 'visitor' => 'v1', 'session' => 's1', 'pageview' => 'late1', 'path' => '/', 'hostname' => 'example.com', 'title' => '', 'name' => 'Signup', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        $store->touchSession('s1', $late, 'event', '/', false);
        $store->insertEvent(['site' => 'default', 'ts' => $late, 'kind' => 'engagement', 'visitor' => 'v1', 'session' => 's1', 'pageview' => 'late1', 'path' => '/', 'hostname' => 'example.com', 'title' => '', 'name' => '', 'props' => null, 'engagedMs' => 60_000, 'scroll' => 80, 'link' => '']);
        $store->addEngagement('s1', 60_000);
        $store->touchedOldVisit('default', $start, $late - 2 * self::HOUR);
        $this->assertSame([], $store->rollupDays('default'), 'the day is forgotten');
        $store->touchedOldVisit('default', $start, $start - 1);
        $query = self::q($day5, $day5 + self::DAY);
        $read = static fn (): string => Json::encode([$store->stats($query), $store->breakdown($query, 'event', 10, 0), $store->breakdown($query, 'page', 10, 0)]);
        $store->buildRollupDay('default', '2026-10-05', $day5, $day5 + self::DAY);
        $rolled = $read();
        $store->clearRollups('default');
        $this->assertSame([], $store->rollupDays('default'));
        $this->assertSame($rolled, $read());
        $this->assertSame(0, $store->stats($query)['bounceRate'], 'the event means the visit did not bounce');
        $this->assertSame(['Signup'], array_column($store->breakdown($query, 'event', 10, 0), 'value'));
    }

    #[DataProvider('kinds')]
    public function testTiesComeInCodePointOrderTheSameBeforeAndAfterTheDaysAreBuilt(string $kind): void
    {
        $store = $this->store($kind);
        $values = ['alpha', 'Zeta', 'beta', 'Gamma', 'émile', 'Émile', '_x', 'a-b', 'ab'];
        $t = self::NOW - self::DAY;
        foreach ($values as $i => $value) {
            Seed::visit($store, "s$i", "v$i", $t + $i * self::MIN, ['utmCampaign' => $value], [['pageview', '/', $t + $i * self::MIN, "pv$i"]]);
        }
        $expected = $values;
        sort($expected, SORT_STRING);
        $week = self::q(self::NOW - 7 * self::DAY, self::NOW + self::DAY);
        $this->assertSame($expected, array_column($store->breakdown($week, 'utm_campaign', 20, 0), 'value'), 'read from every visit');
        Seed::buildDays($store, 'default', self::NOW - 2 * self::DAY, self::NOW);
        $this->assertSame($expected, array_column($store->breakdown($week, 'utm_campaign', 20, 0), 'value'), 'read from rollups');
    }

    /** Four visits three days back, built, as the two clearing tests start. */
    private function built(string $kind, int $days): array
    {
        $store = $this->store($kind);
        for ($d = 0; $d < $days; $d++) {
            $t = self::NOW - ($days + 2 - $d) * self::DAY;
            Seed::visit($store, "s$d", "v$d", $t, [], [['pageview', '/', $t, "d$d"]]);
        }
        Seed::buildDays($store, 'default', self::NOW - ($days + 3) * self::DAY, self::NOW - self::DAY);
        $month = self::q(self::NOW - 30 * self::DAY, self::NOW + self::DAY);
        return [$store, $month, $store->stats($month)];
    }

    #[DataProvider('kinds')]
    public function testADayBuiltByAnotherProcessWhileItIsBeingClearedIsNeverLeftMarkedBuiltWithoutItsNumbers(string $kind): void
    {
        [$store, $month, $before] = $this->built($kind, 4);
        $watched = new WatchedDb($store->db);
        $view = new SqlStore($watched);
        $raced = false;
        $watched->afterRun = function (string $sql) use (&$raced, $watched, $store): void {
            if (!$raced && str_starts_with($sql, 'DELETE FROM rl_rollup_days WHERE site = ? AND start_at')) {
                $raced = true;
                $watched->afterRun = null;
                // Another process builds the days right after their marks are deleted.
                Seed::buildDays($store, 'default', self::NOW - 7 * self::DAY, self::NOW - self::DAY);
            }
        };
        $view->clearRollups('default', ['from' => self::NOW - 4 * self::DAY, 'to' => self::NOW]);
        $this->assertTrue($raced);
        $this->assertSame($before, $store->stats($month));
    }

    #[DataProvider('kinds')]
    public function testClearingDaysThatStopsPartWayLeavesNoneMarkedBuiltWithoutItsNumbers(string $kind): void
    {
        [$store, $month, $before] = $this->built($kind, 8);
        $watched = new WatchedDb($store->db);
        $deletes = 0;
        $watched->before = function (string $sql) use (&$deletes): void {
            if (str_starts_with($sql, 'DELETE FROM rl_rollups WHERE') && ++$deletes > 3) {
                throw new \RuntimeException('connection lost');
            }
        };
        try {
            (new SqlStore($watched))->clearRollups('default');
            $this->fail('the clear should have stopped');
        } catch (\RuntimeException $error) {
            $this->assertSame('connection lost', $error->getMessage());
        }
        $this->assertSame($before, $store->stats($month));
        Seed::buildDays($store, 'default', self::NOW - 12 * self::DAY, self::NOW - self::DAY);
        $this->assertSame($before, $store->stats($month));
    }

    #[DataProvider('kinds')]
    public function testRetentionDropsOldVisitsWithTheirEventsAndForgetsTheDaysTheyWereIn(string $kind): void
    {
        $store = $this->store($kind);
        foreach ([gmmktime(0, 0, 0, 10, 1, 2025), gmmktime(0, 0, 0, 7, 1, 2026), gmmktime(0, 0, 0, 10, 6, 2026)] as $i => $at) {
            $t = $at * 1000 + self::HOUR;
            Seed::visit($store, "s$i", "v$i", $t, [], [['pageview', '/', $t, "p$i"], ['event', 'E', $t + 1, null]]);
        }
        // An event of the oldest visit that came after the cutoff goes with it.
        $store->insertEvent(['site' => 'default', 'ts' => gmmktime(0, 0, 0, 10, 1, 2025) * 1000 + self::DAY, 'kind' => 'event', 'visitor' => 'v0', 'session' => 's0', 'pageview' => '', 'path' => '/', 'hostname' => '', 'title' => '', 'name' => 'Late', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        $all = self::q(0, self::NOW + self::DAY);
        $this->assertSame(3, $store->stats($all)['visits']);
        $store->buildRollupDay('default', '2026-07-01', gmmktime(0, 0, 0, 7, 1, 2026) * 1000, gmmktime(0, 0, 0, 7, 2, 2026) * 1000);
        $store->dropBefore('default', gmmktime(0, 0, 0, 4, 6, 2026) * 1000);
        $this->assertSame(2, $store->stats($all)['visits'], 'the visit from a year ago is gone');
        $this->assertSame(0, (int) $store->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 's0'")[0]['n'], 'its events, even the late one');
        $this->assertSame(['2026-07-01'], $store->rollupDays('default'), 'a day after the cutoff stays built');
        $store->dropBefore('default', gmmktime(0, 0, 0, 8, 1, 2026) * 1000);
        $this->assertSame(1, $store->stats($all)['visits']);
        $this->assertSame([], $store->rollupDays('default'), 'a day before the cutoff is built again later');

        // Events whose visit is gone, as an older version left them, are swept.
        $store->insertEvent(['site' => 'default', 'ts' => self::NOW - self::DAY, 'kind' => 'pageview', 'visitor' => 'x', 'session' => 'gone', 'pageview' => 'g', 'path' => '/', 'hostname' => '', 'title' => '', 'name' => '', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        $store->insertEvent(['site' => 'default', 'ts' => self::NOW - self::DAY, 'kind' => 'fetch', 'visitor' => '', 'session' => '', 'pageview' => '', 'path' => '/', 'hostname' => '', 'title' => '', 'name' => 'GPTBot', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        $store->dropOrphans('default', 0, self::NOW + self::DAY);
        $this->assertSame(0, (int) $store->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE session = 'gone'")[0]['n']);
        $this->assertSame(1, (int) $store->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'fetch'")[0]['n'], 'rows of no visit stay');
    }
}
