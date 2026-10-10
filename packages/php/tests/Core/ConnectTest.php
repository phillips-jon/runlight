<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\TestCase;
use Runlight\Connect;
use Runlight\ConnectError;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Runlight;
use Runlight\Store\Stores;

/** Connecting an install through its consent page, as hub.test.ts tests it, with the install played by a Router. */
final class ConnectTest extends TestCase
{
    private const APP = 'http://127.0.0.1:4100/runlight';

    private int $now = 1_791_288_000_000;

    /** An install that speaks OAuth, as an app's Runlight does. */
    private static function install(array $meta = [], array $registered = ['client_id' => 'c1'], int $registerStatus = 201): Router
    {
        $meta = $meta ?: [
            'authorization_endpoint' => 'http://127.0.0.1:4100/runlight/oauth/authorize',
            'token_endpoint' => 'http://127.0.0.1:4100/runlight/oauth/token',
            'registration_endpoint' => 'http://127.0.0.1:4100/runlight/oauth/register',
            'scopes_supported' => ['read', 'manage'],
        ];
        return new Router([
            ['#/\.well-known/oauth-authorization-server$#', static fn () => $meta],
            ['#/oauth/register$#', static fn () => [$registerStatus, $registered]],
            ['#/oauth/token$#', static fn () => ['access_token' => 'rl_manage', 'site' => 'blog']],
            ['#/api/sites$#', static fn () => ['sites' => [['id' => 'shop', 'name' => 'Shop', 'timezone' => 'UTC', 'hostnames' => ['shop.example.com']], ['id' => 'blog', 'name' => 'Blog', 'timezone' => 'Asia/Tokyo', 'hostnames' => ['blog.example.com']]]]],
            ['#/api/token$#', static fn () => ['scope' => 'manage', 'site' => 'blog']],
        ]);
    }

