<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Routes;
use Runlight\Store\Stores;
use Runlight\Tests\Conformance\Player;
use Runlight\Version;

/**
 * routes.test.ts, ported. Each runs on the PHP core when it is here and on the stand-in until then; the few that
 * count visits or change sites in the dashboard wait for the core. Then the unit checks of the routes' own helpers:
 * cookies, bearer tokens, JSON-only writes, and the dashboard's page.
 */
final class RoutesTest extends TestCase
{
    private const CHROME_MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

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

    private static function req(string $path, string $method = 'GET', array $headers = [], ?string $body = null): Request
    {
        return Make::req($path, $method, $headers, $body);
    }

    public function testTheTrackerIsPublicCachedAndAnswers304ToItsEtag(): void
    {
        $routes = Make::runlight()->routes(['token' => 'secret']);
        $first = $routes->handle(self::req('/runlight/s.js'));
        $this->assertSame(200, $first->status);
        $this->assertMatchesRegularExpression('/javascript/', $first->headers->get('content-type') ?? '');
        $this->assertMatchesRegularExpression('/sendBeacon/', $first->text());
        $etag = $first->headers->get('etag') ?? '';
        $this->assertStringStartsWith('"' . Version::build()['trackerHash'] . '-', $etag, 'the etag covers the script and its click rules');
        $again = $routes->handle(self::req('/runlight/s.js', 'GET', ['if-none-match' => $etag]));
        $this->assertSame(304, $again->status);
    }

    public function testStatsNeedTheTokenAsABearerOrThroughTheCookie(): void
    {
        $routes = Make::runlight()->routes(['token' => 'secret']);
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/stats'))->status);
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/stats', 'GET', ['authorization' => 'Bearer wrong']))->status);
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/stats', 'GET', ['authorization' => 'Bearer secret']))->status);

        $signIn = $routes->handle(self::req('/runlight/?token=secret'));
        $this->assertSame(303, $signIn->status);
        $this->assertSame('/runlight/', $signIn->headers->get('location'));
        $cookie = $signIn->headers->get('set-cookie') ?? '';
        $this->assertStringContainsString('HttpOnly', $cookie);
        $this->assertStringContainsString('Secure', $cookie);
        $this->assertStringNotContainsString('secret', $cookie, 'the cookie holds a digest, not the token');
        $value = explode(';', $cookie)[0];
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/stats', 'GET', ['cookie' => $value]))->status);
        $this->assertSame(200, $routes->handle(self::req('/runlight/', 'GET', ['cookie' => $value]))->status);
    }

    public function testWithNoTokenEverythingButDevelopmentRefusesWritesIncluded(): void
    {
        foreach (['production', '', 'staging'] as $value) {
            putenv($value === '' ? 'NODE_ENV' : "NODE_ENV=$value");
            $routes = Make::runlight()->routes([]);
            $this->assertSame(503, $routes->handle(self::req('/runlight/api/stats'))->status, 'NODE_ENV=' . ($value ?: '(unset)'));
            $minted = $routes->handle(self::req('/runlight/api/tokens', 'POST', ['content-type' => 'application/json'], Json::encode(['name' => 'x'])));
            $this->assertSame(503, $minted->status, 'nobody can make a token on an install with no token');
        }
        putenv('NODE_ENV=development');
        $log = ini_set('error_log', '/dev/null');
        try {
            $this->assertSame(200, Make::runlight()->routes([])->handle(self::req('/runlight/api/stats'))->status);
        } finally {
            ini_set('error_log', (string) $log);
            putenv('NODE_ENV');
        }
    }

    public function testAuthorizeReplacesTheToken(): void
    {
        $routes = Make::runlight()->routes(['authorize' => fn (Request $r) => $r->headers->get('x-admin') === 'yes']);
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/sites'))->status);
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/sites', 'GET', ['x-admin' => 'yes']))->status);
    }

