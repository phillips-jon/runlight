<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\Attributes\DataProvider;

/** Sites, links, shares, tokens, reports, settings, salts, and the live view, at the store, on every database. */
final class RecordsTest extends StoreTestCase
{
    #[DataProvider('kinds')]
    public function testSitesAreKeptWithTheirOverridesAndADeletedSitesRecordsGoWithIt(string $kind): void
    {
        $store = $this->store($kind);
        $store->upsertSite(['id' => 'shop', 'name' => 'Shop', 'hostnames' => ['shop.example.com', 'store.example.com'], 'timezone' => 'Europe/London'], self::NOW);
        // Unchanged, it is left alone; changed, it is updated, keeping when it was made.
        $store->upsertSite(['id' => 'shop', 'name' => 'Shop', 'hostnames' => ['shop.example.com', 'store.example.com'], 'timezone' => 'Europe/London'], self::NOW + 1);
        $store->upsertSite(['id' => 'shop', 'name' => 'A shop', 'hostnames' => ['shop.example.com'], 'timezone' => 'Europe/London'], self::NOW + 2);
        $this->assertSame([
            ['id' => 'shop', 'name' => 'A shop', 'hostnames' => ['shop.example.com'], 'timezone' => 'Europe/London'],
            ['id' => 'default', 'name' => 'Example', 'hostnames' => ['example.com'], 'timezone' => 'UTC'],
        ], $store->sites());
        $this->assertSame([self::NOW], array_map('intval', array_column($store->db->all("SELECT created_at FROM rl_sites WHERE id = 'shop'"), 'created_at')));
        $store->setSiteOverrides('shop', ['name' => 'Renamed', 'timezone' => 'Asia/Tokyo']);
        $store->setSiteOverrides('default', []);
        $overrides = $store->siteOverrides();
        ksort($overrides);
        $this->assertSame(['default' => [], 'shop' => ['name' => 'Renamed', 'timezone' => 'Asia/Tokyo']], $overrides);
        $this->assertSame('{}', $store->db->all("SELECT overrides FROM rl_sites WHERE id = 'default'")[0]['overrides'], 'no overrides is an empty object');

        $t = self::NOW - self::HOUR;
        Seed::visit($store, 's1', 'v1', $t, [], [['pageview', '/', $t, 'p1']], 'shop');
        Seed::visit($store, 's2', 'v2', $t - 40 * self::DAY, [], [['pageview', '/', $t - 40 * self::DAY, 'p2']], 'shop');
        Seed::visit($store, 's3', 'v3', $t, [], [['pageview', '/', $t, 'p3']]);
        $store->saveGoal(self::goal('g1', ['site' => 'shop', 'match' => 'x']));
        $store->insertShare(['id' => 'sh', 'site' => 'shop', 'name' => '', 'createdAt' => 1]);
        $store->addLinkDomain('go.shop.example', 'shop', 1);
        $store->buildRollupDay('shop', '2026-10-05', self::NOW - 36 * self::HOUR, self::NOW - 12 * self::HOUR);
        $this->assertSame($t, $store->lastSeen('shop'));
        $store->deleteSite('shop');
        $this->assertSame(['default'], array_column($store->sites(), 'id'));
        foreach (['rl_events', 'rl_sessions', 'rl_goals', 'rl_shares', 'rl_link_domains', 'rl_rollups', 'rl_rollup_days'] as $table) {
            $this->assertSame(0, (int) $store->db->all("SELECT COUNT(*) AS n FROM $table WHERE site = 'shop'")[0]['n'], $table);
        }
        $this->assertSame(1, $store->stats(self::today())['visits'], 'the other site keeps its visits');
        $this->assertNull($store->lastSeen('shop'));
    }

