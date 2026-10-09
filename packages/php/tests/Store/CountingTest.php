<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Funnels;
use Runlight\Goals;
use Runlight\Sources;
use Runlight\Store\SqlStore;

/**
 * What the reports count, at the store: the store-level parts of counting.test.ts, filters.test.ts,
 * goals.test.ts, funnels.test.ts, journeys.test.ts, props.test.ts, and mysql.test.ts. Visits are written
 * through the store as the tracker writes them.
 */
final class CountingTest extends StoreTestCase
{
    /** @return list<int|float> the stats numbers asked for */
    private static function pick(array $stats, string ...$keys): array
    {
        return array_map(static fn (string $k) => $stats[$k], $keys);
    }

    #[DataProvider('kinds')]
    public function testGoalsFunnelsAndEventPropertiesCountVisitsByWhenTheyStartedWithOrWithoutAFilter(string $kind): void
    {
        $store = $this->store($kind);
        // Two people start at 23:50 on the 5th and sign up at 00:10 on the 6th; a third visits on the 6th.
        $start = self::NOW - 12 * self::HOUR - 10 * self::MIN;
        foreach ([1, 2] as $i) {
            Seed::visit($store, "s$i", "v$i", $start, ['country' => 'GB'], [
                ['pageview', '/signup', $start, "p$i"],
                ['event', 'Signup', $start + 20 * self::MIN, ['plan' => 'pro']],
            ]);
        }
        Seed::visit($store, 's3', 'v3', $start + 80 * self::MIN, [], [['pageview', '/', $start + 80 * self::MIN, 'q']]);
        $goal = self::goal(str_repeat('a', 24), ['name' => 'Signup', 'match' => 'Signup']);
        $store->saveGoal($goal);
        $funnel = ['id' => str_repeat('b', 24), 'site' => 'default', 'name' => 'Signup', 'steps' => [['kind' => 'page', 'match' => '/signup'], ['kind' => 'event', 'match' => 'Signup']], 'createdAt' => 0];
        $store->saveFunnel($funnel);
        $day5 = gmmktime(0, 0, 0, 10, 5, 2026) * 1000;
        foreach ([[], [['country', 'not', 'ZZ']], [['page', 'contains', '/']]] as $filters) {
            $read = function (int $from) use ($store, $goal, $funnel, $filters): array {
                $query = self::q($from, $from + self::DAY, ...$filters);
                $totals = $store->goalTotals($query, $goal);
                $visitors = $store->visitors($query);
                $events = array_map(static fn (array $r): string => "{$r['value']}:{$r['events']}", $store->breakdown($query, 'event', 10, 0));
                return [$totals['conversions'], $visitors > 0 ? $totals['visitors'] / $visitors : 0, $store->funnelCounts($query, $funnel), count($store->eventPropKeys($query, 'Signup')), $events];
            };
            $label = json_encode($filters);
            $this->assertEquals([2, 1, [2, 2], 1, ['Signup:2']], $read($day5), "the visits that started on the 5th $label");
            $this->assertEquals([0, 0, [0, 0], 0, []], $read($day5 + self::DAY), "nothing that started on the 6th converted $label");
        }
    }

