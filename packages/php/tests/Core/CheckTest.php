<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Runlight;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;
use Runlight\Tests\Store\Databases;
use Runlight\Tests\Store\WatchedDb;

/** The scheduled check and the rollups it builds, as rollups.test.ts and hardening.test.ts test the process around the store. */
final class CheckTest extends CoreTestCase
{
    private const PAGES = ['/', '/blog/one', '/blog/two', '/pricing', '/about'];
    private const REFERRERS = ['https://www.google.com/', 'https://news.ycombinator.com/', '', 'https://chatgpt.com/', 'https://t.co/x'];
    private const COUNTRIES = ['GB', 'US', 'DE', 'CA'];

    /** Every report this test compares before and after the days are built. */
    private static function everything(Harness $t): array
    {
        $out = [];
        $ranges = ['7d' => $t->query('2026-09-30', '2026-10-06'), '30d' => $t->query('2026-09-07', '2026-10-06'), 'some' => $t->query('2026-09-29', '2026-10-03'), 'all' => $t->all()];
        foreach ($ranges as $name => $q) {
            $out["stats $name"] = $t->stats($q);
            $out["hourly $name"] = $t->store()->hourly($q);
            foreach (['page', 'event', 'entry', 'exit', 'source', 'channel', 'referrer', 'country', 'browser', 'device', 'os'] as $dimension) {
                $out["$dimension $name"] = $t->store()->breakdown($q, $dimension, 3, 0);
                $out["$dimension $name page 2"] = $t->store()->breakdown($q, $dimension, 3, 3);
            }
        }
        $out['filtered'] = $t->stats($t->query('2026-09-07', '2026-10-06', null, [['dimension' => 'country', 'op' => 'is', 'value' => 'GB']]));
        return $out;
    }

    #[DataProvider('kinds')]
    public function testReportsReadFromDailyRollupsMatchReportsReadFromEveryVisit(string $kind): void
    {
        // Toronto, so local days and UTC days differ, starting ten days back.
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com'], 'timezone' => 'America/Toronto']]);
        $start = $t->now;
        $t->advance(-10 * 24 * self::HOUR);
        $n = 0;
        for ($day = 0; $day < 10; $day++) {
            for ($v = 0; $v < 6; $v++) {
                $n++;
                $init = ['ip' => '203.0.113.' . ($n % 40), 'headers' => ['x-vercel-ip-country' => self::COUNTRIES[$n % 4]]];
                if ($n % 3 === 0) {
                    $init['ua'] = Harness::SAFARI_IPHONE;
                }
                for ($p = 0; $p < 1 + ($n % 3); $p++) {
                    $id = "pv{$n}x$p";
                    $t->send(['k' => 'pageview', 'u' => 'https://example.com' . self::PAGES[($n + $p) % 5], 'r' => $p === 0 ? self::REFERRERS[$n % 5] : '', 'i' => $id], $init);
                    $t->advance(20_000 + ($n % 5) * 7_000);
                    if ($n % 2 === 0) {
                        $t->send(['k' => 'engagement', 'u' => 'https://example.com/', 'i' => $id, 'e' => 9_000 + $n * 100, 'd' => 40 + ($n % 60)], $init);
                    }
                    if ($n % 4 === 0) {
                        $t->send(['k' => 'event', 'u' => 'https://example.com/', 'i' => $id, 'n' => 'Signup'], $init);
                    }
                }
                $t->advance(3 * self::HOUR + ($n % 7) * 60_000);
            }
            // A visit that runs past midnight: it belongs to the day it started.
            $t->advance(24 * self::HOUR - 6 * (3 * self::HOUR) - 30 * 60_000);
        }
        $t->advance($start - $t->now + 2 * self::HOUR);

        $before = self::everything($t);
        $built = 0;
        for ($made = $t->rl->buildRollups(); $made > 0; $made = $t->rl->buildRollups()) {
            $built += $made;
        }
        self::assertGreaterThanOrEqual(8, $built);
        self::assertSame(0, $t->rl->buildRollups(), 'a built day is not built again');
        self::assertEquals($before, self::everything($t));
    }

