<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\Attributes\DataProvider;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\SettingsError;
use Runlight\Store\Stores;
use Runlight\Tests\Store\Databases;
use Runlight\Tests\Support\FakeFetcher;

/** Sites in code and in the dashboard, retention, and connected installs, as sites.test.ts and hub.test.ts test them without routes. */
final class SitesTest extends CoreTestCase
{
    private static function refused(callable $fn, string $code): SettingsError
    {
        try {
            $fn();
        } catch (SettingsError $e) {
            self::assertSame($code, $e->code);
            return $e;
        }
        self::fail("no $code");
    }

    #[DataProvider('kinds')]
    public function testManagedSitesAreAddedChangedAndDeletedAndOutliveARestart(string $kind): void
    {
        $store = Databases::fresh($kind);
        $t = new Harness($store, ['managedSites' => true, 'site' => ['name' => 'Ignored']]);
        $rl = $t->rl;
        $rl->init();
        self::assertSame([], $rl->sites(), 'no sites until one is added; the site in code is ignored');

        self::refused(fn () => $rl->addSite(['name' => 'Blog']), 'site_domain_needed');
        self::refused(fn () => $rl->addSite(['hostnames' => 'not a domain']), 'site_domain_invalid');
        $blog = $rl->addSite(['name' => 'Blog', 'hostnames' => 'https://www.blog.example.com/path', 'timezone' => 'Europe/London']);
        self::assertSame(['id' => 'blog.example.com', 'name' => 'Blog', 'hostnames' => ['blog.example.com'], 'timezone' => 'Europe/London'], $blog);
        $shop = $rl->addSite(['hostnames' => ['shop.example.com', 'store.example.com']]);
        self::assertSame('shop.example.com', $shop['name'], 'the name defaults to the domain');
        $taken = self::refused(fn () => $rl->addSite(['hostnames' => 'store.example.com']), 'site_domain_taken');
        self::assertMatchesRegularExpression('/already belongs to shop\.example\.com/', $taken->getMessage());
        self::refused(fn () => $rl->addSite(['hostnames' => 'x.example.com', 'timezone' => 'Nowhere']), 'unknown_timezone');

        // Visits reach the right site by hostname, across origins.
        $send = fn (string $page, string $ip) => $rl->collect(Harness::hit('https://stats.example.com/runlight/e', ['k' => 'pageview', 'u' => $page], ['ip' => $ip]));
        $send('https://blog.example.com/hello', '203.0.113.1');
        $send('https://store.example.com/', '203.0.113.2');
        $send('https://elsewhere.example/', '203.0.113.3');
        self::assertSame(1, $t->stats($t->today('blog.example.com'))['pageviews']);
        self::assertSame(1, $t->stats($t->today('shop.example.com'))['pageviews']);

        $renamed = $rl->updateSite('shop.example.com', ['name' => 'Shop', 'hostnames' => 'shop.example.com']);
        self::assertSame(['shop.example.com'], $renamed['hostnames']);
        self::refused(fn () => $rl->updateSite('shop.example.com', ['hostnames' => 'blog.example.com']), 'site_domain_taken');
        self::refused(fn () => $rl->updateSite('shop.example.com', ['name' => str_repeat('x', 81)]), 'site_name');

        // A restart reads the sites back from the database.
        $again = new Runlight(['store' => $store, 'managedSites' => true]);
        $again->init();
        self::assertSame([['blog.example.com', 'Blog'], ['shop.example.com', 'Shop']], array_map(static fn (array $s): array => [$s['id'], $s['name']], $again->sites()));

        $rl->deleteSite('shop.example.com');
        self::refused(fn () => $rl->deleteSite('shop.example.com'), 'unknown_site');
        self::assertSame(['blog.example.com'], array_column($rl->sites(), 'id'));
        self::assertSame(0, $t->count('SELECT COUNT(*) AS n FROM rl_events WHERE site = ?', ['shop.example.com']), "a deleted site's visits go with it");
    }

