<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Http\Request;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Store\SqlStore;
use Runlight\Store\Stores;
use Runlight\Tests\Store\Databases;
use Runlight\Tests\Store\WatchedDb;

/** The tracker endpoint's work, as ingest.test.ts, audit.test.ts, and hardening.test.ts test it, read back from the store. */
final class IngestTest extends CoreTestCase
{
    #[DataProvider('kinds')]
    public function testAVisitPageviewsAnEventEngagementAndTheReportsThatFollow(string $kind): void
    {
        $t = new Harness($kind);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/?utm_source=chatgpt.com', 'r' => 'https://chatgpt.com/', 'i' => 'pv1', 't' => 'Home', 'w' => 1440, 'h' => 900, 'l' => 'en-GB'], [
            'headers' => ['x-vercel-ip-country' => 'GB', 'x-vercel-ip-country-region' => 'ENG', 'x-vercel-ip-city' => 'London'],
        ]);
        $t->advance(20_000);
        $t->send(['k' => 'engagement', 'u' => 'https://example.com/', 'i' => 'pv1', 'e' => 18_000, 'd' => 75]);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/pricing', 'r' => 'https://example.com/', 'i' => 'pv2', 'w' => 1440, 'h' => 900]);
        $t->advance(5_000);
        $t->send(['k' => 'event', 'u' => 'https://example.com/pricing', 'i' => 'pv2', 'n' => 'Signup', 'p' => ['plan' => 'pro']]);

        // A second visitor on a phone who bounces.
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/blog/post', 'r' => 'https://news.ycombinator.com/', 'i' => 'pv3', 'w' => 390, 'h' => 844], ['ua' => Harness::SAFARI_IPHONE, 'ip' => '198.51.100.7']);
        $t->send(['k' => 'engagement', 'u' => 'https://example.com/blog/post', 'i' => 'pv3', 'e' => 4_000], ['ua' => Harness::SAFARI_IPHONE, 'ip' => '198.51.100.7']);

        $today = $t->today();
        self::assertSame(['visitors' => 2, 'visits' => 2, 'pageviews' => 3, 'viewsPerVisit' => 1.5, 'bounceRate' => 0.5, 'visitDuration' => 11_000], $t->stats($today));
        self::assertEquals([
            ['value' => 'AI', 'visitors' => 1, 'visits' => 1, 'pageviews' => 2, 'bounceRate' => 0, 'visitDuration' => 18_000],
            ['value' => 'Social', 'visitors' => 1, 'visits' => 1, 'pageviews' => 1, 'bounceRate' => 1, 'visitDuration' => 4_000],
        ], $t->store()->breakdown($today, 'channel', 10, 0));
        self::assertSame(['ChatGPT', 'Hacker News'], $t->values($today, 'source'));
        self::assertSame(['GB'], $t->values($today, 'country'));
        self::assertSame(['GB-ENG'], $t->values($today, 'region'));
        $devices = $t->values($today, 'device');
        sort($devices);
        self::assertSame(['desktop', 'mobile'], $devices);
        $screens = $t->values($today, 'screen');
        sort($screens);
        self::assertSame(['1440x900', '390x844'], $screens);
        self::assertEquals([['value' => 'Signup', 'visitors' => 1, 'events' => 1]], $t->store()->breakdown($today, 'event', 10, 0));
        $home = array_values(array_filter($t->store()->breakdown($today, 'page', 10, 0), static fn (array $p): bool => $p['value'] === '/'))[0];
        self::assertEquals(['value' => '/', 'visitors' => 1, 'pageviews' => 1, 'timeOnPage' => 18_000, 'scrollDepth' => 75], $home);
        $props = Json::decode((string) $t->store()->db->all("SELECT props FROM rl_events WHERE kind = 'event'")[0]['props'], true);
        self::assertSame(['plan' => 'pro'], $props);

        $live = $t->store()->realtime('default', $t->now);
        self::assertSame(2, $live['visitors']);
        self::assertCount(4, $live['recent'], 'three pageviews and an event');
    }

    #[DataProvider('kinds')]
    public function testThirtyIdleMinutesStartANewSessionAndANewDayIsANewVisitor(string $kind): void
    {
        $t = new Harness($kind);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'a1']);
        $t->advance(29 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/a', 'i' => 'a2']);
        $t->advance(31 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/b', 'i' => 'a3']);
        $stats = $t->stats($t->today());
        self::assertSame(2, $stats['visits']);
        self::assertSame(1, $stats['visitors']);

        $t->advance(24 * 60 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'a4']);
        self::assertSame(2, $t->stats($t->query('2026-10-01', '2026-10-07'))['visitors'], 'the same person on another day is counted again');
    }

    #[DataProvider('kinds')]
    public function testASessionThatRunsPastMidnightUtcStaysOneSession(string $kind): void
    {
        $t = new Harness($kind);
        $t->advance(11 * 60 * self::MIN + 50 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'm1']);
        $t->advance(20 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/next', 'i' => 'm2']);
        $stats = $t->stats($t->query('2026-10-01', '2026-10-07'));
        self::assertSame(1, $stats['visits']);
        self::assertSame(2, $stats['pageviews']);
    }

    #[DataProvider('kinds')]
    public function testASaltIsDeletedOnceItsDayHasEndedEverywhere(string $kind): void
    {
        $t = new Harness($kind);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 's1']);
        for ($i = 0; $i < 3; $i++) {
            $t->advance(24 * 60 * self::MIN);
            $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 's' . ($i + 2)]);
        }
        $t->rl->check();
        // October 9th at noon UTC: the earliest timezone is on the 8th and still needs the 7th.
        $days = array_map(static fn (array $r): string => (string) $r['day'], $t->store()->db->all('SELECT day FROM rl_salts ORDER BY day'));
        self::assertSame(['2026-10-07', '2026-10-08', '2026-10-09'], $days);
    }

    #[DataProvider('kinds')]
    public function testAVisitorIsOneVisitorForTheWholeOfTheSitesOwnDay(string $kind): void
    {
        // Toronto: 11pm on the 6th and 1am on the 7th UTC are both the evening of October 6th.
        $t = new Harness($kind, ['site' => ['timezone' => 'America/Toronto']]);
        $t->advance(11 * 60 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 't1']);
        $t->advance(2 * 60 * self::MIN);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/later', 'i' => 't2']);
        $stats = $t->stats($t->query('2026-10-06', '2026-10-06'));
        self::assertSame(2, $stats['visits'], 'two hours apart is two visits');
        self::assertSame(1, $stats['visitors'], 'but one visitor, since it is the same day in Toronto');
    }

    #[DataProvider('kinds')]
    public function testNothingIdentifyingIsStored(string $kind): void
    {
        $t = new Harness($kind);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/?email=jane@example.org&utm_campaign=x', 'i' => 'p1'], ['ip' => '192.0.2.55']);
        $dump = Json::encode([$t->store()->db->all('SELECT * FROM rl_sessions'), $t->store()->db->all('SELECT * FROM rl_events')]);
        self::assertStringNotContainsString('192.0.2.55', $dump, 'no IP');
        self::assertStringNotContainsString('jane@example.org', $dump, 'no query string');
        self::assertStringNotContainsString('AppleWebKit', $dump, 'no user agent');
    }

    #[DataProvider('kinds')]
    public function testBotsAiAgentsJunkAndOtherSitesAreDroppedQuietly(string $kind): void
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com']]]);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'b1'], ['ua' => 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)']);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'b2'], ['ua' => 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2)']);
        $t->send(['k' => 'pageview', 'u' => 'https://elsewhere.net/', 'i' => 'b3']);
        $t->send(['k' => 'pageview', 'u' => 'javascript:alert(1)']);
        $t->send(['k' => 'nonsense', 'u' => 'https://example.com/']);
        $t->send(['k' => 'event', 'u' => 'https://example.com/']);
        $t->rl->collect(new Request('https://example.com/runlight/e', 'POST', ['user-agent' => Harness::CHROME_MAC], '{not json'));
        // Too long, whatever the length header says.
        $t->rl->collect(new Request('https://example.com/runlight/e', 'POST', ['user-agent' => Harness::CHROME_MAC], Json::encode(['k' => 'pageview', 'u' => 'https://example.com/', 't' => str_repeat('x', 9000)])));
        $t->rl->collect(new Request('https://example.com/runlight/e', 'POST', ['user-agent' => Harness::CHROME_MAC, 'content-length' => '99999'], Json::encode(['k' => 'pageview', 'u' => 'https://example.com/'])));
        self::assertSame(0, $t->stats($t->today())['pageviews']);
    }

    #[DataProvider('kinds')]
    public function testAiAgentsAreRecordedAsFetchesByObserve(string $kind): void
    {
        $t = new Harness($kind);
        $fetch = fn (string $path, string $ua): bool => $t->rl->observe(new Request("https://example.com$path", 'GET', ['user-agent' => $ua, 'host' => 'example.com']));
        self::assertTrue($fetch('/blog/post', 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot'));
        self::assertTrue($fetch('/blog/post', 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)'));
        self::assertFalse($fetch('/logo.png', 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)'));
        self::assertFalse($fetch('/', Harness::CHROME_MAC));
        $today = $t->today();
        self::assertEquals([['value' => 'ChatGPT-User', 'visitors' => 0, 'fetches' => 1], ['value' => 'ClaudeBot', 'visitors' => 0, 'fetches' => 1]], $t->store()->breakdown($today, 'ai_agent', 10, 0));
        self::assertEquals([['value' => '/blog/post', 'visitors' => 0, 'fetches' => 2]], $t->store()->breakdown($today, 'ai_page', 10, 0));
        self::assertSame(0, $t->stats($today)['visitors'], 'fetches are not visits');
        // A log reader's time: older than a week is dropped, ahead of now counts as now.
        $ua = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)';
        self::assertFalse($t->rl->observe(new Request('https://example.com/old', 'GET', ['user-agent' => $ua]), $t->now - 8 * self::DAY));
        self::assertTrue($t->rl->observe(new Request('https://example.com/later', 'GET', ['user-agent' => $ua]), $t->now + self::DAY));
        self::assertSame($t->now, (int) $t->store()->db->all("SELECT ts FROM rl_events WHERE path = '/later'")[0]['ts']);
    }

    #[DataProvider('kinds')]
    public function testSeveralSitesInOneInstallToldApartByHostname(string $kind): void
    {
        $t = new Harness($kind, ['sites' => [['id' => 'brand-a', 'hostnames' => ['brand-a.com']], ['id' => 'brand-b', 'hostnames' => ['brand-b.com'], 'timezone' => 'America/Toronto']]]);
        $t->send(['k' => 'pageview', 'u' => 'https://www.brand-a.com/', 'i' => 'x1']);
        $t->send(['k' => 'pageview', 'u' => 'https://brand-b.com/', 'i' => 'x2']);
        $t->send(['k' => 'pageview', 'u' => 'https://brand-b.com/two', 'i' => 'x3']);
        self::assertSame(1, $t->stats($t->today('brand-a'))['pageviews']);
        self::assertSame(2, $t->stats($t->today('brand-b'))['pageviews']);
        self::assertCount(2, $t->rl->sites());
        self::assertNull($t->rl->site('brand-c'));
    }

    #[DataProvider('kinds')]
    public function testAVisitorsPageviewAndEventsMakeOneSession(string $kind): void
    {
        $t = new Harness($kind);
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'p1']);
        $t->send(['k' => 'event', 'u' => 'https://example.com/', 'n' => 'Signup', 'i' => 'p1']);
        $t->send(['k' => 'event', 'u' => 'https://example.com/', 'n' => 'Clicked']);
        $stats = $t->stats($t->today());
        self::assertSame(1, $stats['visits']);
        self::assertSame(1, $stats['visitors']);
    }

    #[DataProvider('kinds')]
    public function testAManagedInstallCountsTheFirstHitItGetsBeforeAnythingElseHasLoadedItsSites(string $kind): void
    {
        $store = Databases::fresh($kind);
        $first = new Runlight(['store' => $store, 'managedSites' => true]);
        $first->addSite(['hostnames' => 'blog.example.com']);
        $cold = new Runlight(['store' => $store, 'managedSites' => true, 'now' => fn (): int => Harness::START]);
        $cold->collect(Harness::hit('https://stats.example.com/runlight/e', ['k' => 'pageview', 'u' => 'https://blog.example.com/'], ['ip' => '203.0.113.4']));
        self::assertSame(1, (int) $store->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]['n']);
    }

    public function testARegionNameFromALocationDatabaseIsKeptReadableAndACodeStaysACode(): void
    {
        $names = [
            '203.0.113.1' => ['country' => 'ca', 'region' => 'Ontario', 'city' => 'Toronto'],
            '203.0.113.2' => ['country' => 'GB', 'region' => 'ENG', 'city' => 'London'],
        ];
        $t = new Harness('sqlite', ['geo' => static fn (string $ip): ?array => $names[$ip] ?? null]);
        foreach (array_keys($names) as $ip) {
            $t->rl->collect(Harness::hit('https://x.com/runlight/e', ['k' => 'pageview', 'u' => 'https://x.com/'], ['ua' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36', 'ip' => $ip]));
        }
        $regions = $t->values($t->today(), 'region');
        sort($regions);
        self::assertSame(['CA-Ontario', 'GB-ENG'], $regions);
    }

    public function testTrackerRequestsOverThePerAddressLimitAreDroppedUntilTheNextMinute(): void
    {
        $t = new Harness('sqlite', ['site' => ['hostnames' => ['example.com']], 'rateLimit' => 3]);
        $hit = fn (string $ip, int $n) => $t->rl->collect(Harness::hit('https://example.com/runlight/e', ['k' => 'pageview', 'u' => "https://example.com/$n"], ['ua' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36', 'ip' => $ip]));
        $ip = '203.0.113.7';
        for ($n = 0; $n < 5; $n++) {
            $hit($ip, $n);
        }
        $hit('198.51.100.7', 9);
        $views = fn (): int => (int) $t->store()->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]['n'];
        self::assertSame(4, $views(), 'three from the busy address, one from the other');
        $t->advance(60_000);
        $hit($ip, 7);
        self::assertSame(5, $views(), 'a new minute starts a new count');
    }

    public function testARunlightOnAClockGivenInCodeCountsTheRateLimitOnItsOwn(): void
    {
        // Two installs replaying the same minute from the same address must not share counts, as tests and the
        // conformance replays do; a shared count would drop the second one's hits.
        foreach ([1, 2] as $round) {
            $t = new Harness('sqlite', ['site' => ['hostnames' => ['example.com']], 'rateLimit' => 3]);
            for ($n = 0; $n < 3; $n++) {
                $t->rl->collect(Harness::hit('https://example.com/runlight/e', ['k' => 'pageview', 'u' => "https://example.com/$n"], ['ua' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36', 'ip' => '203.0.113.9']));
            }
            $views = (int) $t->store()->db->all("SELECT COUNT(*) AS n FROM rl_events WHERE kind = 'pageview'")[0]['n'];
            self::assertSame(3, $views, "install $round keeps all three");
        }
    }

    public function testTheRateLimitSharesItsCountsBetweenRequestsWhenOnTheRealClock(): void
    {
        $dir = sys_get_temp_dir() . '/runlight-rate-test-' . bin2hex(random_bytes(4));
        $now = static fn (): int => 1_000 * 60_000;
        $first = new \Runlight\RateLimit(2, $now, $dir);
        $second = new \Runlight\RateLimit(2, $now, $dir);
        self::assertTrue($first->allow('192.0.2.1'));
        self::assertTrue($second->allow('192.0.2.1'));
        if (!(function_exists('apcu_enabled') && apcu_enabled())) {
            self::assertFalse($first->allow('192.0.2.1'), 'the third hit in the minute is over the limit, wherever it lands');
        }
        array_map('unlink', glob("$dir/runlight-rate/*") ?: []);
        @rmdir("$dir/runlight-rate");
        @rmdir($dir);
    }

    public function testATrackerHitThatFindsTheDatabaseBusyIsTriedAgainAtTheTimeItArrived(): void
    {
        $watched = new WatchedDb(Databases::fresh('sqlite')->db);
        $t = new Harness(new SqlStore($watched), ['site' => ['hostnames' => ['example.com'], 'timezone' => 'UTC']]);
        $t->rl->init();
        $refused = 0;
        $watched->before = static function (string $sql) use (&$refused): void {
            if ($refused < 2 && str_contains($sql, 'FROM rl_sessions WHERE site = ? AND visitor IN')) {
                $refused++;
                throw new \RuntimeException('timeout exceeded when trying to connect');
            }
        };
        $arrived = $t->now;
        $t->send(['k' => 'pageview', 'u' => 'https://example.com/', 'i' => 'busy']);
        $watched->before = null;
        self::assertSame(2, $refused);
        self::assertSame(1, $t->stats($t->today())['pageviews']);
        self::assertSame($arrived, (int) $t->store()->db->all('SELECT ts FROM rl_events')[0]['ts']);
    }

    public function testALocalTestCountsWhileASiteIsBeingSetUpAndLocalTrafficIsIgnoredAfterItsFirstVisit(): void
    {
        $t = new Harness('sqlite', ['site' => ['hostnames' => ['example.com']]]);
        $hit = fn (string $url) => $t->rl->collect(Harness::hit('https://x.com/runlight/e', ['k' => 'pageview', 'u' => $url], ['ip' => '203.0.113.5']));
        $views = fn (): int => $t->stats($t->today())['pageviews'];
        $hit('http://localhost:3000/');
        self::assertSame(1, $views(), 'the first local test shows up');
        $hit('http://localhost:3000/again');
        $hit('http://myapp.test/');
        self::assertSame(1, $views(), 'after that, local hits are ignored');
        $hit('https://example.com/');
        self::assertSame(2, $views());
    }

    public function testTheClientAddressComesFromTheHeaderTrustedOrTheConnection(): void
    {
        $request = static fn (array $headers): Request => new Request('https://example.com/', 'GET', $headers, '', '192.0.2.9');
        $store = Stores::sqlite(':memory:');
        $default = new Runlight(['store' => $store]);
        self::assertSame('198.51.100.2', $default->clientIp($request(['x-forwarded-for' => '203.0.113.1, 198.51.100.2'])), 'the last entry, which the nearest proxy wrote');
        self::assertSame('203.0.113.3', $default->clientIp($request(['x-real-ip' => '203.0.113.3'])));
        self::assertSame('203.0.113.4', $default->clientIp($request(['cf-connecting-ip' => '203.0.113.4'])));
        self::assertSame('192.0.2.9', $default->clientIp($request([])), 'the connection, with no header');
        self::assertSame('192.0.2.1', $default->clientIp($request([]), ['ip' => '192.0.2.1']), 'the context names the connection');
        $off = new Runlight(['store' => $store, 'trustProxy' => false]);
        self::assertSame('192.0.2.9', $off->clientIp($request(['x-forwarded-for' => '203.0.113.1'])));
        $cf = new Runlight(['store' => $store, 'trustProxy' => 'cf-connecting-ip']);
        self::assertSame('203.0.113.4', $cf->clientIp($request(['x-forwarded-for' => '203.0.113.1', 'cf-connecting-ip' => '203.0.113.4'])));
        self::assertSame('192.0.2.9', $cf->clientIp($request(['x-forwarded-for' => '203.0.113.1'])));
    }

    public function testOptionsAreCheckedAsTsChecksThem(): void
    {
        $store = Stores::sqlite(':memory:');
        foreach ([
            [['site' => ['timezone' => 'Mars/Base']], 'unknown timezone'],
            [['site' => ['id' => 'has space']], 'must be letters'],
            [['sites' => [['id' => 'a', 'hostnames' => ['a.com']], ['id' => 'b']]], 'give each one its hostnames'],
            [['sites' => [['id' => 'a', 'hostnames' => ['a.com']], ['id' => 'a', 'hostnames' => ['b.com']]]], 'share an id'],
        ] as [$options, $error]) {
            try {
                new Runlight(['store' => $store, ...$options]);
                self::fail("accepted $error");
            } catch (\InvalidArgumentException $e) {
                self::assertStringContainsString($error, $e->getMessage());
            }
        }
        $rl = new Runlight(['store' => $store, 'site' => ['hostnames' => ['www.Example.com']], 'linkPath' => '//links/']);
        self::assertSame('/links', $rl->linkPath);
        self::assertSame([['id' => 'default', 'name' => 'www.Example.com', 'hostnames' => ['example.com'], 'timezone' => 'UTC']], $rl->sites());
        self::assertSame($rl->sites(), $rl->sites);
    }
}
