<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Mcp;
use Runlight\Tests\Conformance\Player;
use Runlight\Tests\Store\Databases;

/**
 * mcp.test.ts, ported: API tokens and the MCP server through the routes, on every store. They count visits
 * first, so they wait for the PHP core.
 */
final class McpTest extends TestCase
{
    private const CHROME_MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
    private const SITES = [
        ['id' => 'a', 'name' => 'Site A', 'hostnames' => ['a.com'], 'timezone' => 'UTC'],
        ['id' => 'b', 'name' => 'Site B', 'hostnames' => ['b.com'], 'timezone' => 'UTC'],
    ];

    /** @var array<string, mixed> */
    private array $env = [];
    private int $now = 0;

    protected function setUp(): void
    {
        Make::needsCore($this);
        $this->env = Player::clearEnv();
        $this->now = gmmktime(12, 0, 0, 10, 6, 2026) * 1000;
    }

    protected function tearDown(): void
    {
        Player::restoreEnv($this->env);
        Databases::cleanup();
    }

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    /** A Runlight on a fresh store of this kind, its routes with the token "secret", and a way to send tracker hits. */
    private function make(string $kind): array
    {
        $rl = Make::runlight(['store' => Databases::fresh($kind), 'sites' => self::SITES, 'now' => fn (): int => $this->now]);
        $routes = $rl->routes(['token' => 'secret']);
        $send = function (array $body, string $ip = '203.0.113.1') use ($routes): void {
            $answer = $routes->handle(new Request('https://example.com/runlight/e', 'POST', ['user-agent' => self::CHROME_MAC, 'x-forwarded-for' => $ip, 'content-type' => 'text/plain;charset=UTF-8'], Json::encode($body)));
            if ($answer->status !== 202) {
                throw new \RuntimeException("collect answered {$answer->status}");
            }
        };
        return [$rl, $routes, $send];
    }

    #[DataProvider('kinds')]
    public function testApiTokensReadCannotWriteCanBeLimitedToASiteAndStopAtRevocation(string $kind): void
    {
        [, $routes, $send] = $this->make($kind);
        $make = function (mixed $body) use ($routes): array {
            $answer = $routes->handle(Make::owner('/runlight/api/tokens', 'POST', $body));
            return ['status' => $answer->status, 'body' => Make::body($answer)];
        };
        $this->assertSame(400, $make(['name' => ''])['status']);
        $this->assertSame(404, $make(['name' => 'X', 'site' => 'nope'])['status']);
        $all = $make(['name' => 'Claude']);
        $this->assertSame(201, $all['status']);
        $this->assertMatchesRegularExpression('/^rl_[a-f0-9]{40}$/', $all['body']['secret']);
        $this->assertSame(substr($all['body']['secret'], -4), $all['body']['token']['hint']);
        $one = $make(['name' => 'Client B', 'site' => 'b'])['body'];

        $listedAnswer = $routes->handle(Make::owner('/runlight/api/tokens'));
        $listed = Make::body($listedAnswer);
        $names = array_column($listed['tokens'], 'name');
        sort($names);
        $this->assertSame(['Claude', 'Client B'], $names);
        $this->assertStringNotContainsString($all['body']['secret'], $listedAnswer->text(), 'a token is shown once, never listed');
        $this->assertArrayNotHasKey('hash', $listed['tokens'][0], 'nor its hash');

        $send(['k' => 'pageview', 'u' => 'https://a.com/', 'i' => 'p1']);
        $send(['k' => 'pageview', 'u' => 'https://b.com/', 'i' => 'p2'], '203.0.113.2');

        $as = fn (string $path, string $secret, string $method = 'GET', mixed $body = null): Response => $routes->handle(Make::owner("/runlight$path", $method, $body, $secret));
        $stats = $as('/api/stats?site=a&period=today', $all['body']['secret']);
        $this->assertSame(200, $stats->status);
        $this->assertSame(1, Make::body($stats)['stats']['visitors']);
        $this->assertSame(200, $as('/api/links?site=a', $all['body']['secret'])->status, 'links can be read');

        // Nothing that writes, and nothing that manages access.
        $this->assertSame(403, $as('/api/goals?site=a', $all['body']['secret'], 'POST', ['name' => 'G', 'kind' => 'page', 'match' => '/'])->status);
        $this->assertSame(403, $as('/api/links?site=a', $all['body']['secret'], 'POST', ['url' => 'https://x.com'])->status);
        $this->assertSame(401, $as('/api/tokens', $all['body']['secret'])->status, 'a token cannot list tokens');
        $this->assertSame(401, $as('/api/shares?site=a', $all['body']['secret'])->status);
        $this->assertSame(401, $as('/api/mail', $all['body']['secret'])->status);

        // A site's token sees only that site.
        $this->assertSame(['b'], array_column(Make::body($as('/api/sites', $one['secret']))['sites'], 'id'));
        $this->assertSame('b', Make::body($as('/api/stats?period=today', $one['secret']))['site'], 'and defaults to it');
        $this->assertSame(404, $as('/api/stats?site=a', $one['secret'])->status);
        $this->assertSame(404, $as('/api/links?site=a', $one['secret'])->status);

        $used = Make::body($routes->handle(Make::owner('/runlight/api/tokens')));
        foreach ($used['tokens'] as $token) {
            if ($token['name'] === 'Claude') {
                $this->assertSame($this->now, $token['lastUsedAt']);
            }
        }

        $id = $all['body']['token']['id'];
        $this->assertSame(403, $as("/api/tokens/$id", $all['body']['secret'], 'DELETE')->status, 'a token cannot revoke');
        $this->assertSame(200, $routes->handle(Make::owner("/runlight/api/tokens/$id", 'DELETE'))->status);
        $this->assertSame(404, $routes->handle(Make::owner("/runlight/api/tokens/$id", 'DELETE'))->status);
        $this->assertSame(401, $as('/api/stats?site=a', $all['body']['secret'])->status, 'revoked at once');
    }