    public function testSitesSetInCodeCannotBeAddedOrDeletedButCanBeRenamed(): void
    {
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'site' => ['name' => 'Code']]);
        self::refused(fn () => $rl->addSite(['hostnames' => 'a.com']), 'sites_in_code');
        self::refused(fn () => $rl->deleteSite('default'), 'sites_in_code');
        self::assertFalse($rl->managedSites);
        $site = $rl->updateSite('default', ['name' => ' Renamed ', 'timezone' => 'Europe/Paris']);
        self::assertSame(['id' => 'default', 'name' => 'Renamed', 'hostnames' => [], 'timezone' => 'Europe/Paris'], $site);
        self::assertSame(['name' => 'Renamed', 'timezone' => 'Europe/Paris'], $rl->store->siteOverrides()['default']);
        self::refused(fn () => $rl->updateSite('nope', ['name' => 'x']), 'unknown_site');
    }

    public function testASecondServerProcessOnTheSameDatabaseSeesNewSitesAndConnectedInstallsAtItsNextCheck(): void
    {
        $store = Stores::sqlite(':memory:');
        $fetcher = new FakeFetcher(static fn (string $url): Response => Response::json(['sites' => [['id' => 'default', 'name' => 'App', 'timezone' => 'UTC', 'hostnames' => ['app.example.com']]]]));
        $one = new Runlight(['store' => $store, 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $fetcher]);
        $two = new Runlight(['store' => $store, 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $fetcher]);
        $one->init();
        $two->init();
        $one->addSite(['hostnames' => 'new.example.com']);
        $one->addSite(['remote' => ['url' => 'https://app.example.com/runlight', 'token' => 'rl_x']]);
        self::assertSame([], array_column($two->sites(), 'id'), 'not yet');
        $two->check();
        $ids = array_column($two->sites(), 'id');
        sort($ids);
        self::assertSame(['app.example.com', 'new.example.com'], $ids);
        self::assertSame('https://app.example.com/runlight', $two->remote('app.example.com')['url']);
        $stored = (string) $store->setting('remote:app.example.com');
        self::assertStringStartsWith('v1:', $stored);
        self::assertStringNotContainsString('rl_x', $stored, 'the token is sealed');
    }

    #[DataProvider('kinds')]
    public function testASitesRetentionSettingDeletesVisitsOlderThanItAllows(string $kind): void
    {
        $t = new Harness($kind, ['site' => ['hostnames' => ['example.com']]]);
        $hit = fn (string $ip) => $t->send(['k' => 'pageview', 'u' => 'https://example.com/'], ['ip' => $ip]);
        $visits = fn (): int => $t->stats($t->all())['visits'];
        $t->now = self::utc(2025, 10, 1);
        $hit('203.0.113.1');
        $t->now = self::utc(2026, 7, 1);
        $hit('203.0.113.2');
        $t->now = self::utc(2026, 10, 6, 12);
        $hit('203.0.113.3');
        self::assertSame(3, $visits());
        self::assertNull($t->rl->retention('default'), 'everything is kept by default');

        self::refused(fn () => $t->rl->setRetention('default', 7), 'retention_bad');
        self::refused(fn () => $t->rl->setRetention('elsewhere', 6), 'unknown_site');
        $t->rl->setRetention('default', 6);
        self::assertSame(3, $visits(), 'the deleting waits for idle(), as TS runs it after answering');
        $t->rl->idle();
        self::assertSame(6, $t->rl->retention('default'));
        self::assertSame(2, $visits(), 'the visit from a year ago is gone');

        $t->now = self::utc(2027, 2, 1);
        $t->rl->check();
        self::assertSame(1, $visits(), 'the scheduled check keeps trimming');
        $t->rl->setRetention('default', null);
        self::assertNull($t->rl->retention('default'));
    }

    public function testRetentionCountsBackCalendarMonthsAsSetUtcMonthDoes(): void
    {
        $t = new Harness('sqlite');
        $t->rl->init();
        $t->rl->setRetention('default', 6);
        $t->now = self::utc(2026, 8, 31, 10, 30) + 123;
        // February 31st runs on to March 3rd, as JavaScript's dates do.
        self::assertSame(self::utc(2026, 3, 3, 10, 30) + 123, $t->rl->retentionCutoff('default'));
    }

    public function testDeletingASiteForgetsItsRetentionItsPluginKeyAndItsUmamiImportProgress(): void
    {
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true]);
        $rl->init();
        $site = $rl->addSite(['hostnames' => 'gone.example.com']);
        $rl->setRetention($site['id'], 12);
        $rl->store->setSetting("observe-key:{$site['id']}", 'rlo_x');
        $rl->store->setSetting("import:umami-visits:{$site['id']}:w1", '{}');
        $rl->deleteSite($site['id']);
        $rl->idle();
        self::assertNull($rl->store->setting("retention:{$site['id']}"));
        self::assertNull($rl->store->setting("observe-key:{$site['id']}"));
        self::assertNull($rl->store->setting("import:umami-visits:{$site['id']}:w1"));
    }

    public function testAConnectedInstallIsReadThroughItsApiAtMostOnceAMinute(): void
    {
        $answers = [];
        $fetcher = new FakeFetcher(static function (string $url, array $init) use (&$answers): Response {
            return array_shift($answers) ?? Response::json(['sites' => []]);
        });
        $t = new Harness('sqlite', ['managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $fetcher]);
        $answers = [Response::json(['sites' => [['id' => 'default', 'name' => 'Shop', 'timezone' => 'Europe/Paris', 'hostnames' => ['shop.example.com']]]]), new Response('', 404)];
        $site = $t->rl->addSite(['remote' => ['url' => 'https://shop.example.com/runlight/', 'token' => 'rl_1']]);
        self::assertSame(['id' => 'shop.example.com', 'name' => 'Shop', 'hostnames' => [], 'timezone' => 'Europe/Paris'], $site);
        self::assertSame(['url' => 'https://shop.example.com/runlight', 'token' => 'rl_1', 'site' => 'default', 'hostnames' => ['shop.example.com'], 'scope' => 'read'], $t->rl->remote($site['id']));
        self::assertSame('Bearer rl_1', $fetcher->requests[0]['headers']['authorization']);

        $answers = [Response::json(['sites' => [['id' => 'default', 'lastSeen' => 123, 'retentionMonths' => 12]]])];
        self::assertSame(['lastSeen' => 123, 'retentionMonths' => 12, 'connection' => 'ok'], $t->rl->remoteInfo($site['id']));
        $asked = count($fetcher->requests);
        self::assertSame(123, $t->rl->remoteLastSeen($site['id']), 'from what it said a moment ago');
        self::assertCount($asked, $fetcher->requests);
        $t->advance(60_000);
        $answers = [new Response('{"error":"Unauthorized"}', 401)];
        $info = $t->rl->remoteInfo($site['id']);
        self::assertSame('refused', $info['connection']);
        self::assertSame(123, $info['lastSeen'], 'the last visit it gave before');
        self::assertSame('{"lastSeen":123,"connection":"refused"}', Json::encode($info), 'retention unknown, as TS leaves it undefined');
        $t->rl->forgetRemoteInfo($site['id']);

        // Hits never land on a site counted elsewhere, even when they name it.
        $t->rl->collect(Harness::hit('https://stats.example.com/runlight/e', ['k' => 'pageview', 'u' => 'https://shop.example.com/', 's' => $site['id']]));
        self::assertSame(0, $t->count('SELECT COUNT(*) AS n FROM rl_events'));
        self::refused(fn () => $t->rl->setRetention($site['id'], 6), 'unknown_site');

        // Deleting it asks the install to delete the token, and keeps nothing of it here.
        $answers = [new Response('', 204)];
        $t->rl->deleteSite($site['id']);
        $last = $fetcher->requests[count($fetcher->requests) - 1];
        self::assertSame(['DELETE', 'https://shop.example.com/runlight/api/token'], [$last['method'], $last['url']]);
        self::assertSame([], $t->store()->settingsStartingWith('remote:'));
    }

    public function testConnectingAgainWithAManageTokenUpgradesTheSameConnectionAndRevokesTheOldToken(): void
    {
        $scope = 'read';
        $fetcher = new FakeFetcher(static function (string $url, array $init) use (&$scope): Response {
            if (str_ends_with($url, '/api/sites')) {
                return Response::json(['sites' => [['id' => 'default', 'name' => 'Shop', 'timezone' => 'UTC', 'hostnames' => ['shop.example.com']]]]);
            }
            if (($init['method'] ?? 'GET') === 'DELETE') {
                return new Response('', 204);
            }
            return Response::json(['scope' => $scope, 'site' => 'default']);
        });
        $hub = new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $fetcher, 'localInstalls' => true]);
        $first = $hub->addSite(['remote' => ['url' => 'http://127.0.0.1:4100/runlight', 'token' => 'rl_read']])['id'];
        self::assertSame('read', $hub->remote($first)['scope']);
        $scope = 'manage';
        $second = $hub->addSite(['remote' => ['url' => 'http://127.0.0.1:4100/runlight', 'token' => 'rl_manage']])['id'];
        self::assertSame($first, $second);
        self::assertSame('manage', $hub->remote($first)['scope']);
        self::assertSame('rl_manage', $hub->remote($first)['token']);
        self::assertCount(1, $hub->sites());
        $revoked = array_values(array_filter($fetcher->requests, static fn (array $r): bool => $r['method'] === 'DELETE'));
        self::assertSame('Bearer rl_read', $revoked[0]['headers']['authorization'], 'the old token was deleted there');
    }

    public function testAConnectionIsRefusedWithACodeTheDashboardCanSay(): void
    {
        $answer = null;
        $fetcher = new FakeFetcher(static function () use (&$answer): Response {
            if ($answer === 'network') {
                throw new \Runlight\Http\FetchError('Could not connect');
            }
            return $answer;
        });
        $hub = new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true, 'fetcher' => $fetcher]);
        self::refused(fn () => $hub->addSite(['remote' => ['url' => 'http://example.com', 'token' => 'x']]), 'connect_url');
        self::refused(fn () => $hub->addSite(['remote' => ['url' => 'https://example.com', 'token' => ' ']]), 'install_token');
        $answer = 'network';
        $e = self::refused(fn () => $hub->addSite(['remote' => ['url' => 'https://example.com:8443/runlight', 'token' => 'x']]), 'unreachable');
        self::assertSame(['host' => 'example.com:8443'], $e->params);
        $answer = new Response('', 401);
        self::refused(fn () => $hub->addSite(['remote' => ['url' => 'https://example.com', 'token' => 'x']]), 'install_refused');
        $answer = Response::json(['sites' => []]);
        $e = self::refused(fn () => $hub->addSite(['remote' => ['url' => 'https://example.com', 'token' => 'x']]), 'connect_not_runlight');
        self::assertSame(['url' => 'https://example.com'], $e->params);
    }

    public function testAssistantSettingsKeepAKeyOnlyForTheSameServiceAtTheSameAddress(): void
    {
        $rl = new Runlight(['store' => Stores::sqlite(':memory:'), 'secret' => str_repeat('k', 32)]);
        $rl->init();
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'nope']), 'assistant_provider');
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'anthropic']), 'assistant_key');
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'custom', 'model' => 'm']), 'assistant_address');
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'custom', 'baseUrl' => 'ftp://x', 'model' => 'm']), 'assistant_address_bad');
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'openai', 'key' => 'k']), 'assistant_model');
        $rl->saveAssistantSettings(['provider' => 'anthropic', 'key' => 'sk-1']);
        self::assertSame(['provider' => 'anthropic', 'model' => '', 'baseUrl' => '', 'key' => 'sk-1'], $rl->assistantSettings());
        self::assertStringNotContainsString('sk-1', (string) $rl->store->setting('assistant'));
        $rl->saveAssistantSettings(['provider' => 'anthropic', 'model' => 'claude-x', 'key' => '']);
        self::assertSame('sk-1', $rl->assistantSettings()['key'], 'same service, blank key: kept');
        self::refused(fn () => $rl->saveAssistantSettings(['provider' => 'anthropic', 'baseUrl' => 'https://proxy.example/v1/', 'key' => '']), 'assistant_key');
        $rl->saveAssistantSettings(null);
        self::assertNull($rl->assistantSettings());
    }
}
