<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Fetcher;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Tests\Conformance\Player;

/**
 * manage.test.ts, ported: what a hub's manage token may change, link domains kept off the dashboard's own names,
 * and a hub that never shows an install's answer as a page. The parts that need links, reports, or sites in the
 * dashboard wait for the PHP core; the rest run on the stand-in until then.
 */
final class ManageTest extends TestCase
{
    /** @var array<string, mixed> */
    private array $env = [];

    protected function setUp(): void
    {
        $this->env = Player::clearEnv();
    }

    protected function tearDown(): void
    {
        Player::restoreEnv($this->env);
    }

    /** An app with two sites and an owner token, as a hub would connect to. */
    private static function app(array $options = []): array
    {
        $rl = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']], ['id' => 'shop', 'hostnames' => ['shop.example.com']]]] + $options);
        $routes = $rl->routes(['token' => 'owner', 'origin' => 'https://app.example.com']);
        $call = function (string $method, string $path, string $auth, mixed $body = null) use ($routes): array {
            $headers = ['authorization' => "Bearer $auth"] + ($body === null ? [] : ['content-type' => 'application/json']);
            $answer = $routes->handle(new Request("https://app.example.com/runlight$path", $method, $headers, $body === null ? '' : Json::encode($body)));
            return ['status' => $answer->status, 'body' => Json::tryDecode($answer->text(), true)];
        };
        $make = fn (string $scope, string $site): string => $call('POST', '/api/tokens', 'owner', ['name' => 'Hub', 'scope' => $scope, 'site' => $site])['body']['secret'];
        return [$rl, $call, $make];
    }

    public function testAManageTokenChangesItsOwnSitesSettingsAndNothingElse(): void
    {
        [, $call, $make] = self::app();
        $this->assertSame(400, $call('POST', '/api/tokens', 'owner', ['name' => 'Hub', 'scope' => 'manage'])['status'], 'a manage token is for one site');
        $manage = $make('manage', 'blog');

        $this->assertSame(['scope' => 'manage', 'site' => 'blog'], $call('GET', '/api/token', $manage)['body']);
        $this->assertSame(201, $call('POST', '/api/goals?site=blog', $manage, ['name' => 'Signup', 'kind' => 'event', 'match' => 'Signup'])['status']);
        $this->assertSame(201, $call('POST', '/api/goals', $manage, ['name' => 'No site given', 'kind' => 'event', 'match' => 'x'])['status'], 'its site is assumed');
        $this->assertCount(2, $call('GET', '/api/goals?site=blog', 'owner')['body']['goals']);
        $this->assertSame(404, $call('POST', '/api/goals?site=shop', $manage, ['name' => 'Elsewhere', 'kind' => 'event', 'match' => 'x'])['status'], 'never another site');
        $this->assertCount(0, $call('GET', '/api/goals?site=shop', 'owner')['body']['goals']);
        $this->assertSame(404, $call('PATCH', '/api/sites/shop', $manage, ['name' => 'Mine now'])['status']);
        $this->assertSame(403, $call('PATCH', '/api/sites/blog', $manage, ['hostnames' => 'evil.example'])['status']);

        // Everything beyond one site's settings stays the owner's.
        $this->assertSame(401, $call('GET', '/api/tokens', $manage)['status']);
        $this->assertSame(403, $call('POST', '/api/tokens', $manage, ['name' => 'More', 'site' => 'blog'])['status']);
        $this->assertSame(403, $call('PUT', '/api/mail', $manage, ['service' => 'webhook'])['status']);
        $this->assertSame(200, $call('GET', '/api/mail?site=blog', $manage)['status'], 'it can see which mail service sends reports');
        $this->assertSame(201, $call('POST', '/api/shares?site=blog', $manage, ['name' => 'For the team'])['status'], 'share links for its site are its to make');
        $this->assertSame(404, $call('POST', '/api/shares?site=shop', $manage, ['name' => 'x'])['status']);
        $this->assertSame(403, $call('DELETE', '/api/sites/blog', $manage)['status']);
        $this->assertSame(403, $call('POST', '/api/links/import?site=blog', $manage, ['rows' => []])['status']);

        Make::needsCore($this);
        $this->assertSame(201, $call('POST', '/api/links?site=blog', $manage, ['url' => 'https://example.org/', 'slug' => 'hello'])['status']);
        $this->assertCount(1, $call('GET', '/api/links?site=blog', $manage)['body']['links']);
        $this->assertSame(201, $call('POST', '/api/reports?site=blog', $manage, ['email' => 'me@example.com'])['status']);
        $this->assertSame(200, $call('PATCH', '/api/sites/blog', $manage, ['name' => 'The blog', 'retentionMonths' => 12])['status']);
    }

    public function testAReadTokenStillOnlyReads(): void
    {
        [, $call, $make] = self::app();
        $read = $make('read', 'blog');
        $this->assertSame(['scope' => 'read', 'site' => 'blog'], $call('GET', '/api/token', $read)['body']);
        $this->assertSame(403, $call('POST', '/api/goals?site=blog', $read, ['name' => 'Signup', 'kind' => 'event', 'match' => 'Signup'])['status']);
        $this->assertSame(200, $call('GET', '/api/stats?site=blog&period=today', $read)['status']);
    }

