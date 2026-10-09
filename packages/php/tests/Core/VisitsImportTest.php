<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Http\Url;
use Runlight\Importers\CsvVisits;
use Runlight\Importers\ImportError;
use Runlight\Importers\Visits;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Store\SqlStore;
use Runlight\Tests\Store\Databases;
use Runlight\Tests\Store\WatchedDb;

/** Visit history from Umami and from CSV files, as visits-import*.test.ts and visits-csv.test.ts test it at the store. */
final class VisitsImportTest extends CoreTestCase
{
    private const CREDENTIALS = ['url' => 'https://umami.example.com', 'apiKey' => 'key'];

    /** A small Umami: one website, events answered by time window like the real API, newest first. */
    private static function umami(array $events, array $sessions = [], string $created = '2026-03-01T08:00:00Z', bool $newestFirst = true): Router
    {
        $inside = static function (Url $url) use ($events, $newestFirst): array {
            $q = $url->searchParams();
            $from = (int) $q->get('startAt');
            $to = (int) $q->get('endAt');
            $rows = array_values(array_filter($events, static fn (array $e): bool => self::at($e['createdAt']) >= $from && self::at($e['createdAt']) <= $to));
            return $newestFirst ? array_reverse($rows) : $rows;
        };
        return new Router([
            ['#/api/websites\?#', static fn () => ['data' => [['id' => 'w1', 'name' => 'Blog', 'domain' => 'blog.example.com']], 'count' => 1]],
            ['#/api/websites/w1$#', static fn () => ['id' => 'w1', 'createdAt' => $created]],
            ['#/api/websites/w1/events\?#', static function (Url $url) use ($inside): array {
                $rows = $inside($url);
                return ['data' => $rows, 'count' => count($rows)];
            }],
            ['#/api/websites/w1/sessions\?#', static fn () => ['data' => $sessions, 'count' => count($sessions)]],
        ]);
    }

    private static function fakeEvents(): array
    {
        return [
            // Visit 1: Google, two pages and a signup, in Toronto on a phone.
            ['sessionId' => 's1', 'createdAt' => '2026-03-01T10:00:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/', 'urlQuery' => 'utm_campaign=spring', 'referrerDomain' => 'www.google.com', 'referrerPath' => '/', 'pageTitle' => 'Home', 'eventType' => 1, 'country' => 'CA', 'city' => 'Toronto', 'device' => 'mobile', 'os' => 'iOS', 'browser' => 'ios'],
            ['sessionId' => 's1', 'createdAt' => '2026-03-01T10:02:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/pricing', 'pageTitle' => 'Pricing', 'eventType' => 1, 'country' => 'CA', 'city' => 'Toronto', 'device' => 'mobile', 'os' => 'iOS', 'browser' => 'ios'],
            ['sessionId' => 's1', 'createdAt' => '2026-03-01T10:03:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/pricing', 'eventType' => 2, 'eventName' => 'Signup', 'country' => 'CA', 'city' => 'Toronto', 'device' => 'mobile', 'os' => 'iOS', 'browser' => 'ios'],
            // The same Umami session two hours later is a second visit.
            ['sessionId' => 's1', 'createdAt' => '2026-03-01T12:30:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/blog', 'eventType' => 1, 'country' => 'CA', 'city' => 'Toronto', 'device' => 'mobile', 'os' => 'iOS', 'browser' => 'ios'],
            // Visit 3: direct, desktop, the next day.
            ['sessionId' => 's2', 'createdAt' => '2026-03-02T09:00:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/', 'eventType' => 1, 'country' => 'GB', 'city' => 'London', 'device' => 'desktop', 'os' => 'Mac OS', 'browser' => 'chrome'],
            // A performance event is not a visit.
            ['sessionId' => 's2', 'createdAt' => '2026-03-02T09:00:01.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/', 'eventType' => 5, 'country' => 'GB', 'city' => 'London', 'device' => 'desktop', 'os' => 'Mac OS', 'browser' => 'chrome'],
        ];
    }

