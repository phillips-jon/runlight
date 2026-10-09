<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Http\Request;
use Runlight\OAuth;
use Runlight\Routes;
use Runlight\Tests\Conformance\Player;
use Runlight\Tests\Fixtures;

/**
 * Replays tests/fixtures/routes.json, which scripts/php-fixtures-routes.mts writes from the TypeScript SDK: the
 * dashboard's page, the tracker, refusals with their codes, and OAuth's documents, each answer byte for byte with
 * every header, and the helpers routes.ts and oauth.ts export.
 */
final class RoutesFixtureTest extends TestCase
{
    /** @var array<string, array{env: string|false, _ENV: ?string, _SERVER: ?string, inEnv: bool, inServer: bool}> */
    private array $env = [];

    protected function setUp(): void
    {
        $this->env = Player::clearEnv();
    }

    protected function tearDown(): void
    {
        Player::restoreEnv($this->env);
    }

    /** @return iterable<string, array{int}> */
    public static function exchanges(): iterable
    {
        foreach (Fixtures::load('routes', true)['exchanges'] as $i => $exchange) {
            yield $exchange['name'] => [$i];
        }
    }

    #[DataProvider('exchanges')]
    public function testAnswersAsTheTypeScriptDoes(int $index): void
    {
        $fixture = Fixtures::load('routes', true);
        $exchange = $fixture['exchanges'][$index];
        $now = $fixture['now'];
        $rl = Make::runlight($exchange['runlight'] + ['now' => fn (): int => $now]);
        $routes = $rl->routes($exchange['routes']);
        foreach ($exchange['answers'] as $answer) {
            $ask = $answer['ask'];
            $label = ($ask['method'] ?? 'GET') . ' ' . $ask['path'];
            $headers = array_change_key_case($ask['headers'] ?? []);
            if (isset($ask['body']) && !isset($headers['content-type'])) {
                $headers['content-type'] = Player::TEXT_BODY_TYPE;
            }
            $response = $routes->handle(new Request('https://example.com' . $ask['path'], $ask['method'] ?? 'GET', $headers, $ask['body'] ?? ''));
            $this->assertSame($answer['status'], $response->status, "$label: status");
            $got = [];
            foreach ($response->headers->all() as $name => $values) {
                $got[$name] = $name === 'set-cookie' ? $values : implode(', ', $values);
            }
            ksort($got);
            $want = $answer['headers'];
            ksort($want);
            $this->assertSame($want, $got, "$label: headers");
            $body = $response->text();
            if (isset($answer['sha256'])) {
                $this->assertSame($answer['sha256'], hash('sha256', $body), "$label: body");
            } else {
                $this->assertSame($answer['text'], $body, "$label: body");
            }
        }
    }

    public function testCodedErrorsAreTheSameBytes(): void
    {
        foreach (Fixtures::load('routes', true)['coded'] as $case) {
            [$error, $code, $status, $params, $headers] = $case['args'];
            $response = Routes::coded($error, $code, $status, $params, $headers);
            $this->assertSame($case['status'], $response->status);
            $this->assertSame($case['text'], $response->text(), $code);
            $got = array_map(fn (array $v) => implode(', ', $v), $response->headers->all());
            ksort($got);
            $want = $case['headers'];
            ksort($want);
            $this->assertSame($want, $got, $code);
        }
    }

    public function testHostNamesAreBareAsTheTypeScriptMakesThem(): void
    {
        foreach (Fixtures::load('routes', true)['hostName'] as [$given, $want]) {
            $this->assertSame($want, Routes::hostName($given), $given);
        }
    }

    public function testManagePathsAreTheSame(): void
    {
        foreach (Fixtures::load('routes', true)['managePath'] as [$method, $path, $want]) {
            $this->assertSame($want, Routes::managePath($method, $path), "$method $path");
        }
    }

    public function testPkceS256MatchesTheTypeScript(): void
    {
        foreach (Fixtures::load('routes', true)['s256'] as [$verifier, $want]) {
            $this->assertSame($want, OAuth::s256($verifier), $verifier);
        }
        // RFC 7636's own example.
        $this->assertSame('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', OAuth::s256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'));
    }

    public function testResourceMetadataUrl(): void
    {
        foreach (Fixtures::load('routes', true)['resourceMetadataUrl'] as [$origin, $base, $want]) {
            $this->assertSame($want, OAuth::resourceMetadataUrl($origin, $base));
        }
    }
}