    #[DataProvider('kinds')]
    public function testShortLinksAndTheirClicks(string $kind): void
    {
        $store = $this->store($kind);
        $link = ['id' => str_repeat('l', 24), 'site' => 'default', 'domain' => '', 'slug' => 'launch', 'name' => 'Launch', 'url' => 'https://example.com/launch', 'createdAt' => self::NOW - self::DAY, 'updatedAt' => self::NOW - self::DAY];
        $store->insertLink($link);
        $this->assertSame($link, $store->linkBySlug('launch'));
        // A slug is unique across every domain while its link lives.
        try {
            $store->insertLink([...$link, 'id' => str_repeat('m', 24), 'domain' => 'go.example.com']);
            $this->fail('a second live link with the slug');
        } catch (\PDOException) {
        }
        $store->updateLink([...$link, 'domain' => 'go.example.com', 'name' => 'Moved', 'updatedAt' => self::NOW]);
        $this->assertSame(['go.example.com', 'Moved', self::NOW], [$store->linkById($link['id'])['domain'], $store->linkById($link['id'])['name'], $store->linkById($link['id'])['updatedAt']]);
        for ($i = 0; $i < 40; $i++) {
            $ts = self::NOW - $i * self::HOUR;
            $session = $i % 4 ? "c$i" : '';
            if ($session !== '') {
                Seed::visit($store, $session, 'cv' . ($i % 3), $ts, ['source' => $i % 2 ? 'Twitter' : 'Direct', 'country' => $i % 2 ? 'GB' : 'US']);
            }
            $store->insertEvent(['site' => 'default', 'ts' => $ts, 'kind' => 'click', 'visitor' => $session === '' ? '' : 'cv' . ($i % 3), 'session' => $session, 'pageview' => '', 'path' => '', 'hostname' => '', 'title' => '', 'name' => '', 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => $link['id']]);
            if ($session !== '') {
                $store->touchSession($session, $ts, 'click', '');
            }
        }
        $listed = $store->links('default', self::NOW - 2 * self::DAY, self::NOW + 1);
        $this->assertSame([40, 3], [$listed[0]['clicks'], $listed[0]['visitors']], 'clicks imported as counts add to clicks only');
        $buckets = [];
        for ($h = 0; $h < 45; $h++) {
            $buckets[] = ['start' => self::NOW - 44 * self::HOUR + $h * self::HOUR, 'end' => self::NOW - 43 * self::HOUR + $h * self::HOUR];
        }
        $series = $store->linkSeries('default', $link['id'], $buckets);
        $this->assertCount(45, $series, 'more buckets than one statement takes');
        $this->assertSame(40, array_sum(array_column($series, 'clicks')));
        $this->assertSame([['value' => 'Twitter', 'visitors' => 3, 'events' => 20], ['value' => 'Direct', 'visitors' => 3, 'events' => 10]], $store->linkBreakdown('default', $link['id'], 0, self::NOW + 1, 'source', 5));
        $this->assertSame(0, $store->stats(self::q(0, self::NOW + 1))['visits'], 'a click alone is not a visit');

        $store->deleteLink($link['id'], self::NOW);
        $this->assertNull($store->linkBySlug('launch'));
        $this->assertNull($store->linkById($link['id']));
        $this->assertSame([], $store->links('default', 0, self::NOW + 1));
        $store->insertLink([...$link, 'id' => str_repeat('n', 24)]);
        $this->assertSame(str_repeat('n', 24), $store->linkBySlug('launch')['id'], 'a deleted link frees its slug');

        $store->addLinkDomain('go.example.com', 'default', 1);
        $store->addLinkDomain('go.example.com', 'other', 2);
        $store->addLinkDomain('a.example.com', 'default', 3);
        $this->assertSame([['domain' => 'a.example.com', 'site' => 'default'], ['domain' => 'go.example.com', 'site' => 'default']], $store->linkDomains(), 'a domain stays with its first site');
        $store->removeLinkDomain('go.example.com');
        $this->assertSame(['a.example.com'], array_column($store->linkDomains(), 'domain'));
    }

