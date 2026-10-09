<?php

declare(strict_types=1);

namespace Runlight\Tests\Server;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Json;
use Runlight\Server\Standalone;
use Runlight\Store\Stores;

/** The standalone server's own behaviour, as packages/server/test/server.test.ts checks the Node one's. */
final class StandaloneTest extends TestCase
{
    private const ORIGIN = 'https://stats.example.com';
    private const CODE = 'one-time-code';

    private int $now = 1_791_374_400_000; // 2026-10-07 12:00 UTC

    /** @param array<string, mixed> $options */
    private function make(array $options = []): Standalone
    {
        return new Standalone([
            'store' => Stores::sqlite(':memory:'),
            'secret' => str_repeat('s', 64),
            'now' => fn (): int => $this->now,
            'setupCode' => self::CODE,
            ...$options,
        ]);
    }

    /** @param array<string, string> $headers */
    private static function req(string $path, string $method = 'GET', array $headers = [], string $body = '', ?string $host = null): Request
    {
        return new Request(($host !== null ? "https://$host" : self::ORIGIN) . $path, $method, $headers, $body);
    }

    /** @param array<string, string> $fields */
    private static function form(string $path, array $fields, array $headers = []): Request
    {
        return self::req($path, 'POST', ['content-type' => 'application/x-www-form-urlencoded'] + $headers, (new SearchParams($fields))->toString());
    }

    private static function cookieOf(Response $response): string
    {
        return explode(';', $response->headers->get('set-cookie') ?? '')[0];
    }

    private static function json(mixed $body): string
    {
        return Json::encode($body);
    }

