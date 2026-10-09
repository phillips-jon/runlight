<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\OAuth;
use Runlight\Tests\Conformance\Player;

/** oauth.test.ts, ported: on the PHP core when it is here, and on the stand-in until then. */
final class OAuthTest extends TestCase
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

    private static function b64url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    /** @param array<string, string> $headers */
    private static function at(string $url, string $method = 'GET', array $headers = [], ?string $body = null): Request
    {
        if ($body !== null && !isset($headers['content-type'])) {
            $headers['content-type'] = 'text/plain;charset=UTF-8';
        }
        return new Request($url, $method, $headers, $body ?? '');
    }

    private static function form(array $fields): string
    {
        return (new SearchParams($fields))->toString();
    }

    public function testAnAppConnectsToTheMcpServerOverOAuth(): void
    {
        $rl = Make::runlight(['sites' => [
            ['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']],
            ['id' => 'b', 'name' => 'Site B', 'hostnames' => ['b.com']],
        ]]);
        $routes = $rl->routes(['token' => 'secret']);
        $origin = 'https://x.com';
        $owner = ['authorization' => 'Bearer secret'];
        $form = ['content-type' => 'application/x-www-form-urlencoded'];

        // The MCP endpoint points at the metadata.
        $refused = $routes->handle(self::at("$origin/runlight/mcp", 'POST', ['content-type' => 'application/json'], '{}'));
        $this->assertSame(401, $refused->status);
        preg_match('/resource_metadata="([^"]+)"/', $refused->headers->get('www-authenticate') ?? '', $m);
        $this->assertSame("$origin/runlight/.well-known/oauth-protected-resource", $m[1] ?? null);
        $resource = Make::body($routes->handle(self::at($m[1])));
        $this->assertSame(["$origin/runlight"], $resource['authorization_servers']);
        $this->assertSame("$origin/runlight/mcp", $resource['resource']);
        $server = Make::body($routes->handle(self::at("$origin/.well-known/oauth-authorization-server/runlight")));
        $this->assertSame("$origin/runlight/oauth/token", $server['token_endpoint']);
        $this->assertSame(['S256'], $server['code_challenge_methods_supported']);

        // Registration.
        $this->assertSame(400, $routes->handle(self::at("$origin/runlight/oauth/register", 'POST', ['content-type' => 'application/json'], Json::encode(['redirect_uris' => ['http://evil.example/cb']])))->status);
        $registered = $routes->handle(self::at("$origin/runlight/oauth/register", 'POST', ['content-type' => 'application/json'], Json::encode(['client_name' => 'Claude', 'redirect_uris' => ['https://claude.ai/api/mcp/auth_callback']])));
        $this->assertSame(201, $registered->status);
        $clientId = Make::body($registered)['client_id'];

        // Consent: signed out it says so; signed in it asks; allowing sends a code back.
        $verifier = self::b64url(random_bytes(32));
        $challenge = self::b64url(hash('sha256', $verifier, true));
        $params = self::form(['response_type' => 'code', 'client_id' => $clientId, 'redirect_uri' => 'https://claude.ai/api/mcp/auth_callback', 'code_challenge' => $challenge, 'code_challenge_method' => 'S256', 'state' => 'xyz']);
        $this->assertSame(401, $routes->handle(self::at("$origin/runlight/oauth/authorize?$params"))->status);
        $wrongRedirect = new SearchParams($params);
        $wrongRedirect->set('redirect_uri', 'https://evil.example/cb');
        $this->assertSame(400, $routes->handle(self::at("$origin/runlight/oauth/authorize?$wrongRedirect", 'GET', $owner))->status, 'never sends a code to an address the app did not register');
        $consent = $routes->handle(self::at("$origin/runlight/oauth/authorize?$params", 'GET', $owner));
        $this->assertSame(200, $consent->status);
        $page = $consent->text();
        $this->assertMatchesRegularExpression('/Claude<\/strong> wants to read your Runlight stats/', $page);
        $this->assertMatchesRegularExpression('/sends you back to <strong>claude\.ai<\/strong>/', $page, 'the page shows where the answer goes');
        $deny = $routes->handle(self::at("$origin/runlight/oauth/authorize", 'POST', $owner + $form, "$params&decision=deny"));
        $this->assertMatchesRegularExpression('/error=access_denied&state=xyz/', $deny->headers->get('location') ?? '');
        $forged = $routes->handle(self::at("$origin/runlight/oauth/authorize", 'POST', $owner + ['origin' => 'https://evil.example'] + $form, "$params&decision=allow"));
        $this->assertSame(403, $forged->status);
        $allow = $routes->handle(self::at("$origin/runlight/oauth/authorize", 'POST', $owner + ['origin' => $origin] + $form, "$params&decision=allow&site=b"));
        $back = new Url($allow->headers->get('location') ?? '');
        $this->assertSame('https://claude.ai/api/mcp/auth_callback', $back->origin() . $back->pathname);
        $this->assertSame('xyz', $back->searchParams()->get('state'));
        $code = $back->searchParams()->get('code');

        // The token: PKCE checked, the code good once.
        $exchange = fn (string $code, string $used): Response => $routes->handle(self::at("$origin/runlight/oauth/token", 'POST', $form, self::form(['grant_type' => 'authorization_code', 'code' => $code, 'client_id' => $clientId, 'redirect_uri' => 'https://claude.ai/api/mcp/auth_callback', 'code_verifier' => $used])));
        $this->assertSame('invalid_grant', Make::body($exchange($code, 'wrong-verifier'))['error']);
        $this->assertSame('invalid_grant', Make::body($exchange($code, $verifier))['error'], 'a code that failed once is spent');

        // Again, properly this time.
        $second = $routes->handle(self::at("$origin/runlight/oauth/authorize", 'POST', $owner + ['origin' => $origin] + $form, "$params&decision=allow&site=b"));
        $code2 = (new Url($second->headers->get('location') ?? ''))->searchParams()->get('code');
        $issued = Make::body($exchange($code2, $verifier));
        $this->assertSame('Bearer', $issued['token_type']);
        $this->assertSame('read', $issued['scope']);
        $this->assertSame('b', $issued['site']);

        $call = $routes->handle(self::at("$origin/runlight/mcp", 'POST', ['authorization' => "Bearer {$issued['access_token']}", 'content-type' => 'application/json'], Json::encode(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call', 'params' => ['name' => 'list_sites', 'arguments' => Json::object()]])));
        $sites = Json::decode(Make::body($call)['result']['content'][0]['text'], true)['sites'];
        $this->assertSame(['b'], array_column($sites, 'id'), 'the token reads only the site chosen at consent');
        $tokens = Make::body($routes->handle(self::at("$origin/runlight/api/tokens", 'GET', $owner)));
        $this->assertSame([['Claude (OAuth)', 'b']], array_map(fn (array $t) => [$t['name'], $t['site']], $tokens['tokens']));
    }

    public function testRegisteringStoresNothingSoAFloodOfRegistrationsNeverKeepsARealAppOut(): void
    {
        $now = gmmktime(12, 0, 0, 10, 7, 2026) * 1000;
        $rl = Make::runlight(['sites' => [['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']]], 'now' => function () use (&$now): int {
            return $now;
        }]);
        $routes = $rl->routes(['token' => 'secret']);
        $owner = ['authorization' => 'Bearer secret'];
        $register = fn (string $name, string $ip = '', string $redirect = 'https://app.example/cb'): Response => $routes->handle(
            self::at('https://x.com/runlight/oauth/register', 'POST', ['content-type' => 'application/json'], Json::encode(['client_name' => $name, 'redirect_uris' => [$redirect]])),
            ['ip' => $ip],
        );
        for ($i = 0; $i < 500; $i++) {
            $this->assertSame(201, $register("flood $i")->status);
        }
        $this->assertCount(0, $rl->store->settingsStartingWith('oauth-client:'));
        $this->assertCount(0, $rl->store->settingsStartingWith('oauth-used:'));

        // A real app still registers, and its id names it and its address, signed, so nobody can change them.
        $claude = $register('Claude', '', 'https://claude.ai/cb');
        $this->assertSame(201, $claude->status);
        $clientId = Make::body($claude)['client_id'];
        $verifier = self::b64url(random_bytes(32));
        $fields = ['response_type' => 'code', 'client_id' => $clientId, 'redirect_uri' => 'https://claude.ai/cb', 'code_challenge' => self::b64url(hash('sha256', $verifier, true)), 'code_challenge_method' => 'S256'];
        $params = self::form($fields);
        $this->assertMatchesRegularExpression('/Claude<\/strong> wants to read/', $routes->handle(self::at("https://x.com/runlight/oauth/authorize?$params", 'GET', $owner))->text());
        [$payload, $signature] = explode('.', $clientId);
        $forged = self::b64url(Json::encode(['n' => 'Claude', 'r' => ['https://evil.example/cb'], 't' => $now])) . ".$signature";
        $this->assertNotSame($payload, explode('.', $forged)[0]);
        $this->assertSame(400, $routes->handle(self::at('https://x.com/runlight/oauth/authorize?' . self::form(['client_id' => $forged, 'redirect_uri' => 'https://evil.example/cb'] + $fields), 'GET', $owner))->status);

        // Allowed and swapped for a token, the app gets its first row.
        $allow = $routes->handle(self::at('https://x.com/runlight/oauth/authorize', 'POST', $owner + ['origin' => 'https://x.com', 'content-type' => 'application/x-www-form-urlencoded'], "$params&decision=allow"));
        $code = (new Url($allow->headers->get('location') ?? ''))->searchParams()->get('code');
        $issued = $routes->handle(self::at('https://x.com/runlight/oauth/token', 'POST', ['content-type' => 'application/x-www-form-urlencoded'], self::form(['grant_type' => 'authorization_code', 'code' => $code, 'client_id' => $clientId, 'redirect_uri' => 'https://claude.ai/cb', 'code_verifier' => $verifier])));
        $this->assertSame(200, $issued->status);
        $this->assertCount(1, $rl->store->settingsStartingWith('oauth-used:'));

        // An app stored before ids were signed still works, and one that never connected goes after a day.
        $rl->store->setSetting('oauth-client:' . str_repeat('a', 32), Json::encode(['name' => 'Old', 'redirects' => ['https://old.example/cb'], 'createdAt' => $now]));
        $old = self::form(['client_id' => str_repeat('a', 32), 'redirect_uri' => 'https://old.example/cb'] + $fields);
        $this->assertSame(200, $routes->handle(self::at("https://x.com/runlight/oauth/authorize?$old", 'GET', $owner))->status);
        $now += 86_400_000;
        $register('Another');
        $this->assertCount(0, $rl->store->settingsStartingWith('oauth-client:'));

        // One address registers at most ten a minute.
        for ($i = 0; $i < 10; $i++) {
            $this->assertSame(201, $register("app $i", '203.0.113.9')->status);
        }
        $this->assertSame(429, $register('one more', '203.0.113.9')->status);
        $this->assertSame(201, $register('one more', '203.0.113.10')->status);
    }

    public function testBeforeAnOwnerHasAllowedAnAppOnceARequestItGotWrongEndsOnAPage(): void
    {
        $rl = Make::runlight(['sites' => [['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']]]]);
        $routes = $rl->routes(['signIn' => '/login', 'authorize' => fn () => false]);
        $registered = $routes->handle(self::at('https://x.com/runlight/oauth/register', 'POST', ['content-type' => 'application/json'], Json::encode(['client_name' => 'x', 'redirect_uris' => ['https://evil.example/landing']])));
        $clientId = Make::body($registered)['client_id'];
        foreach ([['response_type' => 'token'], ['response_type' => 'code', 'code_challenge_method' => 'plain', 'code_challenge' => str_repeat('a', 43)]] as $asked) {
            $answer = $routes->handle(self::at('https://x.com/runlight/oauth/authorize?' . self::form(['client_id' => $clientId, 'redirect_uri' => 'https://evil.example/landing', 'state' => 'x'] + $asked)));
            $this->assertSame(400, $answer->status);
            $this->assertNull($answer->headers->get('location'));
        }
    }

    public function testASignedInViewerIsToldOnlyAnOwnerCanConnectNeverSentToSignInAgain(): void
    {
        $rl = Make::runlight(['sites' => [['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']]]]);
        $routes = $rl->routes(['signIn' => '/login', 'authorize' => fn (Request $r) => $r->headers->get('cookie') === 'viewer' ? 'read' : false]);
        $registered = $routes->handle(self::at('https://x.com/runlight/oauth/register', 'POST', ['content-type' => 'application/json'], Json::encode(['client_name' => 'Claude', 'redirect_uris' => ['https://claude.ai/cb']])));
        $clientId = Make::body($registered)['client_id'];
        $params = self::form(['response_type' => 'code', 'client_id' => $clientId, 'redirect_uri' => 'https://claude.ai/cb', 'code_challenge' => str_repeat('a', 43), 'code_challenge_method' => 'S256']);
        $signedOut = $routes->handle(self::at("https://x.com/runlight/oauth/authorize?$params"));
        $this->assertSame(303, $signedOut->status);
        $this->assertStringStartsWith('/login?next=%2Frunlight%2Foauth%2Fauthorize%3Fresponse_type%3Dcode', $signedOut->headers->get('location') ?? '');
        $viewer = $routes->handle(self::at("https://x.com/runlight/oauth/authorize?$params", 'GET', ['cookie' => 'viewer']));
        $this->assertSame(403, $viewer->status);
        $this->assertMatchesRegularExpression('/only an owner of this Runlight can connect Claude/', $viewer->text());
    }

    public function testAManageGrantNamesOneSiteAndRecordsTheHubsOrigin(): void
    {
        $rl = Make::runlight(['sites' => [['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com']], ['id' => 'b', 'name' => 'Site B', 'hostnames' => ['b.com']]]]);
        $routes = $rl->routes(['token' => 'secret']);
        $owner = ['authorization' => 'Bearer secret'];
        $clientId = Make::body($routes->handle(self::at('https://x.com/runlight/oauth/register', 'POST', ['content-type' => 'application/json'], Json::encode(['client_name' => 'Hub', 'redirect_uris' => ['https://hub.example.net/cb']]))))['client_id'];
        $verifier = self::b64url(random_bytes(32));
        $params = self::form(['response_type' => 'code', 'client_id' => $clientId, 'redirect_uri' => 'https://hub.example.net/cb', 'code_challenge' => OAuth::s256($verifier), 'code_challenge_method' => 'S256', 'scope' => 'read manage', 'site' => 'b']);
        $page = $routes->handle(self::at("https://x.com/runlight/oauth/authorize?$params", 'GET', $owner))->text();
        $this->assertStringContainsString('<option value="b" selected>Site B</option>', $page, 'the site asked for is offered first');
        $this->assertStringNotContainsString('Every site', $page);
        $form = $owner + ['origin' => 'https://x.com', 'content-type' => 'application/x-www-form-urlencoded'];
        $noSite = $routes->handle(self::at('https://x.com/runlight/oauth/authorize', 'POST', $form, str_replace('site=b', 'site=', $params) . '&decision=allow'));
        $this->assertSame('https://hub.example.net/cb?error=invalid_request&error_description=Pick+the+site+to+manage', $noSite->headers->get('location'));
        $allow = $routes->handle(self::at('https://x.com/runlight/oauth/authorize', 'POST', $form, str_replace('site=b', 'site=a', $params) . '&decision=allow'));
        $code = (new Url($allow->headers->get('location') ?? ''))->searchParams()->get('code');
        $issued = Make::body($routes->handle(self::at('https://x.com/runlight/oauth/token', 'POST', ['content-type' => 'application/json'], Json::encode(['grant_type' => 'authorization_code', 'code' => $code, 'client_id' => $clientId, 'redirect_uri' => 'https://hub.example.net/cb', 'code_verifier' => $verifier]))));
        $this->assertSame(['manage', 'a'], [$issued['scope'], $issued['site']]);
        $tokens = Make::body($routes->handle(self::at('https://x.com/runlight/api/tokens', 'GET', $owner)))['tokens'];
        $this->assertSame('https://hub.example.net', $rl->store->setting("token-origin:{$tokens[0]['id']}"));
    }
}
