<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\TestCase;
use Runlight\Importers\ImportError;
use Runlight\Importers\Index;
use Runlight\Importers\Write;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Store\Stores;

/** Link imports written into the store, as importers.test.ts tests them. */
final class ImportStepTest extends TestCase
{
    private const NOW = 1_791_288_000_000;

    private static function runlight(Router $router): Runlight
    {
        return new Runlight(['store' => Stores::sqlite(':memory:'), 'fetcher' => $router, 'now' => static fn (): int => self::NOW]);
    }

    /** @return array{Runlight, array{links: int, clicks: int, skipped: int, failed: list<array>}, int|float} */
    private static function runAll(Router $router, string $source, array $credentials): array
    {
        $rl = self::runlight($router);
        $cursor = null;
        $done = 0;
        $totals = ['links' => 0, 'clicks' => 0, 'skipped' => 0, 'failed' => []];
        do {
            $step = Index::importStep($rl, 'default', $source, $credentials, $cursor, $done);
            $cursor = $step['cursor'];
            $done = $step['done'];
            $totals['links'] += $step['links'];
            $totals['clicks'] += $step['clicks'];
            $totals['skipped'] += $step['skipped'];
            array_push($totals['failed'], ...$step['failed']);
        } while ($cursor !== null);
        return [$rl, $totals, $done];
    }

    private static function links(Runlight $rl): array
    {
        return $rl->store->links('default', 0, self::NOW + 1);
    }

    public function testDubEveryClickWhereThePlanAllows(): void
    {
        $router = new Router([
            ['#api\.dub\.co/links\?.*startingAfter=l2#', static fn () => []],
            ['#api\.dub\.co/links\?#', static fn () => [
                ['id' => 'l1', 'domain' => 'dub.sh', 'key' => 'launch', 'url' => 'https://a.com/launch', 'title' => 'Launch', 'createdAt' => '2026-01-02T00:00:00Z'],
                ['id' => 'l2', 'domain' => 'go.brand.com', 'key' => 'sale', 'url' => 'https://a.com/sale', 'title' => null, 'createdAt' => '2026-02-03T00:00:00Z'],
            ]],
            ['#/events\?.*linkId=l1#', static fn () => [
                ['timestamp' => '2026-03-01T10:00:00Z', 'click' => ['id' => 'c1', 'country' => 'CA', 'city' => 'Toronto', 'device' => 'Mobile', 'browser' => 'Chrome', 'os' => 'iOS', 'referer' => 'instagram.com', 'refererUrl' => 'https://instagram.com/']],
                ['timestamp' => '2026-03-02T10:00:00Z', 'click' => ['id' => 'c2', 'country' => 'US', 'device' => 'Desktop', 'browser' => 'Safari', 'os' => 'Mac OS', 'referer' => '(direct)']],
            ]],
            ['#/events\?.*linkId=l2#', static fn () => []],
        ]);
        [$rl, $totals] = self::runAll($router, 'dub', ['apiKey' => 'dub_test']);
        self::assertSame(2, $totals['links']);
        self::assertSame(2, $totals['clicks']);
        $bySlug = array_column(self::links($rl), null, 'slug');
        self::assertSame('', $bySlug['launch']['domain'], 'dub.sh stays behind; the link moves to /go');
        self::assertSame('go.brand.com', $bySlug['sale']['domain'], 'branded domains come across');
        self::assertSame(['domain' => 'go.brand.com', 'site' => 'default'], $rl->store->linkDomains()[0]);
        $session = $rl->store->db->all('SELECT country, source, device FROM rl_sessions ORDER BY started_at LIMIT 1')[0];
        self::assertSame(['country' => 'CA', 'source' => 'Instagram', 'device' => 'mobile'], $session);
        self::assertSame(1, (int) $rl->store->db->all('SELECT imported FROM rl_sessions LIMIT 1')[0]['imported']);
    }