    public function testANewServerIsLockedUntilTheSetupCodeMakesTheFirstAccount(): void
    {
        $server = $this->make(['setupWhere' => 'in setup.txt']);
        $this->assertSame(403, $server->handle(self::req('/'))->status, 'the dashboard waits for setup');
        $this->assertStringContainsString('Open the setup link in setup.txt', $server->handle(self::req('/'))->text());
        $this->assertSame(403, $server->handle(self::req('/setup?code=wrong'))->status);
        $this->assertSame(403, $server->handle(self::form('/setup', ['code' => 'wrong', 'email' => 'a@b.co', 'password' => 'long enough pw']))->status);
        $this->assertSame(200, $server->handle(self::req('/setup?code=' . self::CODE))->status);
        $mismatch = $server->handle(self::form('/setup', ['code' => self::CODE, 'email' => 'a@b.co', 'password' => 'a long password', 'again' => 'a long pasword']));
        $this->assertSame(400, $mismatch->status, 'the password is asked twice');
        $made = $server->handle(self::form('/setup', ['code' => self::CODE, 'email' => 'Jon@Example.com', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(303, $made->status);
        $this->assertSame('/', $made->headers->get('location'));
        $this->assertSame(200, $server->handle(self::req('/', 'GET', ['cookie' => self::cookieOf($made)]))->status, 'signed straight in');
        $this->assertSame('/login', $server->handle(self::req('/setup?code=' . self::CODE))->headers->get('location'), 'setup closes once an account exists');
    }

    public function testWithNoCodeTheFirstAccountIsMadeWithTheToken(): void
    {
        $server = $this->make(['setupCode' => null, 'token' => 'script-token']);
        $this->assertSame('/setup', $server->handle(self::req('/'))->headers->get('location'));
        $this->assertSame(403, $server->handle(self::form('/setup', ['code' => 'wrong', 'email' => 'a@b.co', 'password' => 'a long password', 'again' => 'a long password']))->status);
        $made = $server->handle(self::form('/setup', ['code' => 'script-token', 'email' => 'a@b.co', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(303, $made->status);
    }

    public function testSignInSignOutAndSessionsThatEndWithAPasswordChange(): void
    {
        $server = $this->make();
        $server->accounts->setPassword('jon@example.com', 'a long password', $this->now);
        $away = $server->handle(self::req('/?period=7d'));
        $this->assertSame(303, $away->status);
        $this->assertSame('/login?next=' . rawurlencode('/?period=7d'), $away->headers->get('location'));
        $this->assertSame(401, $server->handle(self::req('/api/sites'))->status);
        $this->assertSame(401, $server->handle(self::form('/login', ['email' => 'jon@example.com', 'password' => 'nope nope nope']))->status);

        $ok = $server->handle(self::form('/login', ['email' => 'JON@example.com', 'password' => 'a long password', 'next' => '//evil.example']));
        $this->assertSame(303, $ok->status);
        $this->assertSame('/', $ok->headers->get('location'), 'a next address off this server is ignored');
        $cookie = self::cookieOf($ok);
        $this->assertSame(200, $server->handle(self::req('/api/sites', 'GET', ['cookie' => $cookie]))->status);
        $this->assertStringContainsString('data-sign-out="/logout"', $server->handle(self::req('/', 'GET', ['cookie' => $cookie]))->text());
        $this->assertStringContainsString('Max-Age=0', $server->handle(self::req('/logout'))->headers->get('set-cookie') ?? '');

        $server->accounts->setPassword('jon@example.com', 'another long password', $this->now);
        $this->assertSame(401, $server->handle(self::req('/api/sites', 'GET', ['cookie' => $cookie]))->status, 'a new password signs out every browser');
    }

    public function testSitesAreAddedCountedAndShortLinksAnswerOnTheirOwnDomains(): void
    {
        $server = $this->make(['token' => 'script-token']);
        $server->accounts->setPassword('jon@example.com', 'a long password', $this->now);
        $auth = ['authorization' => 'Bearer script-token', 'content-type' => 'application/json'];

        $this->assertSame(201, $server->handle(self::req('/api/sites', 'POST', $auth, self::json(['name' => 'Blog', 'hostnames' => 'blog.example.com'])))->status);
        $this->assertSame(200, $server->handle(self::req('/s.js'))->status);
        $hit = $server->handle(self::req('/e', 'POST', ['user-agent' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36', 'x-forwarded-for' => '203.0.113.9'], self::json(['k' => 'pageview', 'u' => 'https://blog.example.com/post', 's' => 'blog.example.com'])));
        $this->assertSame(202, $hit->status);
        $stats = Json::decode($server->handle(self::req('/api/stats?site=blog.example.com&period=today', 'GET', $auth))->text(), true);
        $this->assertSame(1, $stats['stats']['pageviews']);

        $this->assertSame(201, $server->handle(self::req('/api/link-domains?site=blog.example.com', 'POST', $auth, self::json(['domain' => 'go.example.com'])))->status);
        $made = Json::decode($server->handle(self::req('/api/links?site=blog.example.com', 'POST', $auth, self::json(['url' => 'https://blog.example.com/launch', 'slug' => 'launch', 'domain' => 'go.example.com'])))->text(), true);
        $this->assertSame('launch', $made['link']['slug']);
        $short = $server->handle(self::req('/launch', host: 'go.example.com'));
        $this->assertSame(302, $short->status);
        $this->assertSame('https://blog.example.com/launch', $short->headers->get('location'));
        $this->assertSame(302, $server->handle(self::req('/go/launch'))->status, 'every link also answers at /go/:slug on the server itself');

        $health = $server->handle(self::req('/healthz'));
        $this->assertSame([200, 'ok'], [$health->status, $health->text()]);
        $this->assertSame(401, $server->handle(self::req('/api/sites', 'GET', ['authorization' => 'Bearer wrong']))->status);
    }

    public function testALinkDomainNeverTakesOverTheDashboardsOwnNameSignInOrApi(): void
    {
        $server = $this->make(['token' => 'script-token']);
        $server->accounts->setPassword('jon@example.com', 'a long password', $this->now);
        $auth = ['authorization' => 'Bearer script-token', 'content-type' => 'application/json'];
        $server->handle(self::req('/api/sites', 'POST', $auth, self::json(['name' => 'Blog', 'hostnames' => 'blog.example.com'])));
        $addDomain = fn (string $domain, string $host): Response => $server->handle(self::req('/api/link-domains?site=blog.example.com', 'POST', $auth, self::json(['domain' => $domain]), $host));

        // Someone signs in at stats.example.com, so a caller naming another Host cannot add it afterwards.
        $cookie = self::cookieOf($server->handle(self::form('/login', ['email' => 'jon@example.com', 'password' => 'a long password'])));
        $this->assertSame(200, $server->handle(self::req('/api/sites', 'GET', ['cookie' => $cookie]))->status);
        foreach (['decoy.example.org', '203.0.113.5', 'stats.example.com.'] as $host) {
            $this->assertSame(400, $addDomain('stats.example.com', $host)->status, $host);
        }

        // Added anyway: its short links answer, and the server's own pages stay the server's.
        $server->runlight->store->addLinkDomain('stats.example.com', 'blog.example.com', $this->now);
        $server->runlight->forgetLinkDomains();
        $server->handle(self::req('/api/links?site=blog.example.com', 'POST', $auth, self::json(['url' => 'https://blog.example.com/a', 'slug' => 'login', 'domain' => 'stats.example.com'])));
        $server->handle(self::req('/api/links?site=blog.example.com', 'POST', $auth, self::json(['url' => 'https://blog.example.com/b', 'slug' => 'sale', 'domain' => 'stats.example.com'])));
        $this->assertSame(302, $server->handle(self::req('/sale'))->status);
        $this->assertSame(200, $server->handle(self::req('/login'))->status, 'sign-in is still the sign-in page');
        $this->assertSame(200, $server->handle(self::req('/', 'GET', ['cookie' => $cookie]))->status, 'the dashboard opens for someone signed in');
        $this->assertSame(404, $server->handle(self::req('/'))->status);
        $this->assertSame(200, $server->handle(self::req('/api/link-domains/stats.example.com?site=blog.example.com', 'DELETE', ['cookie' => $cookie]))->status, 'so it can be removed');
        $this->assertSame(404, $server->handle(self::req('/sale'))->status);

        // With the public address set, short links never answer there, and nobody can add it under any Host.
        $named = $this->make(['token' => 'script-token', 'url' => self::ORIGIN]);
        $named->handle(self::req('/api/sites', 'POST', $auth, self::json(['name' => 'Blog', 'hostnames' => 'blog.example.com'])));
        $this->assertSame(400, $named->handle(self::req('/api/link-domains?site=blog.example.com', 'POST', $auth, self::json(['domain' => 'stats.example.com']), 'decoy.example.org'))->status);
        $named->runlight->store->addLinkDomain('stats.example.com', 'blog.example.com', $this->now);
        $named->runlight->forgetLinkDomains();
        $named->handle(self::req('/api/links?site=blog.example.com', 'POST', $auth, self::json(['url' => 'https://blog.example.com/b', 'slug' => 'sale', 'domain' => 'stats.example.com'])));
        $this->assertSame(404, $named->handle(self::req('/sale'))->status);
        $this->assertSame(403, $named->handle(self::req('/'))->status, 'the dashboard, waiting for setup');
    }

    public function testOnlyTheOwnerAndAdminsTeachTheServerItsNames(): void
    {
        $server = $this->make();
        $owner = $server->accounts->setPassword('jon@example.com', 'a long password', $this->now);
        $viewer = $server->accounts->setPassword('viewer@example.com', 'another long one', $this->now, 'viewer');
        $as = fn (array $user): string => 'runlight_session=' . rawurlencode($server->accounts->sessionFor($user, $this->now));
        $names = fn (): array => Json::decode($server->runlight->store->setting('server-hosts') ?? '[]', true);
        for ($i = 0; $i < 25; $i++) {
            $server->handle(self::req('/api/sites', 'GET', ['cookie' => $as($viewer), 'x-forwarded-host' => "junk$i.example.org"]));
        }
        $this->assertSame([], $names(), "a viewer's made-up forwarded names fill nothing");
        $server->handle(self::req('/api/sites', 'GET', ['cookie' => $as($owner), 'x-forwarded-host' => '203.0.113.7:8080']));
        $server->handle(self::req('/api/sites', 'GET', ['cookie' => $as($owner)]));
        $this->assertSame(['stats.example.com'], $names(), "an owner's are learned, if they are domain names");

        // A new request, as PHP serves each one, reads them back from the database.
        $again = new Standalone(['store' => $server->runlight->store, 'secret' => str_repeat('s', 64), 'now' => fn (): int => $this->now]);
        $json = ['cookie' => $as($owner), 'content-type' => 'application/json'];
        $again->handle(self::req('/api/sites', 'POST', $json, self::json(['name' => 'Blog', 'hostnames' => 'blog.example.com'])));
        $this->assertSame(400, $again->handle(self::req('/api/link-domains?site=blog.example.com', 'POST', $json, self::json(['domain' => 'stats.example.com']), 'decoy.example.org'))->status);
    }

    public function testCheckRunsTheScheduledWork(): void
    {
        $this->assertSame(['ok' => true, 'reports' => ['sent' => 0, 'failed' => 0]], $this->make()->check());
    }
}