    private const SESSIONS = [
        ['id' => 's1', 'screen' => '390x844', 'language' => 'en-CA', 'region' => 'CA-ON'],
        ['id' => 's2', 'screen' => '1440x900', 'language' => 'en-GB', 'region' => 'GB-ENG'],
    ];

    private static function harness(string|SqlStore $kind, Router $router, int $now, string $timezone = 'UTC'): Harness
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['blog.example.com'], 'timezone' => $timezone], 'fetcher' => $router]);
        $t->now = $now;
        return $t;
    }

    /** @return array{pageviews: int, events: int, visits: int, steps: int} */
    private static function importAll(Harness $t, array $credentials = self::CREDENTIALS): array
    {
        $cursor = null;
        $totals = ['pageviews' => 0, 'events' => 0, 'visits' => 0, 'steps' => 0];
        do {
            $step = Visits::importUmamiVisits($t->rl, 'default', $credentials, 'w1', $cursor);
            $cursor = $step['cursor'];
            foreach (['pageviews', 'events', 'visits'] as $k) {
                $totals[$k] += $step[$k];
            }
            $totals['steps']++;
            self::assertLessThanOrEqual($step['total'], $step['done']);
        } while ($cursor !== null);
        return $totals;
    }

    #[DataProvider('kinds')]
    public function testUmamiVisitHistoryPageviewsAndEventsBecomeVisitsWithSourcesPlacesAndDevices(string $kind): void
    {
        $router = self::umami(self::fakeEvents(), self::SESSIONS);
        self::assertSame([['id' => 'w1', 'name' => 'Blog', 'domain' => 'blog.example.com']], Visits::umamiWebsites(self::CREDENTIALS, $router));
        $t = self::harness($kind, $router, self::at('2026-03-04T00:00:00Z'));
        $totals = self::importAll($t);
        self::assertSame(['pageviews' => 4, 'events' => 1, 'visits' => 3], array_slice($totals, 0, 3));
        foreach ($router->requests as $r) {
            self::assertSame('Bearer key', Router::authorization($r['init']), 'every request carries the key');
        }

        $q = $t->query('2026-03-01', '2026-03-03');
        $stats = $t->stats($q);
        self::assertSame(4, $stats['pageviews']);
        self::assertSame(3, $stats['visits']);
        self::assertSame(2, $stats['visitors'], 'one Umami session on one day is one visitor');
        self::assertGreaterThan(0, $stats['visitDuration'], 'imported visits take their length from first to last pageview');
        self::assertSame(['Google'], $t->values($q, 'source'));
        $regions = $t->values($q, 'region');
        sort($regions);
        self::assertSame(['CA-ON', 'GB-ENG'], $regions);
        $browsers = $t->values($q, 'browser');
        sort($browsers);
        self::assertSame(['Chrome', 'Safari'], $browsers);
        self::assertSame(['Signup'], $t->values($q, 'event'));
        self::assertSame(['spring'], $t->values($q, 'utm_campaign'));

        // Running it again carries on from where it stopped, so nothing doubles.
        $t->advance(self::DAY);
        $again = Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w1', null);
        self::assertSame(0, $again['pageviews']);
        self::assertSame(4, $t->stats($q)['pageviews']);

        // No imported visitor id lasts past a day.
        $days = [];
        foreach ($t->store()->db->all('SELECT visitor, ts FROM rl_events') as $r) {
            $days[$r['visitor']][gmdate('Y-m-d', intdiv((int) $r['ts'], 1000))] = true;
        }
        foreach ($days as $set) {
            self::assertCount(1, $set);
        }
    }

    public function testUmamiVisitHistoryStopsWhereRunlightsOwnVisitsBegin(): void
    {
        $t = self::harness('sqlite', self::umami(self::fakeEvents(), self::SESSIONS), self::at('2026-03-01T23:00:00Z'));
        // Runlight started counting on the evening of March 1st.
        $t->rl->collect(Harness::hit('https://x.com/runlight/e', ['k' => 'pageview', 'u' => 'https://blog.example.com/'], ['ip' => '203.0.113.9']));
        self::assertSame(3, self::importAll($t)['pageviews'], "March 2nd is left to Runlight");
    }

    public function testAStepThatFailedPartWayCanRunAgainWithoutCountingAnythingTwice(): void
    {
        $watched = new WatchedDb(Databases::fresh('sqlite')->db);
        $t = self::harness(new SqlStore($watched), self::umami(self::fakeEvents(), self::SESSIONS), self::at('2026-03-04T00:00:00Z'));
        $t->rl->init();
        $writes = 0;
        $watched->before = static function (string $sql) use (&$writes): void {
            if (str_starts_with($sql, 'INSERT INTO rl_events') && ++$writes > 2) {
                throw new \RuntimeException('connection lost');
            }
        };
        try {
            Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w1', null);
            self::fail('the first try fails');
        } catch (\RuntimeException $e) {
            self::assertSame('connection lost', $e->getMessage());
        }
        $watched->before = null;
        self::importAll($t);
        $stats = $t->stats($t->query('2026-03-01', '2026-03-03'));
        self::assertSame(4, $stats['pageviews']);
        self::assertSame(3, $stats['visits']);
        $totals = $t->store()->db->all('SELECT SUM(pageviews) AS pageviews, SUM(events) AS events FROM rl_sessions')[0];
        self::assertSame(['pageviews' => 4, 'events' => 1], ['pageviews' => (int) $totals['pageviews'], 'events' => (int) $totals['events']]);
    }

    public function testUmamiVisitHistorySkipsDaysOlderThanTheSiteKeeps(): void
    {
        $t = self::harness('sqlite', self::umami(self::fakeEvents(), self::SESSIONS), self::at('2026-09-01T12:00:00Z'));
        $t->rl->init();
        // Six months back from September 1st at noon is March 1st at noon, so March 1st is left out.
        $t->rl->setRetention('default', 6);
        self::assertSame(1, self::importAll($t)['pageviews'], 'only March 2nd comes in');
    }

    public function testAnImportedVisitAcrossUtcMidnightIsOneVisitOnTheSitesOwnDay(): void
    {
        $events = [
            ['sessionId' => 'n1', 'createdAt' => '2026-03-02T23:55:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/', 'eventType' => 1, 'country' => 'CA', 'device' => 'desktop', 'os' => 'Mac OS', 'browser' => 'chrome'],
            ['sessionId' => 'n1', 'createdAt' => '2026-03-03T00:05:00.000Z', 'hostname' => 'blog.example.com', 'urlPath' => '/about', 'eventType' => 1, 'country' => 'CA', 'device' => 'desktop', 'os' => 'Mac OS', 'browser' => 'chrome'],
        ];
        $t = self::harness('sqlite', self::umami($events, [['id' => 'n1']], '2026-03-02T00:00:00Z', false), self::at('2026-03-10T00:00:00Z'), 'America/Toronto');
        self::importAll($t);
        $stats = $t->stats($t->query('2026-03-02', '2026-03-02'));
        self::assertSame([1, 1, 2], [$stats['visits'], $stats['visitors'], $stats['pageviews']]);
    }

    private static function ev(string $session, string $iso, string $path, ?string $name = null): array
    {
        return ['sessionId' => $session, 'createdAt' => gmdate('Y-m-d\TH:i:s.000\Z', intdiv(self::at($iso), 1000)), 'hostname' => 'blog.example.com', 'urlPath' => $path, 'eventType' => $name !== null ? 2 : 1, ...($name !== null ? ['eventName' => $name] : [])];
    }

    #[DataProvider('kinds')]
    public function testAnImportedVisitThatRunsPastMidnightKeepsOneVisitorOnAllItsRows(string $kind): void
    {
        $events = [self::ev('s1', '2026-03-01T23:50:00Z', '/a'), self::ev('s1', '2026-03-02T00:05:00Z', '/b'), self::ev('s1', '2026-03-02T00:06:00Z', '/b', 'Signup'), self::ev('s1', '2026-03-02T10:00:00Z', '/b'), self::ev('s1', '2026-03-02T10:01:00Z', '/b', 'Signup')];
        $t = self::harness($kind, self::umami($events, [], '2026-03-01T00:00:00.000Z'), self::at('2026-03-05T12:00:00Z'));
        self::importAll($t);
        self::assertSame([], $t->store()->db->all('SELECT e.id FROM rl_events e JOIN rl_sessions s ON s.id = e.session WHERE e.visitor <> s.visitor'));
        $q = $t->query('2026-03-01', '2026-03-02');
        $read = fn (): array => [
            'pages' => array_map(static fn (array $r): array => [$r['value'], $r['visitors']], $t->store()->breakdown($q, 'page', 10, 0)),
            'events' => array_map(static fn (array $r): array => [$r['value'], $r['visitors']], $t->store()->breakdown($q, 'event', 10, 0)),
        ];
        $raw = $read();
        while ($t->rl->buildRollups() > 0) {
        }
        self::assertEquals($raw, $read(), 'the same before and after the days are built');
        self::assertEquals([['Signup', 2]], $raw['events']);
    }

    #[DataProvider('kinds')]
    public function testAVisitThatCrossesIntoTheNextImportStepHasItsFirstDayBuiltAgain(string $kind): void
    {
        $events = [self::ev('s0', '2026-03-02T10:00:00Z', '/'), self::ev('s1', '2026-03-14T23:50:00Z', '/a'), self::ev('s1', '2026-03-15T00:10:00Z', '/b'), self::ev('s2', '2026-03-20T10:00:00Z', '/')];
        $t = self::harness($kind, self::umami($events, [], '2026-03-01T00:00:00.000Z'), self::at('2026-03-25T12:00:00Z'));
        $cursor = Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w1', null)['cursor'];
        // The scheduled check builds days between two steps.
        while ($t->rl->buildRollups() > 0) {
        }
        while ($cursor !== null) {
            $cursor = Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w1', $cursor)['cursor'];
        }
        while ($t->rl->buildRollups() > 0) {
        }
        $q = $t->query('2026-03-14', '2026-03-14');
        $read = fn (): array => ['stats' => $t->stats($q), 'pages' => array_map(static fn (array $r): array => [$r['value'], $r['pageviews']], $t->store()->breakdown($q, 'page', 10, 0))];
        $rolled = $read();
        $t->store()->clearRollups('default');
        self::assertEquals($read(), $rolled);
        self::assertSame(2, $rolled['stats']['pageviews']);
    }

    public function testAStepCursorCarriesASignInTokenButNeverAnApiKey(): void
    {
        $events = [self::ev('s0', '2026-03-02T10:00:00Z', '/'), self::ev('s2', '2026-03-20T10:00:00Z', '/')];
        $router = self::umami($events, [], '2026-03-01T00:00:00.000Z');
        $t = self::harness('sqlite', $router, self::at('2026-03-25T12:00:00Z'));
        $cursor = Json::decode((string) Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w1', null)['cursor'], true);
        self::assertSame(['website', 'day', 'start', 'end'], array_keys($cursor));
        self::assertSame(self::at('2026-03-15T00:00:00Z'), $cursor['day'], 'fourteen days a step');
        try {
            Visits::importUmamiVisits($t->rl, 'default', self::CREDENTIALS, 'w/1', null);
            self::fail('a bad website id');
        } catch (ImportError $e) {
            self::assertSame('import_website', $e->code);
        }
    }

    // ---------------------------------------------------------------- CSV

    private const RUNLIGHT_ROWS = [
        ['time' => '2026-03-01T10:00:00Z', 'url' => 'https://blog.example.com/?utm_campaign=spring', 'referrer' => 'www.google.com', 'visitor' => 'a', 'country' => 'CA', 'region' => 'CA-ON', 'city' => 'Toronto', 'browser' => 'Safari', 'os' => 'iOS', 'device' => 'mobile', 'title' => 'Home'],
        ['time' => '2026-03-01T10:02:00Z', 'url' => 'https://blog.example.com/pricing', 'visitor' => 'a', 'country' => 'CA', 'browser' => 'Safari', 'os' => 'iOS', 'device' => 'mobile'],
        ['time' => '2026-03-01T10:03:00Z', 'url' => 'https://blog.example.com/pricing', 'event' => 'Signup', 'visitor' => 'a'],
        ['time' => '1772442000', 'path' => '/', 'hostname' => 'blog.example.com', 'visitor' => 'b', 'country' => 'GB', 'browser' => 'Chrome', 'os' => 'macOS', 'device' => 'desktop'],
        // Not a time at all.
        ['time' => 'yesterday', 'path' => '/x', 'visitor' => 'c'],
    ];

    private static function csv(int $now = 0): Harness
    {
        $t = new Harness('sqlite', ['site' => ['hostnames' => ['blog.example.com'], 'timezone' => 'UTC']]);
        $t->now = $now ?: self::at('2026-03-04T00:00:00Z');
        return $t;
    }

    public function testCsvInRunlightsFormatRowsBecomeVisitsWithSourcesPlacesDevicesAndEvents(): void
    {
        $t = self::csv();
        self::assertSame(['pageviews' => 3, 'events' => 1, 'visits' => 2, 'skipped' => 1], Visits::importCsvVisits($t->rl, 'default', self::RUNLIGHT_ROWS));
        $q = $t->query('2026-03-01', '2026-03-03');
        $stats = $t->stats($q);
        self::assertSame([3, 2, 2], [$stats['pageviews'], $stats['visits'], $stats['visitors']]);
        self::assertSame(['Google'], $t->values($q, 'source'));
        self::assertSame(['spring'], $t->values($q, 'utm_campaign'));
        self::assertSame(['Signup'], $t->values($q, 'event'));
        $devices = $t->values($q, 'device');
        sort($devices);
        self::assertSame(['desktop', 'mobile'], $devices);
        self::assertSame(['CA-ON'], $t->values($q, 'region'));

        // The same file again replaces what it brought in, so nothing doubles.
        Visits::importCsvVisits($t->rl, 'default', self::RUNLIGHT_ROWS);
        self::assertSame(3, $t->stats($q)['pageviews']);
        self::assertSame(2, $t->stats($q)['visits']);
    }

    public function testCsvInRunlightsFormatWithoutAVisitorColumnEveryRowIsItsOwnVisit(): void
    {
        $t = self::csv();
        $rows = [['time' => '2026-03-01 10:00:00', 'path' => '/a'], ['time' => '2026-03-01 10:01:00', 'path' => '/b?ref=x']];
        self::assertSame(2, Visits::importCsvVisits($t->rl, 'default', $rows)['visits']);
        Visits::importCsvVisits($t->rl, 'default', $rows);
        $q = $t->query('2026-03-01', '2026-03-03');
        self::assertSame(2, $t->stats($q)['visits'], 'the same rows get the same ids the second time');
        $pages = $t->values($q, 'page');
        sort($pages);
        self::assertSame(['/a', '/b'], $pages);
    }

    public function testCsvFromUmamisExportPageviewsAndNamedEventsComeAcrossOtherEventTypesDoNot(): void
    {
        $t = self::csv();
        $rows = [
            ['website_id' => 'w1', 'session_id' => 's1', 'created_at' => '2026-03-01 10:00:00', 'hostname' => 'blog.example.com', 'url_path' => '/', 'url_query' => '', 'referrer_domain' => 'news.ycombinator.com', 'page_title' => 'Home', 'event_type' => '1', 'country' => 'CA', 'subdivision1' => 'ON', 'city' => 'Toronto', 'browser' => 'ios', 'os' => 'iOS', 'device' => 'mobile', 'screen' => '390x844', 'language' => 'en-CA'],
            ['website_id' => 'w1', 'session_id' => 's1', 'created_at' => '2026-03-01 10:03:00', 'hostname' => 'blog.example.com', 'url_path' => '/pricing', 'event_type' => '2', 'event_name' => 'Signup'],
            ['website_id' => 'w1', 'session_id' => 's1', 'created_at' => '2026-03-01 10:03:01', 'hostname' => 'blog.example.com', 'url_path' => '/pricing', 'event_type' => '5'],
            ['website_id' => 'w1', 'session_id' => 's2', 'created_at' => '2026-03-02T09:00:00.000Z', 'hostname' => 'blog.example.com', 'url_path' => '/blog', 'event_type' => '1', 'country' => 'GB', 'browser' => 'chrome', 'os' => 'Mac OS', 'device' => 'desktop'],
        ];
        self::assertSame(['pageviews' => 2, 'events' => 1, 'visits' => 2, 'skipped' => 1], Visits::importCsvVisits($t->rl, 'default', $rows));
        $q = $t->query('2026-03-01', '2026-03-03');
        self::assertSame(['Hacker News'], $t->values($q, 'source'));
        self::assertSame(['CA-ON'], $t->values($q, 'region'));
        $browsers = $t->values($q, 'browser');
        sort($browsers);
        self::assertSame(['Chrome', 'Safari'], $browsers);
    }

    public function testCsvRowsFromAfterRunlightsOwnFirstVisitAreLeftToRunlight(): void
    {
        $t = self::csv(self::at('2026-03-01T23:00:00Z'));
        $t->rl->collect(Harness::hit('https://x.com/runlight/e', ['k' => 'pageview', 'u' => 'https://blog.example.com/'], ['ip' => '203.0.113.9']));
        $step = Visits::importCsvVisits($t->rl, 'default', array_slice(self::RUNLIGHT_ROWS, 0, 4));
        self::assertSame(2, $step['pageviews'], 'March 2nd is left to Runlight');
        self::assertSame(1, $step['skipped']);
    }

    public function testACsvItCannotReadAndABatchThatIsTooBigAreRefused(): void
    {
        $t = self::csv();
        foreach ([[[['date' => '2026-03-01', 'visitors' => '12']], 'import_csv_format'], [array_fill(0, 2001, self::RUNLIGHT_ROWS[0]), 'import_csv_batch'], ['not rows', 'import_csv_batch']] as [$rows, $code]) {
            try {
                Visits::importCsvVisits($t->rl, 'default', $rows);
                self::fail($code);
            } catch (ImportError $e) {
                self::assertSame($code, $e->code);
            }
        }
        self::assertSame(2, Visits::importCsvVisits($t->rl, 'default', self::RUNLIGHT_ROWS)['visits']);
    }

    public function testCsvTimesAndFormats(): void
    {
        self::assertSame('umami', CsvVisits::csvFormat(['created_at', 'url_path', 'session_id']));
        self::assertSame('runlight', CsvVisits::csvFormat(['time', 'url']));
        self::assertNull(CsvVisits::csvFormat(['date', 'visitors']));
        $iso = self::at('2026-03-01T10:00:00Z');
        self::assertSame($iso, CsvVisits::rowTime(['time' => '2026-03-01 10:00:00'], 'runlight'), 'no zone reads as UTC');
        self::assertSame($iso, CsvVisits::rowTime(['time' => '2026-03-01T12:00:00+02:00'], 'runlight'));
        self::assertSame($iso, CsvVisits::rowTime(['time' => (string) intdiv($iso, 1000)], 'runlight'), 'Unix seconds');
        self::assertSame($iso, CsvVisits::rowTime(['time' => (string) $iso], 'runlight'), 'Unix milliseconds');
        self::assertSame($iso, CsvVisits::rowTime(['created_at' => '2026-03-01 10:00:00'], 'umami'));
        self::assertNan(CsvVisits::rowTime(['time' => ''], 'runlight'));
        self::assertNan(CsvVisits::rowTime(['time' => 'yesterday'], 'runlight'));
    }
}