    public function testTheElementPickerSendsItsChoiceOnlyToTheDashboardItsTicketNames(): void
    {
        $now = gmmktime(12, 0, 0, 10, 7, 2026) * 1000;
        $rl = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']]], 'now' => function () use (&$now): int {
            return $now;
        }]);
        $routes = $rl->routes(['token' => 'secret']);
        $ask = fn (mixed $body, string $auth = 'secret'): Response => $routes->handle(Make::owner('/runlight/api/pick?site=blog', 'POST', $body, $auth));
        $target = function (string $ticket) use ($routes): ?string {
            $script = $routes->handle(self::req('/runlight/pick.js?runlight=pick&runlight_ticket=' . rawurlencode($ticket)))->text();
            return preg_match('/var \w+="([^"]*)";if\(/', $script, $m) ? $m[1] : null;
        };

        $this->assertSame(401, $ask(['origin' => 'https://stats.example.com'], 'wrong')->status, 'only the owner gets a ticket');
        $this->assertSame(400, $ask(['origin' => 'javascript:alert(1)'])->status);
        $ticket = Make::body($ask(['origin' => 'https://stats.example.com']))['ticket'];
        $this->assertSame('https://stats.example.com', $target($ticket));
        // A page that opens the site some other way has no ticket, or only a changed one, and the picker sends nowhere.
        $this->assertSame('', $target(''));
        $this->assertSame('', $target((string) preg_replace('/\.[a-f0-9]+\./', '.' . bin2hex('https://evil.example') . '.', $ticket, 1)));
        $this->assertSame('no-store', $routes->handle(self::req('/runlight/pick.js'))->headers->get('cache-control'));
        $now += 31 * 60_000;
        $this->assertSame('', $target($ticket), 'a ticket runs out after half an hour');

        // The script also learns the site the ticket is for, and does nothing on any other site's pages.
        $fresh = Make::body($ask(['origin' => 'https://stats.example.com']))['ticket'];
        $script = $routes->handle(self::req('/runlight/pick.js?runlight_ticket=' . rawurlencode($fresh)))->text();
        $this->assertStringContainsString(Json::encode(Json::encode(['blog.example.com'])), $script);
        $this->assertStringNotContainsString('__RUNLIGHT_PICK_HOSTS__', $script);

        // A hub's manage token gets one only for the hub it connected from, recorded when it did.
        $made = Make::body($routes->handle(Make::owner('/runlight/api/tokens', 'POST', ['name' => 'Hub', 'scope' => 'manage', 'site' => 'blog'])));
        $manage = $made['secret'];
        $refused = $ask(['origin' => 'https://hub.example.net'], $manage);
        $this->assertSame(403, $refused->status);
        $this->assertSame('pick_hub', Make::body($refused)['code']);
        $rl->store->setSetting("token-origin:{$made['token']['id']}", 'https://hub.example.net');
        $this->assertSame(403, $ask(['origin' => 'https://evil.example'], $manage)->status, 'never another origin');
        $hub = Make::body($ask(['origin' => 'https://hub.example.net'], $manage))['ticket'];
        $this->assertSame('https://hub.example.net', $target($hub));
    }

    public function testTheCheckEndpointTakesTheCronSecret(): void
    {
        $routes = Make::runlight()->routes(['token' => 'secret', 'cronSecret' => 'cron']);
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/check', 'POST', ['content-type' => 'application/json']))->status);
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/check', 'POST', ['authorization' => 'Bearer cron']))->status);
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/check', 'POST', ['authorization' => 'Bearer secret']))->status);
        $routes = Make::runlight()->routes(['token' => 'secret', 'cronSecret' => 'cron']);
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/check', 'GET', ['authorization' => 'Bearer cron']))->status, 'Vercel Cron sends GET');
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/check'))->status);
    }

    public function testBasePathMovesEverything(): void
    {
        $routes = Make::runlight()->routes(['token' => 'secret', 'basePath' => '/admin/runlight/']);
        $this->assertSame(200, $routes->handle(self::req('/admin/runlight/s.js'))->status);
        $this->assertSame(404, $routes->handle(self::req('/runlight/s.js'))->status);
        $info = Make::body($routes->handle(self::req('/admin/runlight/api')));
        $this->assertSame('runlight', $info['name']);
        $this->assertSame('runlight/runlight', $info['library']);
        $this->assertSame('php', $info['language']);
    }

    public function testBadQueriesAre400sWithAReason(): void
    {
        $routes = Make::runlight()->routes(['token' => null]);
        foreach (['/runlight/api/stats?period=forever', '/runlight/api/stats?filter=nope', '/runlight/api/stats?filter=page:like:x', '/runlight/api/breakdown?dimension=shoe_size'] as $path) {
            $response = $routes->handle(self::req($path));
            $this->assertSame(400, $response->status, $path);
            $this->assertNotEmpty(Make::body($response)['error']);
        }
    }

    public function testTheDashboardPageLoadsItsHashedAssetsUnderAStrictCsp(): void
    {
        $hash = Version::build()['dashboardHash'];
        $locales = Version::build()['localesHash'];
        $routes = Make::runlight()->routes(['token' => 'secret', 'basePath' => '/admin/runlight']);
        $page = $routes->handle(self::req('/admin/runlight/'));
        $this->assertSame(200, $page->status, 'the shell holds no data, so it loads signed out');
        $this->assertMatchesRegularExpression("/script-src 'self'/", $page->headers->get('content-security-policy') ?? '');
        $html = $page->text();
        $this->assertStringContainsString("/admin/runlight/assets/app.$hash.js", $html);
        $this->assertStringContainsString('data-base="/admin/runlight"', $html);
        $js = $routes->handle(self::req("/admin/runlight/assets/app.$hash.js"));
        $this->assertSame(200, $js->status);
        $this->assertMatchesRegularExpression('/immutable/', $js->headers->get('cache-control') ?? '');
        $this->assertSame(200, $routes->handle(self::req("/admin/runlight/assets/app.$hash.css"))->status);
        $this->assertSame(404, $routes->handle(self::req('/admin/runlight/assets/app.old.js'))->status);
        $this->assertStringContainsString("/admin/runlight/assets/locale.fr.$locales.json", $html, 'the page lists its languages');
        $french = $routes->handle(self::req("/admin/runlight/assets/locale.fr.$locales.json"));
        $this->assertSame(200, $french->status);
        $this->assertSame('Filtrer', Make::body($french)['filter.button']);
        $this->assertSame(404, $routes->handle(self::req("/admin/runlight/assets/locale.xx.$locales.json"))->status);
        $this->assertSame(401, $routes->handle(self::req('/admin/runlight/api/stats'))->status, 'the data stays behind the token');
    }

    public function testASitesNameAndTimezoneCanBeChangedAndSurviveARestart(): void
    {
        Make::needsCore($this);
        $store = Stores::sqlite(':memory:');
        $first = Make::runlight(['store' => $store, 'site' => ['name' => 'From code', 'timezone' => 'UTC']]);
        $routes = $first->routes(['token' => null]);
        $patch = fn (mixed $body, string $type = 'application/json'): Response => $routes->handle(self::req('/runlight/api/sites/default', 'PATCH', ['content-type' => $type], Json::encode($body)));
        $this->assertSame(200, $patch(['name' => "Jon's site", 'timezone' => 'America/Toronto'])->status);
        $this->assertSame(400, $patch(['timezone' => 'Mars/Olympus'])->status);
        $this->assertSame(400, $patch(['name' => ''])->status);
        $this->assertSame(415, $patch(['name' => 'x'], 'text/plain')->status);
        $this->assertSame(404, $routes->handle(self::req('/runlight/api/sites/nope', 'PATCH', ['content-type' => 'application/json'], '{}'))->status);
        $listed = Make::body($routes->handle(self::req('/runlight/api/sites')));
        $this->assertSame("Jon's site", $listed['sites'][0]['name']);
        $this->assertNull($listed['sites'][0]['lastSeen']);

        // Code still says "From code"; the dashboard's change wins after a restart.
        $again = Make::runlight(['store' => $store, 'site' => ['name' => 'From code', 'timezone' => 'UTC']]);
        $again->init();
        $this->assertSame("Jon's site", $again->site('default')['name']);
        $this->assertSame('America/Toronto', $again->site('default')['timezone']);
    }

    public function testAShareReadsOneSitesReportsAndNothingElseUntilItIsDeleted(): void
    {
        $rl = Make::runlight(['sites' => [
            ['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com'], 'timezone' => 'UTC'],
            ['id' => 'b', 'name' => 'Site B', 'hostnames' => ['b.com'], 'timezone' => 'UTC'],
        ]]);
        $routes = $rl->routes(['token' => 'secret']);

        $this->assertSame(401, $routes->handle(self::req('/runlight/api/shares?site=a', 'POST', ['content-type' => 'application/json'], '{}'))->status);
        $made = $routes->handle(Make::owner('/runlight/api/shares?site=a', 'POST', ['name' => 'Client']));
        $this->assertSame(201, $made->status);
        $share = Make::body($made)['share'];
        $this->assertMatchesRegularExpression('/^[a-f0-9]{32}$/', $share['id']);
        $this->assertSame("/runlight/share/{$share['id']}", $share['path']);

        $page = $routes->handle(self::req($share['path']));
        $this->assertSame(200, $page->status);
        $this->assertStringContainsString("data-share=\"{$share['id']}\"", $page->text());
        $this->assertSame('no-referrer', $page->headers->get('referrer-policy'));

        $as = ['x-runlight-share' => $share['id']];
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/stats?site=b', 'GET', $as))->status);
        $this->assertSame('a', Make::body($routes->handle(self::req('/runlight/api/stats?site=b', 'GET', $as)))['site'], 'a share is pinned to its own site whatever is asked');
        $sites = Make::body($routes->handle(self::req('/runlight/api/sites', 'GET', $as)));
        $this->assertSame([['a', []]], array_map(fn (array $s) => [$s['id'], $s['hostnames']], $sites['sites']));
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/links?site=a', 'GET', $as))->status, 'links need the token');
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/shares?site=a', 'GET', $as))->status, 'a share cannot list shares');
        $this->assertSame(404, $routes->handle(self::req('/runlight/api/stats', 'GET', ['x-runlight-share' => str_repeat('0', 32)]))->status);

        $renamed = $routes->handle(Make::owner("/runlight/api/shares/{$share['id']}?site=a", 'PATCH', ['name' => 'Board']));
        $this->assertSame('Board', Make::body($renamed)['share']['name']);
        $this->assertSame(404, $routes->handle(Make::owner("/runlight/api/shares/{$share['id']}?site=b", 'DELETE'))->status, 'only from its own site');
        $this->assertSame(200, $routes->handle(Make::owner("/runlight/api/shares/{$share['id']}?site=a", 'DELETE'))->status);
        $this->assertSame(404, $routes->handle(self::req('/runlight/api/stats', 'GET', $as))->status);
        $this->assertSame(404, $routes->handle(self::req($share['path']))->status);
    }

    public function testTheDashboardInsideACmsOpensOneFramedPageOnceWhoseSessionReadsOneSite(): void
    {
        Make::needsCore($this);
        $rl = Make::runlight(['sites' => [
            ['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com'], 'timezone' => 'UTC'],
            ['id' => 'b', 'name' => 'Site B', 'hostnames' => ['b.com'], 'timezone' => 'UTC'],
        ]]);
        $routes = $rl->routes(['token' => 'secret']);
        $made = Make::body($routes->handle(Make::owner('/runlight/api/tokens', 'POST', ['name' => 'CMS', 'site' => 'a', 'scope' => 'embed'])));
        $mint = fn (string $origin): Response => $routes->handle(Make::owner('/runlight/api/embed', 'POST', ['origin' => $origin], $made['secret']));
        $this->assertSame(400, $mint('https://b.com')->status, "only an origin on the site's own domains");
        $minted = $mint('https://www.a.com');
        $this->assertSame(201, $minted->status);
        ['ticket' => $ticket, 'path' => $path, 'site' => $site] = Make::body($minted);
        $this->assertSame('a', $site);
        $this->assertSame("/runlight/embed?ticket=$ticket", $path);
        $this->assertStringNotContainsString($made['token']['id'], $ticket, 'a ticket never names its token');

        $page = $routes->handle(self::req($path));
        $this->assertSame(200, $page->status);
        $this->assertStringEndsWith('frame-ancestors https://www.a.com', (string) $page->headers->get('content-security-policy'));
        $this->assertNull($page->headers->get('x-frame-options'));
        $this->assertSame('no-referrer', $page->headers->get('referrer-policy'));
        $this->assertSame(1, preg_match('/data-embed="([^"]+)"/', $page->text(), $found));
        $session = $found[1];
        $this->assertMatchesRegularExpression('/^\d+\.[a-f0-9]{24}\.[a-f0-9]{64}$/', $session);
        $again = $routes->handle(self::req($path));
        $this->assertSame(410, $again->status, 'a ticket works once');
        $this->assertStringEndsWith('frame-ancestors https://www.a.com', (string) $again->headers->get('content-security-policy'), 'a used ticket still says so inside its frame');

        $as = ['x-runlight-embed' => $session];
        $this->assertSame('a', Make::body($routes->handle(self::req('/runlight/api/stats?site=b', 'GET', $as)))['site'], "pinned to its token's site whatever is asked");
        $this->assertSame(403, $routes->handle(self::req('/runlight/api/links?site=a', 'GET', $as + ['authorization' => 'Bearer secret']))->status, 'nothing a share cannot read, even beside the owner\'s token');
        $this->assertSame('DENY', $routes->handle(self::req('/runlight/'))->headers->get('x-frame-options'), 'every other page still refuses to be framed');

        $this->assertSame(200, $routes->handle(Make::owner("/runlight/api/tokens/{$made['token']['id']}", 'DELETE'))->status);
        $this->assertSame(401, $routes->handle(self::req('/runlight/api/stats', 'GET', $as))->status, 'deleting the token ends its sessions at once');
    }

    public function testASettingCanBeTakenOnce(): void
    {
        Make::needsCore($this);
        $rl = Make::runlight(['site' => ['hostnames' => ['a.com']]]);
        $rl->init();
        $rl->store->setSetting('x', '1');
        $this->assertSame('1', $rl->store->takeSetting('x'));
        $this->assertNull($rl->store->takeSetting('x'));
        $this->assertNull($rl->store->setting('x'));
    }

    public function testACmsPluginReportsAiAgentFetchesWithItsOwnKeyWhichReadsNothing(): void
    {
        Make::needsCore($this);
        $rl = Make::runlight(['site' => ['hostnames' => ['blog.example.com']]]);
        $routes = $rl->routes(['token' => 'secret', 'observeKey' => 'agents']);
        $send = fn (string $key, mixed $body): Response => $routes->handle(Make::owner('/runlight/api/observe', 'POST', $body, $key));
        $gpt = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot';
        $this->assertSame(401, $send('wrong', ['url' => 'https://blog.example.com/post', 'userAgent' => $gpt])->status);
        $this->assertSame(400, $send('agents', ['url' => 'not a url', 'userAgent' => $gpt])->status);
        $this->assertSame(204, $send('agents', ['url' => 'https://blog.example.com/post', 'userAgent' => $gpt])->status);
        $this->assertSame(204, $send('agents', ['url' => 'https://blog.example.com/style.css', 'userAgent' => $gpt])->status, 'assets are ignored, quietly');
        $this->assertSame(204, $send('agents', ['url' => 'https://elsewhere.example/post', 'userAgent' => $gpt])->status, 'other sites are ignored, quietly');
        $this->assertSame(401, $routes->handle(Make::owner('/runlight/api/stats', 'GET', null, 'agents'))->status, 'the observe key reads nothing');
        $rows = Make::body($routes->handle(Make::owner('/runlight/api/breakdown?period=today&dimension=ai_page')));
        $this->assertSame(['/post'], array_column($rows['rows'], 'value'));
    }

    public function testAGoneShareLinkSaysSoInTheVisitorsLanguageAndAReadTokensWriteIsRefusedWithACode(): void
    {
        $rl = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']]]]);
        $routes = $rl->routes(['token' => 'secret']);
        $gone = $routes->handle(self::req('/runlight/share/' . str_repeat('a', 32), 'GET', ['accept-language' => 'fr-CA,fr;q=0.9,en;q=0.8']));
        $this->assertSame(404, $gone->status);
        $this->assertMatchesRegularExpression('/^text\/html/', $gone->headers->get('content-type') ?? '');
        $page = $gone->text();
        $this->assertStringContainsString('<html lang="fr">', $page);
        $this->assertStringContainsString('Ce lien de partage ne fonctionne plus', $page);
        $this->assertStringContainsString('This share link no longer works', $routes->handle(self::req('/runlight/share/' . str_repeat('a', 32)))->text());

        $read = Make::body($routes->handle(Make::owner('/runlight/api/tokens', 'POST', ['name' => 'Script'])))['secret'];
        $write = $routes->handle(Make::owner('/runlight/api/goals?site=blog', 'POST', ['name' => 'X', 'kind' => 'event', 'match' => 'X'], $read));
        $this->assertSame(403, $write->status);
        $this->assertSame('token_read_only', Make::body($write)['code']);
    }

    public function testGoalFunnelSiteAndAssistantRefusalsCarryTheirOwnCodesAndParams(): void
    {
        Make::needsCore($this);
        $rl = Make::runlight(['managedSites' => true]);
        $routes = $rl->routes(['token' => 'secret']);
        $send = function (string $method, string $path, mixed $body) use ($routes): array {
            $json = Make::body($routes->handle(Make::owner("/runlight$path", $method, $body)));
            return ['code' => $json['code'] ?? null, 'params' => $json['params'] ?? null];
        };
        $this->assertSame(['code' => 'site_domain_invalid', 'params' => ['host' => 'nope']], $send('POST', '/api/sites', ['name' => 'Blog', 'hostnames' => 'nope']));
        $send('POST', '/api/sites', ['name' => 'Blog', 'hostnames' => 'blog.example.com']);
        $this->assertSame(['code' => 'site_domain_taken', 'params' => ['host' => 'blog.example.com', 'site' => 'Blog']], $send('POST', '/api/sites', ['name' => 'Again', 'hostnames' => 'blog.example.com']));
        $send('POST', '/api/goals?site=blog.example.com', ['name' => 'Signup', 'kind' => 'event', 'match' => 'Signup']);
        $this->assertSame(['code' => 'goal_exists', 'params' => ['name' => 'signup']], $send('POST', '/api/goals?site=blog.example.com', ['name' => 'signup', 'kind' => 'event', 'match' => 'x']));
        $this->assertSame(['code' => 'funnel_short', 'params' => []], $send('POST', '/api/funnels?site=blog.example.com', ['name' => 'F', 'steps' => [['kind' => 'page', 'match' => '/']]]));
        $this->assertSame(['code' => 'assistant_provider', 'params' => []], $send('PUT', '/api/assistant', ['provider' => 'nope']));
    }

    // The routes' own helpers.

    public function testCookiesAreReadByNameWithEqualsSignsKeptInTheirValues(): void
    {
        $request = self::req('/', 'GET', ['cookie' => 'a=1; runlight_token=x=y=z ;  other=2']);
        $this->assertSame('x=y=z', Routes::readCookie($request, 'runlight_token'));
        $this->assertSame('2', Routes::readCookie($request, 'other'));
        $this->assertSame('', Routes::readCookie($request, 'missing'));
        $this->assertSame('', Routes::readCookie(self::req('/'), 'a'));
        $this->assertSame(hash('sha256', 'runlight-cookie:secret'), Routes::cookieValue('secret'));
    }

    public function testBearerTokensAreReadWhateverTheSchemesCase(): void
    {
        $this->assertSame('abc', Routes::bearer(self::req('/', 'GET', ['authorization' => 'Bearer abc'])));
        $this->assertSame('abc', Routes::bearer(self::req('/', 'GET', ['authorization' => 'bEaReR   abc  '])));
        $this->assertSame('', Routes::bearer(self::req('/', 'GET', ['authorization' => 'Basic abc'])));
        $this->assertSame('', Routes::bearer(self::req('/')));
    }

    public function testOnlyAJsonMediaTypeCountsAsJson(): void
    {
        foreach (['application/json' => true, 'Application/JSON; charset=utf-8' => true, ' application/json ' => true, 'text/plain; application/json' => false, 'application/json-patch+json' => false, 'text/plain;charset=UTF-8' => false] as $type => $want) {
            $this->assertSame($want, Routes::isJson(self::req('/', 'POST', ['content-type' => $type], '{}')), $type);
        }
        $this->assertFalse(Routes::isJson(self::req('/', 'POST')));
    }

    public function testWritesMustBeJsonUnlessABearerTokenIsSent(): void
    {
        $routes = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']]]])->routes(['token' => null]);
        // A form from another page cannot send JSON, so a cookie or an open install never lets it write.
        foreach (['POST' => '/runlight/api/goals?site=blog', 'PUT' => '/runlight/api/mail', 'PATCH' => '/runlight/api/sites/blog'] as $method => $path) {
            $answer = $routes->handle(self::req($path, $method, ['content-type' => 'application/x-www-form-urlencoded'], 'name=x'));
            $this->assertSame(415, $answer->status, "$method $path");
            $this->assertSame(['error' => 'Send JSON', 'code' => 'send_json'], Make::body($answer));
        }
        $this->assertSame(415, $routes->handle(self::req('/runlight/api/check', 'POST'))->status, 'even a write with no body');
        $this->assertSame(200, $routes->handle(self::req('/runlight/api/check', 'POST', ['authorization' => 'Bearer x']))->status, 'a bearer token is never sent by a browser on its own');
        $this->assertSame(404, $routes->handle(self::req('/runlight/api/goals/nope?site=blog', 'DELETE'))->status, 'a DELETE carries no body to check');
    }

    public function testErrorsAreJsonWithTheirCodeAndNeverSniffed(): void
    {
        $answer = Routes::coded('Unknown site', 'unknown_site', 404);
        $this->assertSame('{"error":"Unknown site","code":"unknown_site"}', $answer->text());
        $this->assertSame('nosniff', $answer->headers->get('x-content-type-options'));
        $this->assertSame('{"error":"x","code":"y","params":{}}', Routes::coded('x', 'y', 400, [])->text(), 'empty params are an object');
        $this->assertSame('private, max-age=3600', Routes::coded('No icon', 'icon_none', 404, null, ['cache-control' => 'private, max-age=3600'])->headers->get('cache-control'));
    }

    public function testAnErrorInsideARouteIsAnInternalErrorThatSaysNothingMore(): void
    {
        $routes = Make::runlight(['sites' => [['id' => 'blog', 'hostnames' => ['blog.example.com']]]])->routes(['token' => null]);
        $log = ini_set('error_log', '/dev/null');
        try {
            // A broken escape in a path makes decodeURIComponent throw, as it does in TypeScript.
            $answer = $routes->handle(self::req('/runlight/api/goals/%E0%A4%A?site=blog', 'DELETE'));
        } finally {
            ini_set('error_log', (string) $log);
        }
        $this->assertSame(500, $answer->status);
        $this->assertSame(['error' => 'Internal error', 'code' => 'internal'], Make::body($answer));
    }

    public function testTheDashboardShellEscapesWhatItIsGiven(): void
    {
        $html = Routes::dashboard('/a"b', 'share<', '/out?x=1&y=2', true, true, '/in');
        $this->assertStringContainsString('data-base="/a&#34;b"', $html);
        $this->assertStringContainsString('data-share="share&#60;"', $html);
        $this->assertStringContainsString('data-sign-out="/out?x=1&#38;y=2"', $html);
        $this->assertStringContainsString('data-sign-in="/in" data-geo-credit="" data-accounts=""', $html);
        $this->assertStringNotContainsString('data-share', Routes::dashboard('/runlight'));
    }
}