    private function hub(Router $router): Runlight
    {
        return new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $router, 'localInstalls' => true, 'now' => fn (): int => $this->now]);
    }

    private static function refused(callable $fn, string $code): ConnectError
    {
        try {
            $fn();
        } catch (ConnectError $e) {
            self::assertSame($code, $e->code);
            return $e;
        }
        self::fail("no $code");
    }

    public function testAHubConnectsAnAppThroughItsConsentPageForTheOneSiteTheOwnerPicked(): void
    {
        $router = self::install();
        $hub = $this->hub($router);
        $hub->init();
        $back = 'http://localhost:4900/runlight/api/sites/connect/done';
        $consent = new Url(Connect::startConnect($hub, self::APP . '/', $back));
        self::assertSame('http://127.0.0.1:4100/runlight/oauth/authorize', $consent->origin() . $consent->pathname);
        $q = $consent->searchParams();
        self::assertSame(['code', 'c1', $back, 'S256', 'manage'], [$q->get('response_type'), $q->get('client_id'), $q->get('redirect_uri'), $q->get('code_challenge_method'), $q->get('scope')]);
        self::assertMatchesRegularExpression('/^[a-f0-9]{32}$/', (string) $q->get('state'));
        self::assertNull($q->get('site'));
        $registration = Json::decode($router->requests[1]['init']['body'], true);
        self::assertSame(['client_name' => 'Runlight at localhost:4900', 'redirect_uris' => [$back]], $registration);

        $pending = Json::decode((string) $hub->store->setting('connect:' . $q->get('state')), true);
        self::assertSame(rtrim(strtr(base64_encode(hash('sha256', $pending['verifier'], true)), '+/', '-_'), '='), $q->get('code_challenge'), 'the challenge is the verifier hashed');
        self::assertSame($this->now + 15 * 60_000, $pending['expires']);

        $id = Connect::finishConnect($hub, new SearchParams(['state' => (string) $q->get('state'), 'code' => 'the-code']));
        self::assertSame('blog.example.com', $id);
        self::assertSame(['url' => self::APP, 'token' => 'rl_manage', 'site' => 'blog', 'hostnames' => ['blog.example.com'], 'scope' => 'manage'], $hub->remote($id));
        self::assertSame(['id' => 'blog.example.com', 'name' => 'Blog', 'hostnames' => [], 'timezone' => 'Asia/Tokyo'], $hub->site($id));
        $exchange = array_values(array_filter($router->requests, static fn (array $r): bool => str_ends_with($r['url'], '/oauth/token')))[0];
        $form = new SearchParams($exchange['init']['body']);
        self::assertSame(['authorization_code', 'the-code', 'c1', $back, $pending['verifier']], [$form->get('grant_type'), $form->get('code'), $form->get('client_id'), $form->get('redirect_uri'), $form->get('code_verifier')]);

        // A code works once.
        self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => (string) $q->get('state'), 'code' => 'the-code'])), 'expired');
    }

    public function testWhatWentWrongComesBackAsACode(): void
    {
        $hub = $this->hub(self::install());
        $hub->init();
        $start = fn (string $site = ''): SearchParams => (new Url(Connect::startConnect($hub, self::APP, 'https://hub.example/done', $site)))->searchParams();
        self::assertSame('blog', $start('blog')->get('site'), 'which of its sites to offer first');
        $denied = $start();
        self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => (string) $denied->get('state'), 'error' => 'access_denied'])), 'denied');
        $other = $start();
        $e = self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => (string) $other->get('state'), 'error' => 'server_error', 'error_description' => 'Sign in again'])), 'refused');
        self::assertSame('Sign in again', $e->getMessage());
        self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => 'not-a-state'])), 'expired');
        // An attempt nobody came back from in time.
        $late = $start();
        $this->now += 16 * 60_000;
        self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => (string) $late->get('state')])), 'expired');
        // Starting again clears the ones that ran out.
        $start();
        self::assertCount(1, $hub->store->settingsStartingWith('connect:'));
    }

    public function testAHubOnlyFollowsAnInstallsOwnEndpointsWhenConnecting(): void
    {
        $hostile = self::install(['authorization_endpoint' => 'http://127.0.0.1:1/authorize', 'token_endpoint' => 'http://169.254.169.254/token', 'registration_endpoint' => 'http://169.254.169.254/register', 'scopes_supported' => ['read', 'manage']]);
        $hub = $this->hub($hostile);
        $e = self::refused(fn () => Connect::startConnect($hub, 'http://127.0.0.1:4100', 'https://hub.example/done'), 'endpoints');
        self::assertMatchesRegularExpression('/named endpoints on another address/', $e->getMessage());
        self::assertCount(1, $hostile->requests, 'nothing else was asked');
    }

    public function testAnInstallThatCannotConnectSaysWhy(): void
    {
        self::refused(fn () => Connect::startConnect($this->hub(self::install()), 'ftp://x', 'https://hub.example/done'), 'url');
        self::refused(fn () => Connect::startConnect($this->hub(new Router([])), self::APP, 'https://hub.example/done'), 'not_runlight');
        $old = self::install(['authorization_endpoint' => self::APP . '/oauth/authorize', 'token_endpoint' => self::APP . '/oauth/token', 'registration_endpoint' => self::APP . '/oauth/register', 'scopes_supported' => ['read']]);
        self::refused(fn () => Connect::startConnect($this->hub($old), self::APP, 'https://hub.example/done'), 'old');
        $e = self::refused(fn () => Connect::startConnect($this->hub(self::install([], ['error_description' => 'redirect_uris must use https'], 400)), self::APP, 'http://hub.example/done'), 'register');
        self::assertSame(['url' => self::APP, 'reason' => 'redirect_uris must use https.'], $e->params);
        $e = self::refused(fn () => Connect::startConnect($this->hub(self::install([], ['nope' => true], 400)), self::APP, 'http://hub.example/done'), 'register');
        self::assertSame("This server's address must use https.", $e->params['reason']);
        $down = new class () implements \Runlight\Http\Fetcher {
            public function fetch(string $url, array $init = []): \Runlight\Http\Response
            {
                throw new \Runlight\Http\FetchError('refused');
            }
        };
        $hub = new Runlight(['store' => Stores::sqlite(':memory:'), 'fetcher' => $down, 'localInstalls' => true]);
        $e = self::refused(fn () => Connect::startConnect($hub, self::APP, 'https://hub.example/done'), 'unreachable');
        self::assertSame(['host' => '127.0.0.1:4100'], $e->params);
    }

    public function testWithoutLocalInstallsAHubAsksOnlyPublicHttpsAddresses(): void
    {
        $router = self::install();
        $hub = new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $router, 'now' => fn (): int => $this->now]);
        $hub->init();
        self::refused(fn () => Connect::startConnect($hub, self::APP, 'https://hub.example/done'), 'url');
        foreach (['https://10.0.0.5', 'https://169.254.169.254', 'https://[::1]:4100', 'https://localhost'] as $url) {
            self::refused(fn () => Connect::startConnect($hub, $url, 'https://hub.example/done'), 'unreachable');
        }
        try {
            $hub->addSite(['remote' => ['url' => 'https://10.0.0.5/runlight', 'token' => 't']]);
            self::fail('a private address was added');
        } catch (\Runlight\SettingsError $e) {
            self::assertSame('unreachable', $e->code);
        }
        self::assertSame([], $router->requests, 'nothing was fetched');
        // A redirect from the install is handed back, never followed, so its token goes nowhere else.
        $moved = new \Runlight\Tests\RecordingFetcher([\Runlight\Http\Response::redirect('https://elsewhere.example/api/sites')]);
        $hub = new Runlight(['store' => Stores::sqlite(':memory:'), 'managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $moved, 'now' => fn (): int => $this->now]);
        $hub->init();
        try {
            $hub->addSite(['remote' => ['url' => 'https://app.example/runlight', 'token' => 't']]);
            self::fail('a redirect was taken for an install');
        } catch (\Runlight\SettingsError $e) {
            self::assertSame('connect_not_runlight', $e->code);
        }
        self::assertSame(['https://app.example/runlight/api/sites'], array_column($moved->requests, 'url'));
    }

    public function testAnAddressTheUrlParserRefusesIsTheAddressError(): void
    {
        foreach (['https://[', 'https://[::1', 'https://a b'] as $url) {
            self::refused(fn () => Connect::installUrl($url), 'url');
        }
        self::assertSame('https://example.com/runlight', Connect::installUrl('https://example.com/runlight/'));
    }

    public function testAnAttemptSavedWithoutAnExpiryHasExpired(): void
    {
        $router = new Router([]);
        $hub = $this->hub($router);
        $hub->init();
        $state = str_repeat('a', 32);
        foreach ([['url' => self::APP, 'client' => 'c', 'verifier' => 'v', 'redirect' => 'https://hub.example/done', 'token' => self::APP . '/oauth/token'], null, 5, ['expires' => '9999999999999']] as $stored) {
            $hub->store->setSetting("connect:$state", Json::encode($stored));
            self::refused(fn () => Connect::finishConnect($hub, new SearchParams(['state' => $state, 'code' => 'c'])), 'expired');
        }
        self::assertSame([], $router->requests, 'nothing was fetched');
        // Starting clears every attempt that cannot be read or has no expiry.
        $fresh = $this->hub(self::install());
        $fresh->init();
        foreach (['b' => 'null', 'c' => '5', 'd' => 'not json', 'e' => '{"url":"x"}'] as $letter => $value) {
            $fresh->store->setSetting('connect:' . str_repeat($letter, 32), $value);
        }
        Connect::startConnect($fresh, self::APP, 'https://hub.example/done');
        self::assertCount(1, $fresh->store->settingsStartingWith('connect:'));
    }
}