    public function testALinkDomainCanNeverBeWhereTheDashboardOrACountedSiteLives(): void
    {
        [, $call] = self::app();
        $this->assertSame(400, $call('POST', '/api/link-domains?site=blog', 'owner', ['domain' => 'app.example.com'])['status'], "the dashboard's own host");
        $this->assertSame(400, $call('POST', '/api/link-domains?site=blog', 'owner', ['domain' => 'shop.example.com'])['status'], "a site's domain");
        $this->assertSame(201, $call('POST', '/api/link-domains?site=blog', 'owner', ['domain' => 'go.example.com'])['status']);
    }

    public function testLinkDomainsStayOffTheConfiguredAddressAndTheNamesPeopleSignedInFrom(): void
    {
        $sent = new MailCatcher();
        $rl = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']]], 'fetcher' => $sent, 'secret' => 'k']);
        $routes = $rl->routes(['token' => 'owner', 'origin' => 'https://stats.example.com', 'ownHosts' => fn () => ['dash.example.net:443']]);
        $call = fn (string $method, string $path, string $auth = 'owner', mixed $body = null): Response => $routes->handle(new Request("https://decoy.example.org/runlight$path", $method, ['authorization' => "Bearer $auth", 'content-type' => 'application/json'], $body === null ? '' : Json::encode($body)));
        $add = fn (string $domain): int => $call('POST', '/api/link-domains?site=blog', 'owner', ['domain' => $domain])->status;
        foreach (['stats.example.com', 'stats.example.com.', 'www.stats.example.com', 'dash.example.net', 'decoy.example.org'] as $taken) {
            $this->assertSame(400, $add($taken), $taken);
        }
        // Names inside private networks, which the check would make the install fetch.
        foreach (['metadata.google.internal', 'db.corp', 'printer.local', 'nas.home.arpa', 'router.lan', '10.0.0.5.nip.io', 'app.localhost'] as $inside) {
            $this->assertSame(400, $add($inside), $inside);
        }
        $this->assertSame(201, $add('go.example.org'));
        // One saved before that rule is never fetched.
        $rl->store->addLinkDomain('db.internal', 'blog', 0);
        $check = Make::body($call('GET', '/api/link-domains/db.internal/check?site=blog'));
        $this->assertArrayHasKey('target', $check, 'and where a domain should point');
        unset($check['target']);
        $this->assertSame(['domain' => 'db.internal', 'working' => false, 'reason' => 'is not a public domain name', 'code' => 'check_not_public'], $check);

        // A hub's reports link to the configured address, never to the Host it names, and its samples share one wait.
        Make::needsCore($this);
        $rl->saveMailSettings(['service' => 'webhook', 'url' => 'https://hooks.example.net/mail', 'from' => 'reports@example.com']);
        $manage = Make::body($call('POST', '/api/tokens', 'owner', ['name' => 'Hub', 'scope' => 'manage', 'site' => 'blog']))['secret'];
        $first = Make::body($call('POST', '/api/reports?site=blog', $manage, ['email' => 'a@example.com']))['report'];
        $second = Make::body($call('POST', '/api/reports?site=blog', $manage, ['email' => 'b@example.com']))['report'];
        $this->assertSame(['https://stats.example.com/runlight', 'https://stats.example.com/runlight'], array_column($rl->store->reports('blog'), 'origin'));
        $this->assertSame(200, $call('POST', "/api/reports/{$first['id']}/send?site=blog", $manage)->status, 'the first sample goes out');
        $this->assertCount(1, $sent->mail);
        $this->assertSame('a@example.com', $sent->mail[0]['to']);
        $this->assertStringContainsString('https://stats.example.com/runlight', $sent->mail[0]['text'], 'its links point at the configured address');
        $waits = $call('POST', "/api/reports/{$second['id']}/send?site=blog", $manage);
        $this->assertSame(429, $waits->status, 'another report waits too');
        $this->assertSame('sample_soon_hub', Make::body($waits)['code']);
        $call('DELETE', "/api/reports/{$second['id']}?site=blog", $manage);
        $again = Make::body($call('POST', '/api/reports?site=blog', $manage, ['email' => 'b@example.com']))['report'];
        $this->assertSame(429, $call('POST', "/api/reports/{$again['id']}/send?site=blog", $manage)->status, 'and so does one added again');
        $this->assertCount(1, $sent->mail);
    }