    public function testDubDailyCountsWhenThePlanHasNoEventsApi(): void
    {
        $router = new Router([
            ['#api\.dub\.co/links\?#', static fn () => [['id' => 'l1', 'domain' => 'dub.sh', 'key' => 'x', 'url' => 'https://a.com', 'title' => 'X', 'createdAt' => '2026-01-02T00:00:00Z']]],
            ['#/events\?#', static fn () => [403, ['error' => ['message' => 'Business plan required']]]],
            ['#/analytics\?#', static fn () => [['start' => '2026-03-01T00:00:00.000Z', 'clicks' => 3], ['start' => '2026-03-02T00:00:00.000Z', 'clicks' => 0]]],
        ]);
        [$rl, $totals] = self::runAll($router, 'dub', ['apiKey' => 'dub_test']);
        self::assertSame(3, $totals['clicks']);
        $row = self::links($rl)[0];
        self::assertSame(3, $row['clicks']);
        self::assertSame(0, $row['visitors'], 'daily counts add clicks, not made-up visitors');
        $times = array_map(static fn (array $r): int => (int) $r['ts'], $rl->store->db->all('SELECT ts FROM rl_events ORDER BY ts'));
        $day = gmmktime(0, 0, 0, 3, 1, 2026) * 1000;
        self::assertSame([$day + 14_400_000, $day + 43_200_000, $day + 72_000_000], $times, 'spread through the day');
    }

    public function testBitlyEveryGroupCustomBackHalvesDailyCounts(): void
    {
        $router = new Router([
            ['#/v4/groups$#', static fn () => ['groups' => [['guid' => 'G1'], ['guid' => 'G2']]]],
            ['#/groups/G1/bitlinks#', static fn () => ['links' => [
                ['id' => 'bit.ly/3abc', 'link' => 'https://bit.ly/3abc', 'long_url' => 'https://a.com/1', 'title' => 'One', 'created_at' => '2026-01-01T00:00:00+0000', 'custom_bitlinks' => ['https://t.brand.com/one']],
                ['id' => 'bit.ly/gone', 'link' => 'https://bit.ly/gone', 'long_url' => 'https://a.com/x', 'title' => 'Gone', 'created_at' => '2026-01-01T00:00:00+0000', 'is_deleted' => true],
            ], 'pagination' => ['search_after' => '']]],
            ['#/groups/G2/bitlinks#', static fn () => ['links' => [['id' => 'bit.ly/4def', 'link' => 'https://bit.ly/4def', 'long_url' => 'https://a.com/2', 'title' => null, 'created_at' => '2026-02-01T00:00:00+0000']], 'pagination' => Json::object()]],
            ['#/bitlinks/bit\.ly%2F3abc/clicks#', static fn () => ['link_clicks' => [['clicks' => 5, 'date' => '2026-03-01T00:00:00+0000'], ['clicks' => 2, 'date' => '2026-03-02T00:00:00+0000']]]],
            ['#/bitlinks/bit\.ly%2F4def/clicks#', static fn () => [402, ['message' => 'UPGRADE_REQUIRED']]],
        ]);
        [$rl, $totals] = self::runAll($router, 'bitly', ['token' => 'bitly_test']);
        self::assertSame(2, $totals['links'], 'the deleted link is skipped');
        self::assertSame(7, $totals['clicks']);
        $pairs = array_map(static fn (array $l): array => [$l['domain'], $l['slug']], self::links($rl));
        sort($pairs);
        self::assertSame([['', '4def'], ['t.brand.com', 'one']], $pairs);
    }