    #[DataProvider('kinds')]
    public function testContainsFindsCapitalsBeyondAsciiAndTwoPageFiltersCountBothPages(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, ['utmCampaign' => 'Über'], [['pageview', '/a', $t, 'a'], ['pageview', '/b', $t + self::MIN, 'b']]);
        foreach (['über', 'Über', 'ÜBER', 'ber'] as $value) {
            $this->assertSame(1, $store->stats(self::today(['utm_campaign', 'contains', $value]))['visits'], "contains $value");
        }
        $both = $store->stats(self::today(['page', 'is', '/a'], ['page', 'is', '/b']));
        $this->assertSame([1, 2], self::pick($both, 'visits', 'pageviews'));
    }

    #[DataProvider('kinds')]
    public function testAPageGoalFunnelOrFilterWrittenInPlainLettersMatchesTheEncodedPath(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, [], [['pageview', (string) Sources::recordedPath('/café'), $t, 'a']]);
        $goal = Goals::goalFrom(['name' => 'Café', 'kind' => 'page', 'match' => '/café'], 'default', [], self::NOW);
        $store->saveGoal($goal);
        $this->assertSame(1, $store->goalTotals(self::today(), $goal)['conversions']);
        $this->assertSame(1, $store->stats(self::today(['page', 'is', '/café']))['visits']);
    }

    #[DataProvider('kinds')]
    public function testAnEventThatJoinsAVisitAlreadyEndedCountsWithoutReopeningIt(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - 6 * self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, [], [['pageview', '/', $t, 'p1']]);
        $store->insertEvent(['site' => 'default', 'ts' => $t + 2 * self::HOUR, 'kind' => 'event', 'visitor' => 'v1', 'session' => 's1', 'pageview' => 'p1', 'path' => '/', 'hostname' => 'example.com', 'title' => '', 'name' => 'Late', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        $store->touchSession('s1', $t + 2 * self::HOUR, 'event', '/', false);
        $this->assertNull($store->openSession('default', ['v1'], $t + self::HOUR), 'still ended');
        $this->assertSame([['value' => 'Late', 'visitors' => 1, 'events' => 1]], $store->breakdown(self::today(), 'event', 10, 0));
        $this->assertSame(0, $store->stats(self::today())['bounceRate']);
    }

    #[DataProvider('kinds')]
    public function testTimeOnPageIsOverEveryPageviewCountingQuickOnesAsNone(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        for ($i = 0; $i < 4; $i++) {
            $rows = [['pageview', '/a', $t, "v$i"]];
            if ($i === 0) {
                $rows[] = ['engagement', 'v0', $t + 1000, 60_000, 50];
            }
            Seed::visit($store, "s$i", "v$i", $t, [], $rows);
        }
        $row = $store->breakdown(self::today(), 'page', 10, 0)[0];
        $this->assertSame([15_000, 50], [$row['timeOnPage'], $row['scrollDepth']]);
    }

    public function testJourneysAppliesAFilterBeforeItsCapOnVisitsAndSaysWhenTheCapWasReached(): void
    {
        $store = $this->store('sqlite');
        $start = gmmktime(0, 0, 0, 10, 6, 2026) * 1000;
        // Ten visits from Britain early in the day, then more from the US than journeys reads.
        $store->transaction(function (SqlStore $tx) use ($start): void {
            for ($i = 0; $i < 10 + SqlStore::JOURNEY_VISITS; $i++) {
                $ts = $start + $i;
                $tx->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, country) VALUES (?, 'default', ?, ?, ?, 1, '/', '/', ?)", ["s$i", "v$i", $ts, $ts, $i < 10 ? 'GB' : 'US']);
                $tx->db->run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, ?, '/', 'example.com')", [$ts, "v$i", "s$i", "p$i"]);
            }
        });
        $sessions = static fn (array $answer): int => count(array_unique(array_column($answer['rows'], 'session')));
        $britain = $store->journeyPages(self::q($start, $start + self::DAY, ['country', 'is', 'GB']), 5);
        $this->assertSame(10, $sessions($britain), 'every British visit, though they are older than the newest visits read');
        $this->assertFalse($britain['sampled']);
        $all = $store->journeyPages(self::q($start, $start + self::DAY), 5);
        $this->assertSame(SqlStore::JOURNEY_VISITS, $sessions($all));
        $this->assertTrue($all['sampled']);
    }

    #[DataProvider('kinds')]
    public function testAPageGoalOrFunnelStepForAHashRouteCountsThatRouteOnly(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        for ($i = 0; $i < 5; $i++) {
            $rows = [['pageview', '/', $t, "h$i"]];
            if ($i < 2) {
                $rows[] = ['pageview', '/#/cart', $t + 1000, "c$i"];
                $rows[] = ['pageview', '/#/thanks', $t + 2000, "t$i"];
            }
            Seed::visit($store, "s$i", "v$i", $t, [], $rows);
        }
        $goal = Goals::goalFrom(['name' => 'Thanks', 'kind' => 'page', 'match' => '/#/thanks'], 'default', [], self::NOW);
        $funnel = Funnels::funnelFrom(['name' => 'Checkout', 'steps' => [['kind' => 'page', 'match' => '/#/cart'], ['kind' => 'page', 'match' => 'https://example.com/#/thanks']]], 'default', [], self::NOW);
        $totals = $store->goalTotals(self::today(), $goal);
        $this->assertSame(['/#/thanks', 2, 2], [$goal['match'], $totals['conversions'], $totals['visitors']]);
        $this->assertSame(['/#/cart', '/#/thanks'], array_column($funnel['steps'], 'match'));
        $this->assertSame([2, 2], $store->funnelCounts(self::today(), $funnel));
    }

    #[DataProvider('kinds')]
    public function testPageAndHostnameFiltersTogetherCountPageviewsMatchingBoth(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, [], [
            ['pageview', '/pricing', $t, 'a', 'example.com'],
            ['pageview', '/start', $t + 1000, 'b', 'docs.example.com'],
            ['pageview', '/pricing', $t + 2000, 'c', 'docs.example.com'],
        ]);
        $query = self::today(['page', 'is', '/pricing'], ['hostname', 'is', 'docs.example.com']);
        $this->assertSame(1, $store->stats($query)['pageviews']);
        $this->assertSame([['/pricing', 1]], array_map(static fn (array $r): array => [$r['value'], $r['pageviews']], $store->breakdown($query, 'page', 10, 0)));
    }

    #[DataProvider('kinds')]
    public function testContainsIgnoresCaseInAnyMixInPathsTooAndFiltersTakePathsAsTheBrowserWritesThem(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, ['utmCampaign' => 'ÉcoleÉté'], [['pageview', (string) Sources::recordedPath('/Über-uns'), $t, 'a']]);
        Seed::visit($store, 's2', 'v2', $t, [], [['pageview', (string) Sources::recordedPath('/a^b'), $t, 'b']]);
        Seed::visit($store, 's3', 'v3', $t, [], [['pageview', (string) Sources::recordedPath('/#/x{y}'), $t, 'c']]);
        $visits = static fn (string $d, string $op, string $v): int => $store->stats(self::today([$d, $op, $v]))['visits'];
        foreach (['écoleété', 'ÉCOLEÉTÉ', 'eÉté'] as $value) {
            $this->assertSame(1, $visits('utm_campaign', 'contains', $value), $value);
        }
        foreach (['über', 'ÜBER', 'Über-Uns'] as $value) {
            $this->assertSame(1, $visits('page', 'contains', $value), $value);
        }
        $this->assertSame(1, $visits('page', 'is', '/a^b'));
        $this->assertSame(1, $visits('page', 'is', '/#/x{y}'));
    }

    #[DataProvider('kinds')]
    public function testTimeOnPageLeavesOutImportedViewsWhichCanReportNoTime(string $kind): void
    {
        $store = $this->store($kind);
        // Nine pageviews written as the Umami import writes them: no pageview id, never any engaged time.
        $day = gmmktime(10, 0, 0, 10, 5, 2026) * 1000;
        for ($i = 0; $i < 9; $i++) {
            $store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, entry_path, exit_path, imported) VALUES (?, 'default', ?, ?, ?, 1, '/pricing', '/pricing', 1)", ["i$i", "v$i", $day + $i, $day + $i]);
            $store->db->run("INSERT INTO rl_events (site, ts, kind, visitor, session, pageview, path, hostname) VALUES ('default', ?, 'pageview', ?, ?, '', '/pricing', 'example.com')", [$day + $i, "v$i", "i$i"]);
        }
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 'live', 'lv', $t, [], [['pageview', '/pricing', $t, 'live'], ['engagement', 'live', $t + 1000, 60_000, null]]);
        $week = self::q(self::NOW - 7 * self::DAY, self::NOW + self::DAY);
        $row = static fn (): array => array_values(array_filter($store->breakdown($week, 'page', 10, 0), static fn (array $r): bool => $r['value'] === '/pricing'))[0];
        $this->assertSame([10, 60_000], [$row()['pageviews'], $row()['timeOnPage']]);
        Seed::buildDays($store, 'default', self::NOW - 7 * self::DAY, self::NOW + self::DAY);
        $this->assertSame(60_000, $row()['timeOnPage'], 'the same once the days are built');
    }

    #[DataProvider('kinds')]
    public function testAFilterPicksVisitsAndTheNumbersDescribeThoseWholeVisits(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - 3 * self::HOUR;
        // Visit A: two pages and a Signup. Visit B: one page, no Signup.
        Seed::visit($store, 'a', 'va', $t, [], [['pageview', '/', $t, 'a1'], ['pageview', '/pricing', $t + 30_000, 'a2'], ['event', 'Signup', $t + 60_000, null]]);
        Seed::visit($store, 'b', 'vb', $t + 60_000, [], [['pageview', '/blog', $t + 60_000, 'b1']]);
        $stats = static fn (array ...$f): array => $store->stats(self::today(...$f));
        $this->assertSame([1, 1, 2], self::pick($stats(['event', 'is', 'Signup']), 'visitors', 'visits', 'pageviews'), 'the visits with a Signup, and all their pageviews');
        $this->assertSame([1, 1], self::pick($stats(['page', 'is', '/pricing']), 'visits', 'pageviews'), "a page filter counts that page's views");
        $this->assertSame(1, $stats(['page', 'is', '/pricing'], ['event', 'is', 'Signup'])['visits'], 'a page and an event in the same visit');
        $this->assertSame([1, 1], self::pick($stats(['event', 'not', 'Signup']), 'visits', 'pageviews'), 'is not means visits that never had one');

        $buckets = [];
        for ($h = 0; $h < 24; $h++) {
            $buckets[] = ['start' => self::NOW - 12 * self::HOUR + $h * self::HOUR, 'end' => self::NOW - 11 * self::HOUR + $h * self::HOUR];
        }
        $points = $store->series(['site' => 'default', 'filters' => [['dimension' => 'event', 'op' => 'is', 'value' => 'Signup']]], $buckets);
        $this->assertSame([1, 2], [array_sum(array_column($points, 'visits')), array_sum(array_column($points, 'pageviews'))], 'the chart agrees');
        $pages = array_column($store->breakdown(self::today(['event', 'is', 'Signup']), 'page', 10, 0), 'value');
        sort($pages);
        $this->assertSame(['/', '/pricing'], $pages, 'the pages of the visits that signed up');
        $this->assertSame(['Signup'], array_column($store->breakdown(self::today(['page', 'is', '/pricing']), 'event', 10, 0), 'value'));
    }

    #[DataProvider('kinds')]
    public function testGoalsCountEventsPagePatternsAndRevenueIncludingVisitsFromBeforeTheGoal(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 'a', 'v1', $t, ['source' => 'Google'], [['pageview', '/pricing', $t, 'a1'], ['event', 'Purchase', $t + 1, ['revenue' => 49]], ['pageview', '/thanks', $t + 2, 'a2']]);
        Seed::visit($store, 'b', 'v2', $t, [], [['pageview', '/pricing', $t, 'b1'], ['event', 'Purchase', $t + 1, ['revenue' => '19.50']], ['pageview', '/thanks/pro', $t + 2, 'b2']]);
        Seed::visit($store, 'c', 'v3', $t, [], [['pageview', '/', $t, 'c1'], ['event', 'Purchase', $t + 1, ['revenue' => 'not a number']]]);

        $purchase = Goals::goalFrom(['name' => 'Purchase', 'kind' => 'event', 'match' => 'Purchase', 'valueMode' => 'prop', 'valueProp' => 'revenue', 'currency' => 'usd'], 'default', [], self::NOW);
        $thanks = Goals::goalFrom(['name' => 'Thank you page', 'kind' => 'page', 'match' => 'https://example.com/thanks*', 'valueMode' => 'fixed', 'value' => 9.99], 'default', [$purchase], self::NOW);
        $button = Goals::goalFrom(['name' => 'Buy button', 'kind' => 'click', 'clickBy' => 'selector', 'match' => '.buy'], 'default', [$purchase, $thanks], self::NOW);
        foreach ([$purchase, $thanks, $button] as $g) {
            $store->saveGoal($g);
        }
        $this->assertSame(3, $store->visitors(self::today()));
        $all = $store->goalTotalsAll(self::today(), $store->goals('default'));
        $this->assertSame(['conversions' => 3, 'visitors' => 3, 'revenue' => 68.5], $all[$purchase['id']], 'numbers and numeric strings add up; anything else counts as nothing');
        $this->assertSame('USD', $purchase['currency']);
        $this->assertSame('/thanks*', $thanks['match'], 'a pasted URL keeps only its path');
        $this->assertSame(2, $all[$thanks['id']]['conversions']);
        $this->assertEqualsWithDelta(19.98, $all[$thanks['id']]['revenue'], 1e-9, 'a decimal fixed value works on every database, Postgres too');
        $this->assertSame(0, $all[$button['id']]['conversions']);
        $this->assertSame($all[$thanks['id']], $store->goalTotals(self::today(), $thanks));

        $pages = $store->goalBreakdown(self::today(), $purchase, 'path');
        $this->assertSame([['/pricing', 2], ['/', 1]], array_map(static fn (array $r): array => [$r['value'], $r['conversions']], $pages));
        $this->assertSame(68.5, $store->goalTotals(self::today(), $purchase)['revenue']);
        $series = $store->goalSeries(['site' => 'default', 'filters' => []], $purchase, [['start' => self::NOW - 12 * self::HOUR, 'end' => self::NOW], ['start' => self::NOW, 'end' => self::NOW + 12 * self::HOUR]]);
        $this->assertSame(3, array_sum(array_column($series, 'conversions')));
        $this->assertSame([['s', '.buy', 'Buy button']], Goals::clickRules($store->sites(), $store->goals())['default']);
    }

    #[DataProvider('kinds')]
    public function testRenamingAClickGoalRenamesItsPastClicks(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 'a', 'v1', $t, [], [['pageview', '/', $t, 'a1'], ['event', 'Buy', $t + 1, null]]);
        $before = self::goal(str_repeat('c', 24), ['name' => 'Buy', 'kind' => 'click', 'clickBy' => 'selector', 'match' => '.buy']);
        $store->saveGoal($before);
        $after = [...$before, 'name' => 'Buy now'];
        $store->saveGoal($after, $before);
        $this->assertSame(1, $store->goalTotals(self::today(), $after)['conversions']);
        $this->assertSame('Buy now', $store->goalById($before['id'])['name']);
        $store->deleteGoal($before['id']);
        $this->assertSame([], $store->goals('default'));
    }

    #[DataProvider('kinds')]
    public function testFunnelStepsInTheSameMillisecondBothCountAndOneRowNeverCountsAsTwoSteps(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::MIN;
        Seed::visit($store, 'a', 'v1', $t, [], [['pageview', '/pricing', $t, 'a1'], ['event', 'Signup', $t, null]]);
        $same = Funnels::funnelFrom(['name' => 'Same moment', 'steps' => [['kind' => 'page', 'match' => '/pricing'], ['kind' => 'event', 'match' => 'Signup']]], 'default', [], self::NOW);
        $twice = Funnels::funnelFrom(['name' => 'Twice', 'steps' => [['kind' => 'page', 'match' => '/pricing'], ['kind' => 'page', 'match' => '/pricing']]], 'default', [$same], self::NOW);
        $this->assertSame([1, 1], $store->funnelCounts(self::today(), $same));
        $this->assertSame([1, 0], $store->funnelCounts(self::today(), $twice), 'one pageview is not two steps');
    }

    #[DataProvider('kinds')]
    public function testAFunnelCountsVisitsThatTookEachStepInOrderWithinOneVisit(string $kind): void
    {
        $store = $this->store($kind);
        $n = 0;
        $visit = function (array $steps) use ($store, &$n): void {
            $n++;
            $t = self::NOW - 3 * self::HOUR + $n * 10 * self::MIN;
            $rows = [];
            foreach ($steps as $i => [$path, $event]) {
                $rows[] = $event === null ? ['pageview', $path, $t + $i * self::MIN, "p{$n}x$i"] : ['event', $event, $t + $i * self::MIN, null, $path];
            }
            Seed::visit($store, "s$n", "v$n", $t, [], $rows);
        };
        // All three steps in order; two steps, then gone; the right pages in the wrong order; never on pricing.
        $visit([['/pricing', null], ['/signup', 'Signup'], ['/welcome', null]]);
        $visit([['/pricing', null], ['/signup', 'Signup']]);
        $visit([['/welcome', null], ['/pricing', null]]);
        $visit([['/blog', null], ['/welcome', null]]);

        try {
            Funnels::funnelFrom(['name' => 'One step', 'steps' => [['kind' => 'page', 'match' => '/pricing']]], 'default', [], self::NOW);
            $this->fail('one step');
        } catch (\Runlight\FunnelError $error) {
            $this->assertSame('funnel_short', $error->code);
        }
        $funnel = Funnels::funnelFrom(['name' => 'Signup', 'steps' => [['kind' => 'page', 'match' => 'https://example.com/pricing*'], ['kind' => 'event', 'match' => 'Signup'], ['kind' => 'page', 'match' => 'welcome']]], 'default', [], self::NOW);
        $this->assertSame(['/pricing*', 'Signup', '/welcome'], array_column($funnel['steps'], 'match'), 'a pasted URL keeps its path; a bare path gains its slash');
        $store->saveFunnel($funnel);
        $this->assertSame([3, 2, 1], $store->funnelCounts(self::today(), $store->funnels('default')[0]));
        // Filters choose which visits enter. The Signup events were sent from /signup, so a page filter finds them.
        $this->assertSame([2, 2, 1], $store->funnelCounts(self::today(['page', 'is', '/signup']), $funnel));
        $changed = Funnels::funnelFrom(['name' => 'Signup flow', 'steps' => [['kind' => 'page', 'match' => '/pricing'], ['kind' => 'page', 'match' => '/welcome']]], 'default', [$funnel], self::NOW + 1, $funnel['id']);
        $this->assertSame($funnel['createdAt'], $changed['createdAt']);
        $store->saveFunnel($changed);
        $this->assertSame([3, 1], $store->funnelCounts(self::today(), $store->funnels('default')[0]));
        $store->deleteFunnel($funnel['id']);
        $this->assertSame([], $store->funnels('default'));
    }

    #[DataProvider('kinds')]
    public function testJourneyPagesReadsEachVisitsPagesInOrder(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        foreach ([['/', '/pricing', '/signup'], ['/', '/pricing', '/pricing', '/about'], ['/blog']] as $i => $pages) {
            $rows = [];
            foreach ($pages as $j => $page) {
                $rows[] = ['pageview', $page, $t + $i * self::MIN + $j * 10_000, "p{$i}x$j"];
            }
            Seed::visit($store, "s$i", "v$i", $t + $i * self::MIN, [], $rows);
        }
        $answer = $store->journeyPages(self::today(), 3);
        $this->assertFalse($answer['sampled']);
        $this->assertSame([
            ['session' => 's0', 'path' => '/'], ['session' => 's0', 'path' => '/pricing'], ['session' => 's0', 'path' => '/signup'],
            ['session' => 's1', 'path' => '/'], ['session' => 's1', 'path' => '/pricing'], ['session' => 's1', 'path' => '/about'],
            ['session' => 's2', 'path' => '/blog'],
        ], $answer['rows'], 'a refresh is not a step');
        $this->assertSame(['rows' => [], 'sampled' => false], $store->journeyPages(self::q(0, 1), 3));
    }

    #[DataProvider('kinds')]
    public function testAnEventsPropertiesAndTheirValuesFilteredLikeEverythingElse(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - self::HOUR;
        Seed::visit($store, 'a', 'v1', $t, [], [
            ['pageview', '/', $t, 'a1'],
            ['event', 'Outbound link', $t + 1, ['url' => 'https://github.com/x']],
            ['event', 'Outbound link', $t + 2, ['url' => 'https://news.ycombinator.com/']],
            ['event', 'Signup', $t + 3, ['plan' => 'pro', 'seats' => 3]],
            ['event', 'Signup', $t + 4, ['plan' => 'team']],
            ['event', '404', $t + 5, ['path' => '/missing']],
        ]);
        Seed::visit($store, 'b', 'v2', $t, [], [['pageview', '/blog', $t, 'b1'], ['event', 'Outbound link', $t + 1, ['url' => 'https://github.com/x'], '/blog']]);

        $this->assertSame([['key' => 'url', 'events' => 3]], $store->eventPropKeys(self::today(), 'Outbound link'));
        $this->assertSame([
            ['value' => 'https://github.com/x', 'events' => 2, 'visitors' => 2],
            ['value' => 'https://news.ycombinator.com/', 'events' => 1, 'visitors' => 1],
        ], $store->eventPropValues(self::today(), 'Outbound link', 'url', 10));
        $this->assertSame(['plan', 'seats'], array_column($store->eventPropKeys(self::today(), 'Signup'), 'key'));
        $this->assertSame([['value' => '3', 'events' => 1, 'visitors' => 1]], $store->eventPropValues(self::today(), 'Signup', 'seats', 10));
        $this->assertSame(['https://github.com/x'], array_column($store->eventPropValues(self::today(['page', 'is', '/blog']), 'Outbound link', 'url', 10), 'value'));
        $this->assertSame([], $store->eventPropKeys(self::today(), 'Nothing'));
    }

    #[DataProvider('kinds')]
    public function testTheLongestValuesTheTrackerAcceptsAreKeptWhole(string $kind): void
    {
        $store = $this->store($kind);
        $t = self::NOW - 3 * self::HOUR;
        $path = '/' . str_repeat('p', 999);
        $utm = static fn (string $c): string => str_repeat($c, 200);
        Seed::visit($store, 'a', 'v1', $t, [
            'referrerHost' => str_repeat('r', 60) . '.example.org', 'referrerPath' => '/' . str_repeat('q', 499),
            'utmSource' => $utm('s'), 'utmMedium' => $utm('m'), 'utmCampaign' => $utm('c'), 'utmTerm' => $utm('t'), 'utmContent' => $utm('o'),
        ], [['pageview', $path, $t, 'a1']]);
        $props = [];
        for ($i = 0; $i < 8; $i++) {
            $props[$i . str_repeat('k', 59)] = str_repeat('v', 500);
        }
        $store->insertEvent(['site' => 'default', 'ts' => $t + 1, 'kind' => 'pageview', 'visitor' => 'v1', 'session' => 'a', 'pageview' => 'a2', 'path' => '/x', 'hostname' => 'example.com', 'title' => str_repeat('t', 500), 'name' => '', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        Seed::visit($store, 'b', 'v2', $t, [], [['pageview', '/', $t, 'b1'], ['event', str_repeat('n', 120), $t + 1, $props]]);

        $this->assertContains($path, array_column($store->breakdown(self::today(), 'page', 10, 0), 'value'));
        foreach (['utm_source' => 's', 'utm_medium' => 'm', 'utm_campaign' => 'c', 'utm_term' => 't', 'utm_content' => 'o'] as $dimension => $c) {
            $this->assertSame([$utm($c)], array_column($store->breakdown(self::today(), $dimension, 10, 0), 'value'));
        }
        $this->assertSame(str_repeat('n', 120), $store->breakdown(self::today(), 'event', 10, 0)[0]['value']);
        $this->assertCount(8, $store->eventPropKeys(self::today(), str_repeat('n', 120)));
        $this->assertSame([str_repeat('v', 500)], array_column($store->eventPropValues(self::today(), str_repeat('n', 120), '0' . str_repeat('k', 59), 10), 'value'));
        // A day of them adds up the same way.
        Seed::buildDays($store, 'default', self::NOW - self::DAY, self::NOW + 12 * self::HOUR);
        $this->assertContains($path, array_column($store->breakdown(self::q(self::NOW - 7 * self::DAY, self::NOW + self::DAY), 'page', 10, 0), 'value'));
    }

    #[DataProvider('kinds')]
    public function testTextIsComparedExactlyAndSortedByCodePointCaseAndTrailingSpacesIncluded(string $kind): void
    {
        $store = $this->store($kind);
        $values = ['a', 'a ', 'A', 'b', 'é', 'É', "\u{1F600}", "\u{FFFD}", "a\t"];
        $t = self::NOW - self::HOUR;
        foreach ($values as $i => $value) {
            Seed::visit($store, "s$i", "v$i", $t, ['utmCampaign' => $value], [['pageview', '/', $t, "x$i"], ['event', 'Pick', $t + 1, ['choice' => $value]]]);
        }
        $sorted = $values;
        sort($sorted, SORT_STRING);
        $rows = $store->eventPropValues(self::today(), 'Pick', 'choice', 20);
        $this->assertSame($sorted, array_column($rows, 'value'));
        $this->assertSame(array_fill(0, count($values), 1), array_column($rows, 'events'), 'no two values counted as one');
        $this->assertSame($sorted, array_column($store->breakdown(self::today(), 'utm_campaign', 20, 0), 'value'));
        $this->assertSame(1, $store->stats(self::today(['utm_campaign', 'is', 'a ']))['visits'], 'a trailing space is part of the value');
    }

    #[DataProvider('kinds')]
    public function testShortLinkClicksAreNotVisitsInTheHeatmapRawOrRolledUpNorTheFirstVisit(string $kind): void
    {
        $store = $this->store($kind);
        $day = gmmktime(15, 0, 0, 10, 5, 2026) * 1000;
        // A session opened only by a short link click, then a real visit.
        $store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s1', 'default', 'v1', ?, ?, 0, 0, 0)", [$day - self::HOUR, $day - self::HOUR]);
        $store->db->run("INSERT INTO rl_sessions (id, site, visitor, started_at, last_at, pageviews, events, imported) VALUES ('s2', 'default', 'v2', ?, ?, 1, 0, 0)", [$day, $day]);
        $this->assertSame($day, $store->firstOwnVisit('default'));
        $this->assertSame($day - self::HOUR, $store->firstSeen('default'));
        $query = self::q(gmmktime(0, 0, 0, 10, 1, 2026) * 1000, gmmktime(0, 0, 0, 10, 7, 2026) * 1000);
        $sum = static fn (array $rows): int => array_sum(array_column($rows, 'visits'));
        $this->assertSame(1, $sum($store->hourly($query)), 'raw');
        Seed::buildDays($store, 'default', $query['from'], $query['to']);
        $this->assertSame(1, $sum($store->hourly($query)), 'rolled up');
    }
}
