<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Accounts\Crypto;
use Runlight\Env;
use Runlight\Http\FetchError;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Json;
use Runlight\Tests\Conformance\Fake\ReplayTarget;
use Runlight\Tests\Conformance\Fake\ScriptedTarget;

/** The runner itself, proved before the PHP core exists. */
final class PlayerTest extends TestCase
{
    private const KEY = 'rl_ABCDEFGHJKMNPQRSTVWXYZ12';
    private const HEX24 = '0123456789abcdef01234567';
    private const HEX32 = '0123456789abcdef0123456789abcdef';
    private const SECRET = 'JBSWY3DPEHPK3PXP';
    private const START = 1_700_000_000_000;

    public function testTheFormatIsTheOneThisRunnerReads(): void
    {
        $this->assertSame(
            Player::FORMAT_SHA256,
            hash('sha256', Scenarios::file()->description),
            "conformance/http.json describes its format differently now. Read the change, port it to Player, then update FORMAT_SHA256.",
        );
    }

    /** @return iterable<string, array{string}> */
    public static function scenarios(): iterable
    {
        foreach (Scenarios::all() as $scenario) {
            yield $scenario->name => [$scenario->name];
        }
    }

    /**
     * A fake that answers every step with the expected answer, its placeholders filled with fresh values,
     * must come out of the runner as exactly the expected answers again.
     */
    #[DataProvider('scenarios')]
    public function testReplaysEveryScenarioThroughAFake(string $name): void
    {
        $scenario = Scenarios::named($name);
        $fake = null;
        $saved = $this->setEnv();
        try {
            $answers = (new Player())->play($scenario, function (array $runlight, array $routes) use ($scenario, &$fake) {
                return $fake = new ReplayTarget($scenario, $runlight, $routes);
            }, 'a store');
            $this->assertEnvRestored();
        } finally {
            Player::restoreEnv($saved);
        }
        ConformanceTest::assertAnswers($scenario, $answers);
        $this->assertSame(count($scenario->steps), $fake->idled, 'idle() runs after every step');
        $this->assertSame('a store', $fake->runlightOptions['store']);
    }

    public function testMapsTheScenarioOptions(): void
    {
        $scenario = Json::decode('{"site":{"hostnames":["a.com"],"timezone":"UTC"},"token":null,"options":{"secret":"s","rateLimit":false,"accounts":true,"origin":"https://o.example","observeKey":"k","cronSecret":"c"}}');
        $this->assertSame(['site' => ['hostnames' => ['a.com'], 'timezone' => 'UTC'], 'secret' => 's', 'rateLimit' => false], Player::runlightOptions($scenario));
        $this->assertSame(['token' => null, 'observeKey' => 'k', 'cronSecret' => 'c', 'accounts' => true, 'origin' => 'https://o.example'], Player::routesOptions($scenario));

        $scenario = Json::decode('{"site":{"hostnames":[],"timezone":"UTC"},"sites":[{"id":"a","hostnames":["a.com"],"timezone":"Europe/Paris","name":"A"}],"token":""}');
        $this->assertSame(['sites' => [['id' => 'a', 'hostnames' => ['a.com'], 'timezone' => 'Europe/Paris', 'name' => 'A']]], Player::runlightOptions($scenario));
        $this->assertSame(['token' => '', 'observeKey' => '', 'cronSecret' => ''], Player::routesOptions($scenario));

        $scenario = Json::decode('{"site":{"hostnames":[],"timezone":"UTC"},"sites":[],"token":"t","options":{"managedSites":true,"rateLimit":4}}');
        $this->assertSame(['managedSites' => true, 'rateLimit' => 4], Player::runlightOptions($scenario));
    }

