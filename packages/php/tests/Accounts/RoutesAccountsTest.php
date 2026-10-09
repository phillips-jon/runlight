<?php

declare(strict_types=1);

namespace Runlight\Tests\Accounts;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Store\SqlStore;
use Runlight\Tests\Store\Databases;

/**
 * accounts.test.ts's route-level tests: an app with routes(['accounts' => true]). They need the core
 * (Runlight\Runlight), and are skipped until it is here.
 */
final class RoutesAccountsTest extends TestCase
{
    protected function setUp(): void
    {
        if (!class_exists('Runlight\\Runlight')) {
            $this->markTestSkipped('The PHP core (Runlight\Runlight) is not here yet, so there are no routes to sign in through.');
        }
    }

    protected function tearDown(): void
    {
        Databases::cleanup();
    }

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    /** @param array<string, string> $headers */
    private static function req(string $path, string $method = 'GET', array $headers = [], string $body = ''): Request
    {
        return new Request("https://example.com$path", $method, $headers, $body);
    }

    /** @param array<string, string> $fields */
    private static function form(string $path, array $fields, string $cookie = ''): Request
    {
        return self::req($path, 'POST', ['content-type' => 'application/x-www-form-urlencoded'] + ($cookie !== '' ? ['cookie' => $cookie] : []), (new SearchParams($fields))->toString());
    }

    private static function cookieOf(Response $response): string
    {
        return explode(';', $response->headers->get('set-cookie') ?? '')[0];
    }

    private static function store(string $kind): SqlStore
    {
        return Databases::fresh($kind);
    }