    #[DataProvider('kinds')]
    public function testALateEventAndEngagementOnAnOldPageviewAreCountedOnceTheDayIsBuiltAgain(string $kind): void
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC']]);
        // Evening of October 5th, then rollups built the next morning.
        $t->now = self::utc(2026, 10, 5, 20);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'late1'], ['ip' => '203.0.113.50']);
        $t->advance(7 * self::HOUR);
        self::assertGreaterThanOrEqual(1, $t->rl->buildRollups());
        // The tab was left open overnight: its event and engagement arrive now.
        $t->send(['k' => 'event', 'u' => 'https://example.com/', 'i' => 'late1', 'n' => 'Signup'], ['ip' => '203.0.113.50']);
        $t->send(['k' => 'engagement', 'u' => 'https://example.com/', 'i' => 'late1', 'e' => 60_000, 'd' => 80], ['ip' => '203.0.113.50']);
        $q = $t->query('2026-10-05', '2026-10-05');
        $read = fn (): array => ['stats' => $t->stats($q), 'events' => $t->store()->breakdown($q, 'event', 10, 0), 'pages' => $t->store()->breakdown($q, 'page', 10, 0)];
        $t->rl->buildRollups();
        $rolled = $read();
        $t->store()->clearRollups('default');
        $raw = $read();
        self::assertEquals($raw, $rolled);
        self::assertEquals(0, $raw['stats']['bounceRate'], 'the event means the visit did not bounce');
        self::assertSame(['Signup'], array_column($raw['events'], 'value'));
    }

    #[DataProvider('kinds')]
    public function testAfterATimezoneChangeOnlyDaysAfterItAreBuilt(string $kind): void
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC']]);
        $t->rl->init();
        $t->now = self::utc(2026, 10, 3, 10);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'r' => '', 'i' => 'a1'], ['ip' => '203.0.113.1']);
        $t->advance(10 * self::HOUR);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'r' => '', 'i' => 'a2'], ['ip' => '203.0.113.1']);
        $t->now = self::utc(2026, 10, 4, 12);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'r' => '', 'i' => 'b1'], ['ip' => '203.0.113.2']);
        $t->now = self::utc(2026, 10, 6, 12);
        self::assertGreaterThanOrEqual(2, $t->rl->buildRollups());

        $t->rl->updateSite('default', ['timezone' => 'Asia/Tokyo']);
        $q = $t->query('2026-10-03', '2026-10-05');
        $before = $t->stats($q);
        self::assertSame(0, $t->rl->buildRollups(), 'days before the change stay counted visit by visit');
        self::assertSame($before, $t->stats($q));
        self::assertSame(2, $before['visitors']);
        // A day that starts after the change is built as usual.
        $t->advance(3 * 24 * self::HOUR);
        self::assertGreaterThanOrEqual(1, $t->rl->buildRollups());
    }

    public function testTwoProcessesOnOneDatabaseAStaleTimezoneBuildsNothingAndClearsNothing(): void
    {
        $file = tempnam(sys_get_temp_dir(), 'runlight-zones-');
        try {
            $now = self::utc(2026, 10, 3, 12);
            $clock = static function () use (&$now): int {
                return $now;
            };
            $old = new Runlight(['store' => Stores::sqlite($file), 'site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC'], 'now' => $clock]);
            $old->init();
            $old->collect(Harness::hit('https://example.com/runlight/e', ['k' => 'pageview', 'u' => 'https://example.com/'], ['ip' => '203.0.113.1', 'ua' => Harness::SAFARI_IPHONE]));
            $now = self::utc(2026, 10, 6, 12);
            self::assertGreaterThanOrEqual(2, $old->buildRollups(), 'the old process builds in UTC');
            $built = static fn (): int => (int) $old->store->db->all('SELECT COUNT(*) AS n FROM rl_rollup_days')[0]['n'];

            // A new copy starts with the timezone changed in code: it clears the old days once, at startup.
            $fresh = new Runlight(['store' => Stores::sqlite($file), 'site' => ['hostnames' => ['example.com'], 'timezone' => 'Asia/Tokyo'], 'now' => $clock]);
            $fresh->init();
            self::assertSame(0, $built());
            // The old copy, still running, neither builds in UTC nor clears what the new one does.
            $now += 3 * self::DAY;
            self::assertSame(0, $old->buildRollups());
            self::assertGreaterThanOrEqual(1, $fresh->buildRollups());
            $afterFresh = $built();
            self::assertSame(0, $old->buildRollups());
            self::assertSame($afterFresh, $built(), 'nothing cleared by the stale copy');
            $old->store->close();
            $fresh->store->close();
        } finally {
            @unlink($file);
        }
    }

    public function testATimezoneChangedInTheDashboardReachesAnotherProcessAtItsNextCheck(): void
    {
        $file = tempnam(sys_get_temp_dir(), 'runlight-zones-');
        try {
            $now = self::utc(2026, 10, 6, 12);
            $clock = static function () use (&$now): int {
                return $now;
            };
            $a = new Runlight(['store' => Stores::sqlite($file), 'site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC'], 'now' => $clock]);
            $b = new Runlight(['store' => Stores::sqlite($file), 'site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC'], 'now' => $clock]);
            $a->init();
            $b->init();
            $a->updateSite('default', ['timezone' => 'Europe/Paris']);
            self::assertSame('UTC', $b->site('default')['timezone']);
            // A visit after the change, and days enough for its day to be built.
            $b->store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [$now + self::DAY, $now + self::DAY]);
            $now += 3 * self::DAY;
            self::assertSame(0, $b->buildRollups(), 'holding the old timezone, it builds nothing');
            $b->check();
            self::assertSame('Europe/Paris', $b->site('default')['timezone']);
            $days = $b->store->rollupDays('default');
            sort($days);
            self::assertSame(['2026-10-07', '2026-10-08'], $days, 'then it builds the days after the change');
            $a->store->close();
            $b->store->close();
        } finally {
            @unlink($file);
        }
    }

    #[DataProvider('kinds')]
    public function testEventsLeftBehindByAnOlderVersionWhoseVisitRetentionRemovedAreSweptOnce(string $kind): void
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC']]);
        $t->rl->init();
        $old = $t->now - 400 * self::DAY;
        $db = $t->store()->db;
        $db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews) VALUES ('s1', 'default', 'v1', ?, ?, 1)", [$old, $old]);
        $db->run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', 'v1', 's1', 'p1', '/', 'example.com')", [$old]);
        // An event that joined the visit long after it started, as older versions allowed.
        $db->run("INSERT INTO rl_events (site, ts, kind, visitor, session, name, path, hostname) VALUES ('default', ?, 'event', 'v1', 's1', 'Late', '/', 'example.com')", [$t->now - 30 * self::DAY]);
        $t->rl->setRetention('default', 6);
        $t->rl->idle();
        $t->rl->check();
        self::assertSame([], $db->all("SELECT name FROM rl_events WHERE site = 'default'"));
        self::assertSame('1', $t->store()->setting('orphans-swept:default'));
    }

    public function testPlannerStatisticsAreGatheredOnceADay(): void
    {
        $watched = new WatchedDb(Databases::fresh('sqlite')->db);
        $analyzed = 0;
        $watched->before = static function (string $sql) use (&$analyzed): void {
            if ($sql === 'ANALYZE') {
                $analyzed++;
            }
        };
        $t = new Harness(new SqlStore($watched), ['site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC']]);
        $t->rl->init();
        self::assertSame(1, $analyzed, 'a database without statistics gets them at the start');
        $t->rl->check();
        $t->rl->check();
        self::assertSame(2, $analyzed, 'not again the same day');
        $t->advance(self::DAY);
        $t->rl->check();
        self::assertSame(3, $analyzed);
        self::assertNotEmpty($t->store()->db->all("SELECT name FROM sqlite_master WHERE name = 'sqlite_stat1'"), 'statistics written');
    }

    public function testShortLinkClicksAreNotVisitsInTheHeatmapRawOrRolledUpNorTheFirstVisit(): void
    {
        $clock = self::utc(2026, 10, 7, 12);
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'sites' => [['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']]], 'now' => static function () use (&$clock): int {
            return $clock;
        }]);
        $rl->init();
        $day = self::utc(2026, 10, 5, 15);
        // A session opened only by a short link click, then a real visit.
        $rl->store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'a', 'v1', ?, ?, 0, 0, 0)", [$day - 3_600_000, $day - 3_600_000]);
        $rl->store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'a', 'v2', ?, ?, 1, 0, 0)", [$day, $day]);
        self::assertSame($day, $rl->store->firstOwnVisit('a'));
        $query = ['site' => 'a', 'from' => self::utc(2026, 10, 1), 'to' => self::utc(2026, 10, 7), 'filters' => []];
        $sum = static fn (array $rows): int => array_sum(array_column($rows, 'visits'));
        self::assertSame(1, $sum($rl->store->hourly($query)), 'raw');
        $clock += 3 * 3_600_000;
        $rl->buildRollups();
        self::assertSame(1, $sum($rl->store->hourly($query)), 'rolled up');
    }

    public function testACheckReportsWhatItSent(): void
    {
        $t = new Harness('sqlite');
        self::assertSame(['ok' => true, 'reports' => ['sent' => 0, 'failed' => 0]], $t->rl->check());
    }
}