    public function testSendsAndKeepsWhatTheTypeScriptRunnerDoes(): void
    {
        $scenario = Json::decode(<<<'JSON'
            {
              "name": "the runner",
              "site": {"hostnames": ["example.com"], "timezone": "UTC"},
              "start": 1700000000000,
              "token": "t",
              "upstream": [
                {"url": "https://api.example.com/json", "method": "POST", "body": {"ok": true}},
                {"url": "https://api.example.com/", "status": 201, "body": "plain", "headers": {"x-up": "1"}}
              ],
              "steps": [
                {"method": "POST", "path": "/login", "form": {"email": "a b@x.com", "next": "/runlight/?a=1&b=2"},
                 "capture": {"tok": "token", "id": "nested.list.0.id", "etag": "header:etag", "code": "header:location~code=([a-f0-9]+)",
                   "cookies": "header:set-cookie", "sec": "secret", "raw": "text~\"id\":\"(\\w+)\"", "missing": "nested.nothing.deep",
                   "count": "nested.count", "flag": "nested.flag", "arr": "nested.arr", "obj": "nested", "nomatch": "text~(zzz)"}},
                {"advance": 30000, "method": "put", "path": "/x/{{id}}?c={{code}}",
                 "headers": {"Authorization": "Bearer {{tok}}", "X-Otp": "{{totp:sec}}", "X-All": "{{missing}}|{{count}}|{{flag}}|{{arr}}|{{obj}}|{{unknown}}|{{nomatch}}|{{raw}}"},
                 "body": {"a": "{{etag}}", "n": 1.5, "o": {}, "l": [], "t": "{{totp:sec}}"}},
                {"method": "GET", "path": "/go/x", "to": "links", "host": "s.example.com", "jar": "other"},
                {"method": "GET", "path": "/.well-known/x", "absolute": true, "jar": false, "capture": {"unsub": "fetched~/unsubscribe/([a-f0-9]{32})"}},
                {"method": "GET", "path": "/r/{{unsub}}", "to": "linkDomain", "headers": {"Cookie": "mine=1"}},
                {"method": "POST", "path": "/raw", "body": "{{tok}} as text", "headers": {"content-type": "text/csv"}, "look": ["a,b", "zzz"]},
                {"method": "GET", "path": "/export"},
                {"method": "GET", "path": "/null"}
              ]
            }
            JSON);
        $fetcher = null;
        $now = null;
        $script = [
            function (Request $r) use (&$now) {
                $this->assertSame('https://example.com/runlight/login', $r->url);
                $this->assertSame('POST', $r->method);
                $this->assertSame('email=a+b%40x.com&next=%2Frunlight%2F%3Fa%3D1%26b%3D2', $r->text());
                $this->assertSame('application/x-www-form-urlencoded', $r->headers->get('content-type'));
                $this->assertNull($r->headers->get('cookie'));
                $this->assertSame(self::START, $now());
                foreach (Player::ENV as $name) {
                    $this->assertNull(Env::get($name), "$name is cleared");
                }
                return new Response(
                    Json::encode(['token' => self::KEY, 'secret' => self::SECRET, 'id' => self::HEX24, 'nested' => ['list' => [['id' => 'x1']], 'count' => 3, 'flag' => true, 'arr' => [1, null, 'b']]]),
                    200,
                    [
                        'content-type' => 'application/json; charset=utf-8',
                        'etag' => 'W/"1"',
                        'location' => '/cb?code=deadbeef&state=' . self::HEX32,
                        'set-cookie' => ['sid=abc; Path=/; HttpOnly', 'old=; Max-Age=0', 'keep=k1'],
                        'cache-control' => 'no-store',
                        'x-other' => 'not compared',
                    ],
                );
            },
            function (Request $r) use (&$fetcher, &$now) {
                $this->assertSame('https://example.com/runlight/x/x1?c=deadbeef', $r->url);
                $this->assertSame('PUT', $r->method);
                $this->assertSame(self::START + 30_000, $now());
                $code = Crypto::totp(self::SECRET, intdiv(self::START + 30_000, 30_000));
                $this->assertSame('Bearer ' . self::KEY, $r->headers->get('authorization'));
                $this->assertSame($code, $r->headers->get('x-otp'));
                $this->assertSame('|3|true|1,,b|[object Object]|||' . self::HEX24, $r->headers->get('x-all'));
                $this->assertSame('sid=abc; keep=k1', $r->headers->get('cookie'));
                $this->assertSame(Player::TEXT_BODY_TYPE, $r->headers->get('content-type'));
                $this->assertSame('{"a":"W/\"1\"","n":1.5,"o":{},"l":[],"t":"' . $code . '"}', $r->text());

                $json = $fetcher->fetch('https://api.example.com/json', ['method' => 'post', 'headers' => ['Content-Type' => 'application/json', 'X-B' => '2', 'a-first' => '1'], 'body' => '{"q":"' . self::KEY . '"}']);
                $this->assertSame([200, 'application/json', '{"ok":true}'], [$json->status, $json->headers->get('content-type'), $json->text()]);
                $plain = $fetcher->fetch('https://api.example.com/json');
                $this->assertSame([201, null, '1', 'plain'], [$plain->status, $plain->headers->get('content-type'), $plain->headers->get('x-up'), $plain->text()]);
                try {
                    $fetcher->fetch('https://nowhere.example/', ['method' => 'DELETE']);
                    $this->fail('No upstream answers nowhere.example');
                } catch (FetchError $error) {
                    $this->assertSame('fetch failed', $error->getMessage());
                }
                return new Response('', 204, ['set-cookie' => 'sid=gone; Max-Age=0']);
            },
            function (Request $r, string $to) {
                $this->assertSame('links', $to);
                $this->assertSame('https://s.example.com/go/x', $r->url);
                $this->assertNull($r->headers->get('cookie'));
                return new Response('', 302, ['location' => 'https://shop.example.com/?ref=' . self::KEY, 'set-cookie' => 'o=1']);
            },
            function (Request $r) use (&$fetcher) {
                $this->assertSame('https://example.com/.well-known/x', $r->url);
                $this->assertNull($r->headers->get('cookie'));
                $fetcher->fetch('https://api.example.com/mail', ['method' => 'POST', 'headers' => ['content-type' => 'application/json'], 'body' => '{"link":"https://stats.example.com/unsubscribe/' . self::HEX32 . '"}']);
                $fetcher->fetch('https://api.example.com/form', ['method' => 'POST', 'headers' => ['content-type' => 'application/x-www-form-urlencoded'], 'body' => 'a=1&b=x+y&a=2']);
                return new Response('<p>hi</p>', 200, ['content-type' => 'text/html']);
            },
            function (Request $r, string $to) {
                $this->assertSame('linkDomain', $to);
                $this->assertSame('https://example.com/r/' . self::HEX32, $r->url);
                $this->assertSame('mine=1', $r->headers->get('cookie'));
                return null;
            },
            function (Request $r) {
                $this->assertSame(self::KEY . ' as text', $r->text());
                $this->assertSame('text/csv', $r->headers->get('content-type'));
                $this->assertSame('keep=k1', $r->headers->get('cookie'));
                return new Response("a,b\n1," . self::KEY, 200, ['content-type' => 'text/csv; charset=utf-8']);
            },
            fn () => new Response(Zip::zip([['name' => 'a.csv', 'text' => 'x,' . self::HEX32], ['name' => 'b.txt', 'text' => "\u{FEFF}plain"]]), 200, ['content-type' => 'application/zip', 'content-disposition' => 'attachment; filename="export.zip"']),
            fn () => new Response('null', 200),
        ];
        $target = new ScriptedTarget($script);
        $answers = (new Player())->play($scenario, function (array $runlight, array $routes) use ($target, &$fetcher, &$now) {
            $fetcher = $runlight['fetcher'];
            $now = $runlight['now'];
            return $target;
        });

        $expected = Json::decode(<<<JSON
            [
              {"status": 200, "headers": {"content-type": "application/json", "cache-control": "no-store", "location": "/cb?code=<value>&state=<hex>",
                "set-cookie": ["sid=<value>; Path=/; HttpOnly", "old=; Max-Age=0", "keep=<value>"]},
               "body": {"token": "<token>", "secret": "<secret>", "id": "<id>", "nested": {"list": [{"id": "x1"}], "count": 3, "flag": true, "arr": [1, null, "b"]}}},
              {"status": 204, "headers": {"set-cookie": ["sid=<value>; Max-Age=0"]}, "fetched": [
                {"method": "POST", "url": "https://api.example.com/json", "headers": {"a-first": "1", "content-type": "application/json", "x-b": "2"}, "body": {"q": "<q>"}},
                {"method": "GET", "url": "https://api.example.com/json"},
                {"method": "DELETE", "url": "https://nowhere.example/"}
              ]},
              {"status": 302, "headers": {"location": "https://shop.example.com/?ref=<key>", "set-cookie": ["o=<value>"]}},
              {"status": 200, "headers": {"content-type": "text/html"}, "fetched": [
                {"method": "POST", "url": "https://api.example.com/mail", "headers": {"content-type": "application/json"}, "body": {"link": "https://stats.example.com/unsubscribe/<hex>"}},
                {"method": "POST", "url": "https://api.example.com/form", "headers": {"content-type": "application/x-www-form-urlencoded"}, "body": {"a": "2", "b": "x y"}}
              ]},
              {"pass": true},
              {"status": 200, "headers": {"content-type": "text/csv"}, "text": "a,b\\n1,<key>", "found": [true, false]},
              {"status": 200, "headers": {"content-type": "application/zip", "content-disposition": "attachment; filename=\\"export.zip\\""},
               "files": [{"name": "a.csv", "text": "x,<hex>"}, {"name": "b.txt", "text": "plain"}]},
              {"status": 200, "body": null}
            ]
            JSON);
        $this->assertSame(Normalizer::canonical($expected), Normalizer::canonical($answers));
        $this->assertSame(8, $target->idled);
    }

