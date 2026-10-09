<?php

declare(strict_types=1);

namespace Runlight\Tests\Bridge;

use PHPUnit\Framework\TestCase;
use Runlight\Bridge\HttpFoundation;
use Runlight\Http\Response;
use Runlight\Runlight;
use Runlight\Store\Stores;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Runlight behind Laravel's or Symfony's request and response. */
final class HttpFoundationTest extends TestCase
{
    private function runlight(): Runlight
    {
        return new Runlight([
            'store' => Stores::sqlite(':memory:'),
            'site' => ['name' => 'example.com', 'hostnames' => ['example.com']],
            'now' => static fn (): int => 1_791_374_400_000,
        ]);
    }

    public function testTheRequestKeepsItsQueryStringAndTheConnectionsAddress(): void
    {
        $request = Request::create('https://example.com/runlight/api/stats?site=a&period=7d&b=%2F', 'POST', [], [], [], ['REMOTE_ADDR' => '198.51.100.4', 'HTTP_X_FORWARDED_FOR' => '203.0.113.9'], '{"k":"pageview"}');
        $ours = HttpFoundation::request($request);
        $this->assertSame('https://example.com/runlight/api/stats?site=a&period=7d&b=%2F', $ours->url, 'as sent, not sorted');
        $this->assertSame('POST', $ours->method);
        $this->assertSame('198.51.100.4', $ours->remoteAddress);
        $this->assertSame('203.0.113.9', $ours->headers->get('x-forwarded-for'));
        $this->assertSame('{"k":"pageview"}', $ours->text());
        $this->assertSame('', HttpFoundation::request(Request::create('https://example.com/runlight/', 'GET'))->text());
    }

    public function testATrackerHitAndTheDashboardTokenCookieGoThrough(): void
    {
        $rl = $this->runlight();
        $routes = $rl->routes(['token' => 'app-token']);
        $hit = HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/e', 'POST', [], [], [], [
            'REMOTE_ADDR' => '203.0.113.9',
            'HTTP_USER_AGENT' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36',
        ], '{"k":"pageview","u":"https://example.com/post"}'));
        $this->assertSame(202, $hit->getStatusCode());

        $signIn = HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/?token=app-token'));
        $this->assertSame(303, $signIn->getStatusCode());
        $cookies = $signIn->headers->getCookies();
        $this->assertCount(1, $cookies);
        $this->assertSame('runlight_token', $cookies[0]->getName());
        $this->assertTrue($cookies[0]->isHttpOnly());

        $stats = HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/api/stats?period=today', 'GET', [], [], [], ['HTTP_COOKIE' => 'runlight_token=' . $cookies[0]->getValue()]));
        $this->assertSame(200, $stats->getStatusCode());
        $this->assertSame(1, json_decode((string) $stats->getContent(), true)['stats']['pageviews']);
    }

    public function testAShortLinkAnswersAtGo(): void
    {
        $rl = $this->runlight();
        $routes = $rl->routes(['token' => 'app-token']);
        $made = HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/api/links', 'POST', [], [], [], ['HTTP_AUTHORIZATION' => 'Bearer app-token', 'CONTENT_TYPE' => 'application/json'], '{"url":"https://example.org/sale","slug":"sale"}'));
        $this->assertSame(201, $made->getStatusCode());
        $go = HttpFoundation::handle($rl, $routes, Request::create('https://example.com/go/sale'));
        $this->assertSame(302, $go->getStatusCode());
        $this->assertSame('https://example.org/sale', $go->headers->get('location'));
    }

    public function testAStreamedAnswerStaysStreamed(): void
    {
        $streamed = HttpFoundation::response(new Response(static function (): void {
            echo 'a,b';
        }, 200, ['content-type' => 'text/csv']));
        $this->assertInstanceOf(StreamedResponse::class, $streamed);
        $this->assertSame('text/csv', $streamed->headers->get('content-type'));
    }
}