    #[DataProvider('kinds')]
    public function testSharesTokensReportsAndSettings(string $kind): void
    {
        $store = $this->store($kind);
        $store->insertShare(['id' => 's1', 'site' => 'default', 'name' => 'Client', 'createdAt' => 1]);
        $store->insertShare(['id' => 's2', 'site' => 'default', 'name' => '', 'createdAt' => 2]);
        $store->renameShare('s1', 'Renamed');
        $this->assertSame(['s2', 's1'], array_column($store->shares('default'), 'id'));
        $this->assertSame(['id' => 's1', 'site' => 'default', 'name' => 'Renamed', 'createdAt' => 1], $store->shareById('s1'));
        $store->deleteShare('s1');
        $this->assertNull($store->shareById('s1'));

        $token = ['id' => 't1', 'name' => 'Script', 'site' => '', 'scope' => 'read', 'hash' => str_repeat('h', 64), 'hint' => 'abcd', 'createdAt' => 5, 'lastUsedAt' => null];
        $store->insertToken($token);
        $store->insertToken([...$token, 'id' => 't2', 'site' => 'default', 'scope' => 'manage', 'hash' => str_repeat('g', 64), 'createdAt' => 6]);
        $store->touchToken('t1', 99);
        $this->assertSame([...$token, 'lastUsedAt' => 99], $store->tokenByHash(str_repeat('h', 64)));
        $this->assertSame(['t2', 't1'], array_column($store->tokens(), 'id'));
        $this->assertTrue($store->deleteToken('t1'), 'a token that was there');
        $this->assertFalse($store->deleteToken('t1'), 'and once it is gone');

        $report = ['id' => 'r1', 'site' => 'default', 'email' => 'a@example.com', 'frequency' => 'weekly', 'lang' => 'en', 'token' => str_repeat('q', 32), 'origin' => '', 'lastPeriod' => '', 'lastSentAt' => null, 'createdAt' => 7];
        $store->insertReport($report);
        $this->assertTrue($store->claimReport('r1', 'w:2026-09-28', 100), 'the first claim wins');
        $this->assertFalse($store->claimReport('r1', 'w:2026-09-28', 101), 'a second, at once, does not');
        $this->assertSame([...$report, 'lastPeriod' => 'w:2026-09-28', 'lastSentAt' => 100], $store->reportBy('token', str_repeat('q', 32)));
        $store->releaseReport('r1', 'w:2026-09-28', '');
        $this->assertSame('', $store->reportBy('id', 'r1')['lastPeriod']);
        $this->assertCount(1, $store->reports());
        $this->assertCount(1, $store->reports('default'));
        $this->assertSame([], $store->reports('elsewhere'));
        $store->deleteReport('r1');
        $this->assertNull($store->reportBy('id', 'r1'));

        $store->setSetting('remote:a', '1');
        $store->setSetting('remote:a', '2');
        $store->setSetting('remote_b', '3');
        $store->setSetting('remote%c', '4');
        $store->setSetting('remote\\d', '5');
        $this->assertSame('2', $store->setting('remote:a'));
        $this->assertSame([['key' => 'remote:a', 'value' => '2']], $store->settingsStartingWith('remote:'));
        $this->assertSame([['key' => 'remote_b', 'value' => '3']], $store->settingsStartingWith('remote_'), 'an underscore is taken literally');
        $this->assertSame([['key' => 'remote%c', 'value' => '4']], $store->settingsStartingWith('remote%'));
        $this->assertSame([['key' => 'remote\\d', 'value' => '5']], $store->settingsStartingWith('remote\\'), 'and a backslash, on MySQL too');
        $store->setSetting('remote:a', null);
        $this->assertNull($store->setting('remote:a'));
    }