    #[DataProvider('kinds')]
    public function testAnAppWithAccountsOnMakesItsFirstAccountWithItsTokenThenInvitesPeopleByRole(string $kind): void
    {
        $rl = new \Runlight\Runlight(['store' => self::store($kind), 'secret' => str_repeat('k', 64)]);
        $routes = $rl->routes(['token' => 'app-token', 'accounts' => true]);
        $handler = static fn (Request $r): Response => $routes->handle($r);
        $json = static fn (string $cookie, string $method, string $path, mixed $body = null): Response => $handler(self::req("/runlight$path", $method, ['cookie' => $cookie, 'content-type' => 'application/json'], $body === null ? '' : Json::encode($body)));

        // Nobody yet: the dashboard sends you to set up, which asks for the app's token.
        $start = $handler(self::req('/runlight/'));
        $this->assertSame(303, $start->status);
        $this->assertSame('/runlight/setup', $start->headers->get('location'));
        $page = $handler(self::req('/runlight/setup'))->text();
        $this->assertMatchesRegularExpression('/RUNLIGHT_TOKEN/', $page);
        $this->assertMatchesRegularExpression('/action="\/runlight\/setup"/', $page);
        $this->assertMatchesRegularExpression('/href="\/runlight\/auth\.css"/', $page);
        $wrong = $handler(self::form('/runlight/setup', ['code' => 'guess', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(403, $wrong->status);
        $made = $handler(self::form('/runlight/setup', ['code' => 'app-token', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(303, $made->status);
        $this->assertSame('/runlight/', $made->headers->get('location'));
        $this->assertMatchesRegularExpression('/Path=\/runlight;/', $made->headers->get('set-cookie') ?? '', 'the session is for Runlight\'s paths only');
        $owner = self::cookieOf($made);
        $this->assertSame('/runlight/login', $handler(self::req('/runlight/setup'))->headers->get('location'), 'setup closes once there is an account');

        // Signed in, the dashboard and its API answer; signed out, they do not.
        $this->assertSame(200, $handler(self::req('/runlight/', 'GET', ['cookie' => $owner]))->status);
        $this->assertMatchesRegularExpression('/data-accounts=""/', $handler(self::req('/runlight/', 'GET', ['cookie' => $owner]))->text());
        $this->assertSame(401, $handler(self::req('/runlight/api/sites'))->status);
        $this->assertSame(200, $handler(self::req('/runlight/api/sites', 'GET', ['cookie' => $owner]))->status);
        $this->assertSame(200, $handler(self::req('/runlight/api/sites', 'GET', ['authorization' => 'Bearer app-token']))->status, 'a script\'s token still works');
        $this->assertSame('owner', Json::decode($json($owner, 'GET', '/api/account')->text(), true)['account']['role']);

        // The owner invites a member, who joins with their own password.
        $sent = Json::decode($json($owner, 'POST', '/api/people', ['email' => 'mo@example.com', 'role' => 'member'])->text(), true);
        $this->assertFalse($sent['emailed'], 'no mail service here, so the link is for passing on');
        $link = new Url($sent['link']);
        $this->assertSame('/runlight/invite', $link->pathname);
        $this->assertMatchesRegularExpression('/as a member/', $handler(self::req($link->pathname . $link->search))->text());
        $joined = $handler(self::form('/runlight/invite', ['code' => (string) $link->searchParams()->get('code'), 'password' => 'another long one', 'again' => 'another long one']));
        $this->assertSame(303, $joined->status);
        $member = self::cookieOf($joined);

        // A member changes a site's settings, but not people, the mail service, or the assistant's settings.
        $this->assertSame(201, $json($member, 'POST', '/api/goals', ['name' => 'Signup', 'kind' => 'page', 'match' => '/thanks'])->status);
        $this->assertSame(403, $json($member, 'GET', '/api/people')->status);
        $this->assertSame('admin_only', Json::decode($json($member, 'PUT', '/api/mail', new \stdClass())->text(), true)['code']);
        $this->assertSame(403, $json($member, 'PUT', '/api/assistant', new \stdClass())->status);

        // Signing out ends the session; signing in again with the password starts one.
        $out = $handler(self::req('/runlight/logout'));
        $this->assertSame('/runlight/login', $out->headers->get('location'));
        $this->assertSame('/runlight/login', $handler(self::req('/runlight/'))->headers->get('location'));
        $back = $handler(self::form('/runlight/login', ['email' => 'mo@example.com', 'password' => 'another long one', 'next' => '/runlight/?period=7d']));
        $this->assertSame(303, $back->status);
        $this->assertSame('/runlight/?period=7d', $back->headers->get('location'));
        $elsewhere = $handler(self::form('/runlight/login', ['email' => 'mo@example.com', 'password' => 'another long one', 'next' => '//evil.example/']));
        $this->assertSame('/runlight/', $elsewhere->headers->get('location'), 'never sent off the app');
    }

    public function testInDevelopmentOrLeftOpenOnPurposeTheFirstAccountNeedsNoProofInProductionWithoutATokenSetupStaysShut(): void
    {
        $saved = ['NODE_ENV' => getenv('NODE_ENV'), 'RUNLIGHT_TOKEN' => getenv('RUNLIGHT_TOKEN'), 'RUNLIGHT_SECRET' => getenv('RUNLIGHT_SECRET')];
        putenv('RUNLIGHT_TOKEN');
        putenv('RUNLIGHT_SECRET');
        unset($_ENV['RUNLIGHT_TOKEN'], $_SERVER['RUNLIGHT_TOKEN'], $_ENV['RUNLIGHT_SECRET'], $_SERVER['RUNLIGHT_SECRET']);
        try {
            putenv('NODE_ENV=development');
            $dev = (new \Runlight\Runlight(['store' => self::store('sqlite')]))->routes(['accounts' => true]);
            $page = $dev->handle(self::req('/runlight/setup'))->text();
            $this->assertDoesNotMatchRegularExpression('/RUNLIGHT_TOKEN/', $page);
            $made = $dev->handle(self::form('/runlight/setup', ['code' => '', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
            $this->assertSame(303, $made->status);

            putenv('NODE_ENV=production');
            $open = (new \Runlight\Runlight(['store' => self::store('sqlite')]))->routes(['token' => null, 'accounts' => true]);
            $this->assertSame(200, $open->handle(self::req('/runlight/setup'))->status, 'token: null leaves setup open, as it leaves everything');
            $prod = (new \Runlight\Runlight(['store' => self::store('sqlite'), 'secret' => str_repeat('k', 64)]))->routes(['accounts' => true]);
            $shut = $prod->handle(self::req('/runlight/setup'));
            $this->assertSame(403, $shut->status);
            $this->assertMatchesRegularExpression('/Set RUNLIGHT_TOKEN/', $shut->text());
            $tried = $prod->handle(self::form('/runlight/setup', ['code' => '', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
            $this->assertSame(403, $tried->status);
        } finally {
            foreach ($saved as $name => $value) {
                putenv($value === false ? $name : "$name=$value");
            }
        }
    }
}