    public function testNamesTheStepThatThrew(): void
    {
        $scenario = Json::decode('{"name":"broken","site":{"hostnames":[],"timezone":"UTC"},"start":0,"token":"","steps":[{"method":"GET","path":"/a"},{"method":"POST","path":"/b"}]}');
        $target = new ScriptedTarget([fn () => new Response('', 200), fn () => throw new \DomainException('boom')]);
        $this->expectExceptionMessage('broken: step 2, POST /b: boom');
        (new Player())->play($scenario, fn () => $target);
    }

    public function testUpstreamAnswers(): void
    {
        $fetcher = new UpstreamFetcher(Json::decode('[{"url":"https://a.example/null","body":null},{"url":"https://a.example/list","body":[1],"headers":{"Content-Type":"text/plain"}},{"url":"https://a.example/big","body":"0123456789"},{"url":"https://a.example/empty","method":""}]'));
        $null = $fetcher->fetch('https://a.example/null');
        $this->assertSame(['application/json', 'null'], [$null->headers->get('content-type'), $null->text()]);
        // Spread over {"content-type": ...}, a differently spelled name is a second value, as new Headers() makes it.
        $this->assertSame('application/json, text/plain', $fetcher->fetch('https://a.example/list')->headers->get('content-type'));
        $this->assertSame('01234', $fetcher->fetch('https://a.example/big', ['maxBytes' => 5, 'truncate' => true])->text());
        try {
            $fetcher->fetch('https://a.example/big', ['maxBytes' => 5]);
            $this->fail('Past maxBytes is too long');
        } catch (\Runlight\Http\BodyTooLong) {
        }
        $empty = $fetcher->fetch('https://a.example/empty', ['method' => 'PATCH']);
        $this->assertSame([200, '', null], [$empty->status, $empty->text(), $empty->headers->get('content-type')]);
        $this->assertCount(5, $fetcher->take());
        $this->assertSame([], $fetcher->take());
    }