    public function testShortIoEveryDomainPagedWithDailyCountsInEitherShape(): void
    {
        $router = new Router([
            ['#api\.short\.io/api/domains#', static fn () => [['id' => 7, 'hostname' => 's.brand.com']]],
            ['#api/links\?.*pageToken=P2#', static fn () => ['links' => [['idString' => 'lnk2', 'id' => 2, 'path' => 'two', 'originalURL' => 'https://a.com/2', 'createdAt' => '2026-02-01T00:00:00Z']], 'nextPageToken' => null]],
            ['#api/links\?domain_id=7#', static fn () => ['links' => [['idString' => 'lnk1', 'id' => 1, 'path' => 'one', 'originalURL' => 'https://a.com/1', 'title' => 'One', 'createdAt' => '2026-01-01T00:00:00Z']], 'nextPageToken' => 'P2']],
            ['#statistics/link/lnk1/by_interval#', static fn () => ['clickStatistics' => [['x' => '2026-03-01T00:00:00Z', 'y' => 4]]]],
            ['#statistics/link/lnk2/by_interval#', static fn () => ['clickStatistics' => ['datasets' => [['data' => [['x' => gmmktime(0, 0, 0, 3, 2, 2026) * 1000, 'y' => 1]]]]]]],
        ]);
        [, $totals] = self::runAll($router, 'shortio', ['apiKey' => 'sk_test']);
        self::assertSame(2, $totals['links']);
        self::assertSame(5, $totals['clicks']);
    }

    public function testRebrandlyLinksOnlyPagedByTheLastId(): void
    {
        $page = static fn (int $from, int $n): array => array_map(static fn (int $i): array => ['id' => "r$i", 'slashtag' => "s$i", 'destination' => "https://a.com/$i", 'domain' => ['fullName' => 'rebrand.ly'], 'createdAt' => '2026-01-01T00:00:00Z'], range($from, $from + $n - 1));
        $router = new Router([
            ['#/links\?.*last=r24#', static fn () => $page(25, 3)],
            ['#rebrandly\.com/v1/links\?#', static fn () => $page(0, 25)],
        ]);
        [$rl, $totals] = self::runAll($router, 'rebrandly', ['apiKey' => 'rb_test']);
        self::assertSame(28, $totals['links']);
        self::assertSame(0, $totals['clicks']);
        self::assertSame('', self::links($rl)[0]['domain'], 'rebrand.ly stays behind');
    }

    public function testUmamiSignsInWithAUsernameAndPasswordAndReRunsSkipWhatIsThere(): void
    {
        $router = new Router([
            ['#/api/auth/login#', static fn ($u, array $init) => Json::decode($init['body'], true)['password'] === 'pw' ? ['token' => 'tok'] : Json::object()],
            ['#/api/links\?#', static fn () => ['data' => [['id' => 'u-1', 'name' => 'Golden', 'url' => 'https://a.com', 'slug' => 'golden', 'createdAt' => '2026-01-01T00:00:00Z', 'deletedAt' => null, 'customDomain' => ['domain' => 't.brand.com']]], 'count' => 1]],
            ['#/websites/u-1/events#', static fn () => ['data' => [['sessionId' => 's1', 'createdAt' => '2026-03-01T00:00:00Z', 'urlPath' => '/golden', 'urlQuery' => 'utm_source=newsletter', 'referrerDomain' => '', 'referrerPath' => '', 'country' => 'GB', 'city' => 'London', 'device' => 'mobile', 'os' => 'iOS', 'browser' => 'ios']], 'count' => 1]],
            ['#/websites/u-1/sessions#', static fn () => ['data' => [['id' => 's1', 'screen' => '390x844', 'language' => 'en-GB', 'region' => 'ENG']], 'count' => 1]],
        ]);
        $rl = self::runlight($router);
        $creds = ['url' => 'https://stats.example.com/', 'username' => 'jon', 'password' => 'pw'];
        $first = Index::importStep($rl, 'default', 'umami', $creds, null, 0);
        self::assertSame(1, $first['links']);
        self::assertSame(1, $first['clicks']);
        self::assertStringStartsWith('POST stats.example.com/api/auth/login', $router->calls[0]);
        $s = $rl->store->db->all('SELECT region, source, browser FROM rl_sessions')[0];
        self::assertSame(['region' => 'GB-ENG', 'source' => 'Newsletter', 'browser' => 'Safari'], $s);
        $again = Index::importStep($rl, 'default', 'umami', $creds, null, 0);
        self::assertSame(1, $again['skipped']);
        try {
            Index::importStep($rl, 'default', 'umami', ['url' => 'nope'], null, 0);
            self::fail('a bad address');
        } catch (ImportError $e) {
            self::assertStringContainsString('Umami address', $e->getMessage());
        }
        try {
            Index::importStep($rl, 'default', 'nowhere', [], null, 0);
            self::fail('an unknown source');
        } catch (ImportError $e) {
            self::assertStringContainsString('cannot import', $e->getMessage());
            self::assertSame(['source' => 'nowhere'], $e->params);
        }
    }