    public function testWithoutItsOwnAddressAnAppGivesAHubNoLinkDomainsOrReports(): void
    {
        // As the quickstart sets it up: one site, no origin, and the app answers on more names than the site's.
        $rl = Make::runlight(['site' => ['name' => 'example.com', 'hostnames' => ['example.com']]]);
        $routes = $rl->routes(['token' => 'owner']);
        $call = function (string $host, string $method, string $path, string $auth, mixed $body = null) use ($routes): array {
            $headers = ['host' => $host, 'authorization' => "Bearer $auth"] + ($body === null ? [] : ['content-type' => 'application/json']);
            $answer = $routes->handle(new Request("https://$host/runlight$path", $method, $headers, $body === null ? '' : Json::encode($body)));
            return ['status' => $answer->status, 'body' => Json::tryDecode($answer->text(), true)];
        };
        $manage = $call('app.example.com', 'POST', '/api/tokens', 'owner', ['name' => 'Hub', 'site' => 'default', 'scope' => 'manage'])['body']['secret'];
        // From the deployment's other name, where the app's own name is not the request's Host.
        $add = $call('example-app.vercel.app', 'POST', '/api/link-domains', $manage, ['domain' => 'app.example.com']);
        $this->assertSame(400, $add['status']);
        $this->assertSame('origin_needed', $add['body']['code']);
        $this->assertSame('origin_needed', $call('example-app.vercel.app', 'POST', '/api/reports', $manage, ['email' => 'cfo@example.com'])['body']['code']);
        $this->assertSame(201, $call('app.example.com', 'POST', '/api/link-domains', 'owner', ['domain' => 'go.example.com'])['status'], 'the owner still adds them');

        // On a link domain the dashboard's paths pass to the app, so the owner can always reach it there.
        Make::needsCore($this);
        foreach (['/runlight', '/runlight/api/sites'] as $path) {
            $this->assertNull($rl->linkDomainResponse(new Request("https://go.example.com$path", 'GET', ['host' => 'go.example.com'])), $path);
        }
        $this->assertSame(404, $rl->linkDomainResponse(new Request('https://go.example.com/nothing', 'GET', ['host' => 'go.example.com']))?->status);
        // Middleware that never made the routes leaves the default path alone too.
        $apart = Make::runlight(['store' => $rl->store, 'site' => ['name' => 'example.com', 'hostnames' => ['example.com']]]);
        $this->assertNull($apart->linkDomainResponse(new Request('https://go.example.com/runlight', 'GET', ['host' => 'go.example.com'])));
    }

    public function testTheHubNeverPassesOnAnInstallsAnswerAsAPageNorFollowsItsRedirects(): void
    {
        Make::needsCore($this);
        $evil = new class () implements Fetcher {
            public function fetch(string $url, array $init = []): Response
            {
                $path = (string) parse_url($url, PHP_URL_PATH);
                return match (true) {
                    str_starts_with($path, '/runlight/api/sites') => new Response(Json::encode(['sites' => [['id' => 'x', 'name' => 'X', 'timezone' => 'UTC', 'hostnames' => ['x.example.com']]]]), 200, ['content-type' => 'application/json']),
                    str_starts_with($path, '/runlight/api/stats') => new Response('<script>alert(1)</script>', 200, ['content-type' => 'text/html']),
                    str_starts_with($path, '/runlight/api/series') => new Response('', 302, ['location' => 'http://169.254.169.254/']),
                    str_starts_with($path, '/runlight/api/rhythm') => new Response(Json::encode(['error' => 'Your session ended. Sign in again at https://evil.example/login ' . str_repeat('x', 1000), 'code' => 'link_taken', 'params' => ['slug' => 'a', 'n' => 5]]), 400, ['content-type' => 'application/json']),
                    default => new Response('{}', 404),
                };
            }
        };
        $hub = Make::runlight(['managedSites' => true, 'secret' => str_repeat('k', 32), 'fetcher' => $evil]);
        $routes = $hub->routes(['token' => 'owner']);
        $call = fn (string $path, string $method = 'GET', ?string $body = null): Response => $routes->handle(new Request("https://hub.example.com/runlight$path", $method, ['authorization' => 'Bearer owner', 'content-type' => 'application/json'], $body ?? ''));
        $added = $call('/api/sites', 'POST', Json::encode(['remote' => ['url' => 'http://127.0.0.1:9/runlight', 'token' => 'rl_x']]));
        $id = Make::body($added)['site']['id'];
        $page = $call("/api/stats?site=$id&period=today");
        $this->assertMatchesRegularExpression('/^application\/json/', $page->headers->get('content-type') ?? '');
        $this->assertSame('nosniff', $page->headers->get('x-content-type-options'));
        $this->assertMatchesRegularExpression("/default-src 'none'/", $page->headers->get('content-security-policy') ?? '');
        $this->assertSame(502, $call("/api/series?site=$id&period=today")->status, 'a redirect is reported, not followed');
        // An install's error says where it came from, short, with only its code and string params.
        $said = Make::body($call("/api/rhythm?site=$id&period=today"));
        $this->assertMatchesRegularExpression('/^127\.0\.0\.1:9: Your session ended/', $said['error']);
        $this->assertLessThan(340, strlen($said['error']));
        $this->assertSame('link_taken', $said['code']);
        $this->assertSame(['slug' => 'a'], $said['params']);
    }
}

/** A mail webhook that keeps what it is sent, standing in for the small HTTP server manage.test.ts starts. */
final class MailCatcher implements Fetcher
{
    /** @var list<array<string, mixed>> */
    public array $mail = [];

    public function fetch(string $url, array $init = []): Response
    {
        $this->mail[] = Json::decode((string) ($init['body'] ?? '{}'), true);
        return new Response('ok');
    }
}