    public function testCaptureHelpers(): void
    {
        $parsed = Json::decode('{"a":{"b":[{"c":"x"},0,""]},"n":1.0,"f":0.5,"big":1e21}');
        $this->assertSame('x', Player::jsString(Player::dig($parsed, 'a.b.0.c')));
        $this->assertSame('0', Player::jsString(Player::dig($parsed, 'a.b.1')));
        $this->assertSame('', Player::jsString(Player::dig($parsed, 'a.b.1.c')));
        $this->assertSame('', Player::jsString(Player::dig($parsed, 'a.b.01')));
        $this->assertSame('1', Player::jsString(Player::dig($parsed, 'n')));
        $this->assertSame('0.5', Player::jsString(Player::dig($parsed, 'f')));
        $this->assertSame('1e+21', Player::jsString(Player::dig($parsed, 'big')));
        $this->assertSame('[object Object],0,', Player::jsString(Player::dig($parsed, 'a.b')));
        $this->assertSame('', Player::jsString(Player::dig(null, 'a')));
        $this->assertSame('abc', Player::firstGroup('state=([a-f0-9]+)', 'x?state=abc&y'));
        $this->assertSame('', Player::firstGroup('state=([a-f0-9]+)', 'nothing'));
        $this->assertSame('', Player::firstGroup('(x)?y', 'y'));
        $this->assertSame('/assets/app.1f.css', Player::firstGroup('href="/runlight(/assets/app\\.[a-f0-9]+\\.css)"', '<link href="/runlight/assets/app.1f.css">'));
    }

    /** @return array<string, mixed> what Player::clearEnv() saved, to put back */
    private function setEnv(): array
    {
        $saved = Player::clearEnv();
        foreach (Player::ENV as $name) {
            putenv("$name=from-outside");
            $_ENV[$name] = 'from-outside';
            $_SERVER[$name] = 'from-outside';
        }
        return $saved;
    }

    private function assertEnvRestored(): void
    {
        foreach (Player::ENV as $name) {
            $this->assertSame(['from-outside', 'from-outside', 'from-outside'], [getenv($name), $_ENV[$name] ?? null, $_SERVER[$name] ?? null], "$name is put back");
        }
    }
}