    #[DataProvider('kinds')]
    public function testTheMcpServerAnswersInitializeListsItsToolsAndCallsThemWithTheTokensReach(string $kind): void
    {
        [, $routes, $send] = $this->make($kind);
        $secret = Make::body($routes->handle(Make::owner('/runlight/api/tokens', 'POST', ['name' => 'B only', 'site' => 'b'])))['secret'];
        $send(['k' => 'pageview', 'u' => 'https://b.com/pricing', 'r' => 'https://news.ycombinator.com/', 'i' => 'p1']);
        $send(['k' => 'pageview', 'u' => 'https://a.com/', 'i' => 'p2']);

        $id = 0;
        $rpc = function (string $method, mixed $params = null, ?string $auth = null) use ($routes, $secret, &$id): array {
            $message = ['jsonrpc' => '2.0', 'id' => ++$id, 'method' => $method] + ($params !== null ? ['params' => $params] : []);
            $answer = $routes->handle(new Request('https://example.com/runlight/mcp', 'POST', ['authorization' => 'Bearer ' . ($auth ?? $secret), 'content-type' => 'application/json', 'accept' => 'application/json, text/event-stream'], Json::encode($message)));
            return ['status' => $answer->status, 'headers' => $answer->headers, 'body' => $answer->status === 202 ? null : Make::body($answer)];
        };

        $refused = $rpc('initialize', Json::object(), 'rl_' . str_repeat('0', 40));
        $this->assertSame(401, $refused['status']);
        $this->assertMatchesRegularExpression('/^Bearer/', $refused['headers']->get('www-authenticate') ?? '');
        $this->assertSame(405, $routes->handle(Make::owner('/runlight/mcp'))->status, 'no event stream');

        $init = $rpc('initialize', ['protocolVersion' => '2025-06-18', 'capabilities' => Json::object(), 'clientInfo' => ['name' => 'test', 'version' => '1']]);
        $this->assertSame('2025-06-18', $init['body']['result']['protocolVersion']);
        $this->assertSame('runlight', $init['body']['result']['serverInfo']['name']);
        $this->assertArrayHasKey('tools', $init['body']['result']['capabilities']);
        $this->assertSame('2025-11-25', $rpc('initialize', ['protocolVersion' => '1999-01-01'])['body']['result']['protocolVersion'], 'an unknown version gets the newest');

        $note = $routes->handle(new Request('https://example.com/runlight/mcp', 'POST', ['authorization' => "Bearer $secret", 'content-type' => 'application/json'], Json::encode(['jsonrpc' => '2.0', 'method' => 'notifications/initialized'])));
        $this->assertSame(202, $note->status);

        $listed = $rpc('tools/list');
        $this->assertSame(array_column(Mcp::tools(), 'name'), array_column($listed['body']['result']['tools'], 'name'));
        foreach ($listed['body']['result']['tools'] as $tool) {
            $this->assertTrue($tool['annotations']['readOnlyHint']);
        }

        $call = function (string $name, mixed $args = null) use ($rpc): array {
            $result = $rpc('tools/call', ['name' => $name, 'arguments' => $args ?? Json::object()])['body']['result'];
            return $result + ['data' => !empty($result['isError']) ? null : Json::decode($result['content'][0]['text'], true)];
        };
        $this->assertSame(['b'], array_column($call('list_sites')['data']['sites'], 'id'));
        $stats = $call('get_stats', ['period' => 'today']);
        $this->assertSame('b', $stats['data']['site']);
        $this->assertSame(1, $stats['data']['stats']['pageviews']);
        $this->assertTrue($call('get_stats', ['site' => 'a'])['isError'], 'another site is out of reach');
        $sources = $call('get_breakdown', ['period' => 'today', 'dimension' => 'source', 'limit' => 500]);
        $this->assertSame('Hacker News', $sources['data']['rows'][0]['value']);
        $this->assertSame(0, $call('get_stats', ['period' => 'today', 'filters' => ['page:is:/nowhere']])['data']['stats']['pageviews']);
        $bad = $call('get_stats', ['filters' => ['nonsense']]);
        $this->assertTrue($bad['isError']);
        $this->assertMatchesRegularExpression('/Bad filter/', $bad['content'][0]['text']);
        $times = $call('get_visit_times', ['period' => 'today']);
        $this->assertCount(7, $times['data']['grid']);
        $this->assertArrayNotHasKey('cells', $times['data'], 'trimmed to what an assistant needs');
        $this->assertCount(0, $call('list_goals', ['period' => 'today'])['data']['goals']);
        $this->assertTrue($call('get_goal', ['goal_id' => str_repeat('f', 24)])['isError']);
        $this->assertArrayNotHasKey('isError', $call('list_links'));
        $this->assertArrayNotHasKey('isError', $call('get_realtime'));

        $this->assertSame(-32602, $rpc('tools/call', ['name' => 'drop_tables'])['body']['error']['code']);
        $this->assertSame(-32601, $rpc('resources/list')['body']['error']['code']);
        $this->assertSame([], $rpc('ping')['body']['result']);

        // The owner's own token works too, across every site.
        $all = $rpc('tools/call', ['name' => 'list_sites', 'arguments' => Json::object()], 'secret');
        $this->assertSame(['a', 'b'], array_column(Json::decode($all['body']['result']['content'][0]['text'], true)['sites'], 'id'));
    }
}