    #[DataProvider('kinds')]
    public function testSaltsSessionsAndTheLiveView(string $kind): void
    {
        $store = $this->store($kind);
        $this->assertSame('first', $store->salt('2026-10-06', 'first'));
        $this->assertSame('first', $store->salt('2026-10-06', 'second'), 'two racing callers agree on one');
        $store->salt('2026-10-05', 'old');
        $store->dropSaltsBefore('2026-10-06');
        $this->assertNull($store->saltIfExists('2026-10-05'));
        $this->assertSame('first', $store->saltIfExists('2026-10-06'));

        $t = self::NOW - 3 * self::MIN;
        Seed::visit($store, 's1', 'v1', $t - self::HOUR, ['source' => 'Google', 'country' => 'GB', 'city' => 'London', 'device' => 'Desktop'], [['pageview', '/', $t - self::HOUR, 'old'], ['pageview', '/pricing', $t, 'p1'], ['event', 'Signup', $t + 1000, null]]);
        Seed::visit($store, 's2', 'v2', $t, ['country' => 'US'], [['pageview', '/', $t, 'p2']]);
        $this->assertSame(['id' => 's1', 'visitor' => 'v1'], $store->openSession('default', ['v0', 'v1'], $t - 1));
        $this->assertNull($store->openSession('default', ['v1'], $t + 2000));
        $this->assertNull($store->openSession('default', [], 0));
        $this->assertSame(['session' => 's1', 'visitor' => 'v1', 'path' => '/pricing', 'hostname' => 'example.com', 'ts' => $t, 'startedAt' => $t - self::HOUR, 'lastAt' => $t + 1000], $store->pageview('default', 'p1'));
        $this->assertNull($store->pageview('default', 'nope'));

        $live = $store->realtime('default', self::NOW);
        $this->assertSame(2, $live['visitors']);
        $this->assertSame([['value' => '/', 'visitors' => 1], ['value' => '/pricing', 'visitors' => 1]], $live['pages']);
        $this->assertSame([['value' => 'Google', 'visitors' => 1]], $live['sources']);
        $this->assertSame([['value' => 'GB', 'visitors' => 1], ['value' => 'US', 'visitors' => 1]], $live['countries']);
        $this->assertCount(30, $live['minutes']);
        $this->assertSame(2, $live['minutes'][26]);
        $this->assertSame(['ts' => $t + 1000, 'kind' => 'event', 'path' => '/pricing', 'name' => 'Signup', 'country' => 'GB', 'city' => 'London', 'source' => 'Google', 'device' => 'Desktop'], $live['recent'][0]);
        $this->assertCount(3, $live['recent']);
    }

    #[DataProvider('kinds')]
    public function testAiAgentFetchesAreTheirOwnRowsOutsideVisits(string $kind): void
    {
        $store = $this->store($kind);
        foreach (['GPTBot', 'GPTBot', 'ClaudeBot', 'ClaudeBot', 'Amazonbot'] as $i => $agent) {
            $store->insertEvent(['site' => 'default', 'ts' => self::NOW - $i * self::MIN, 'kind' => 'fetch', 'visitor' => '', 'session' => '', 'pageview' => '', 'path' => $i % 2 ? '/a' : '/b', 'hostname' => 'example.com', 'title' => '', 'name' => $agent, 'props' => ['company' => 'X', 'kind' => 'crawler'], 'engagedMs' => 0, 'scroll' => null, 'link' => '']);
        }
        $this->assertSame([['value' => 'ClaudeBot', 'visitors' => 0, 'fetches' => 2], ['value' => 'GPTBot', 'visitors' => 0, 'fetches' => 2], ['value' => 'Amazonbot', 'visitors' => 0, 'fetches' => 1]], $store->breakdown(self::today(), 'ai_agent', 10, 0));
        $this->assertSame([['value' => '/a', 'visitors' => 0, 'fetches' => 2]], $store->breakdown(self::today(), 'ai_page', 1, 1));
        $this->assertSame(0, $store->stats(self::today())['visits']);
        $this->assertSame('{"company":"X","kind":"crawler"}', $store->db->all("SELECT props FROM rl_events WHERE kind = 'fetch' LIMIT 1")[0]['props']);
    }
}