    public function testUmamiALinkAlreadyHereWithTheSameSlugAndDestinationIsSkippedBeforeItsHistoryIsFetched(): void
    {
        $router = new Router([
            ['#/api/links\?#', static fn () => ['data' => [['id' => 'u-9', 'name' => 'Golden', 'url' => 'https://a.com/', 'slug' => 'golden', 'createdAt' => '2026-01-01T00:00:00Z', 'deletedAt' => null]], 'count' => 1]],
            ['#/websites/u-9/#', static fn () => ['data' => [], 'count' => 0]],
        ]);
        $rl = self::runlight($router);
        $rl->init();
        // Brought in earlier some other way, such as a CSV, so it has no Umami id.
        $rl->links->create('default', ['url' => 'https://a.com', 'slug' => 'golden', 'name' => 'Golden']);
        $step = Index::importStep($rl, 'default', 'umami', ['url' => 'https://stats.example.com/', 'apiKey' => 'k'], null, 0);
        self::assertSame(1, $step['skipped']);
        self::assertSame(0, $step['links']);
        self::assertSame([], array_filter($router->calls, static fn (string $c): bool => str_contains($c, '/websites/u-9/')), 'no history was fetched for it');
    }

    public function testALinkWhoseSlugIsTakenOrUnusableIsReportedWithACode(): void
    {
        $rl = new Runlight(['store' => Stores::sqlite(':memory:')]);
        $rl->init();
        $rl->links->create('default', ['url' => 'https://elsewhere.com', 'slug' => 'taken', 'name' => 'Other']);
        $taken = Write::writeLink($rl, 'default', 'dub', ['sourceId' => 'x', 'slug' => 'taken', 'domain' => '', 'name' => 'X', 'url' => 'https://a.com', 'createdAt' => 0], []);
        self::assertSame(['status' => 'failed', 'clicks' => 0, 'reason' => '/taken is already used by "Other"', 'code' => 'import_slug_taken', 'params' => ['slug' => 'taken', 'name' => 'Other']], $taken);
        $bad = Write::writeLink($rl, 'default', 'dub', ['sourceId' => 'y', 'slug' => 'a/b', 'domain' => '', 'name' => '', 'url' => 'https://a.com', 'createdAt' => 0], []);
        self::assertSame('import_slug_bad', $bad['code']);
        $made = Write::writeLink($rl, 'default', 'dub', ['sourceId' => 'z', 'slug' => 'fine', 'domain' => 'www.Go.Brand.com', 'name' => '', 'url' => 'https://a.com/z', 'createdAt' => 0], ['clicks' => [['ts' => 5_000, 'visit' => 'v', 'path' => '/fine', 'query' => '?utm_campaign=c']]]);
        self::assertSame(['status' => 'created', 'clicks' => 1], $made);
        $link = $rl->store->linkBySlug('fine');
        self::assertSame(['go.brand.com', 'fine', Write::importedLinkId('dub', 'z')], [$link['domain'], $link['name'], $link['id']]);
        self::assertSame('c', $rl->store->db->all('SELECT utm_campaign FROM rl_sessions')[0]['utm_campaign']);
        self::assertSame(['status' => 'skipped', 'clicks' => 0], Write::writeLink($rl, 'default', 'dub', ['sourceId' => 'z', 'slug' => 'fine', 'domain' => '', 'name' => '', 'url' => 'https://a.com/z', 'createdAt' => 0], []), 'the same link again');
    }
}
