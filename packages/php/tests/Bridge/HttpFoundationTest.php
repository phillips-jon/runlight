<?php

declare(strict_types=1);

namespace Runlight\Tests\Bridge;

use PHPUnit\Framework\TestCase;
use Runlight\Bridge\HttpFoundation;
use Runlight\Bridge\ShortLinks;
use Runlight\Http\Response;
use Runlight\Runlight;
use Runlight\Store\Stores;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response as SymfonyResponse;
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

    public function testShortLinksAnswerLinkDomainsAndTheLinkPathBeforeTheApp(): void
    {
        $rl = $this->runlight();
        $routes = $rl->routes(['token' => 'app-token']);
        $json = ['HTTP_AUTHORIZATION' => 'Bearer app-token', 'CONTENT_TYPE' => 'application/json'];
        $this->assertSame(201, HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/api/link-domains', 'POST', [], [], [], $json, '{"domain":"t.example.com"}'))->getStatusCode());
        $this->assertSame(201, HttpFoundation::handle($rl, $routes, Request::create('https://example.com/runlight/api/links', 'POST', [], [], [], $json, '{"url":"https://example.org/a","slug":"a","domain":"t.example.com"}'))->getStatusCode());

        $middleware = new ShortLinks($rl);
        $reached = [];
        $app = static function (Request $request) use (&$reached): SymfonyResponse {
            $reached[] = $request->getHost() . ' ' . $request->getMethod() . ' ' . $request->getPathInfo() . ' ' . $request->getContent();
            return new SymfonyResponse('app');
        };
        $send = static fn (string $url, string $method = 'GET', ?string $body = null): SymfonyResponse => $middleware->handle(Request::create($url, $method, [], [], [], ['HTTP_USER_AGENT' => 'Mozilla/5.0 (Macintosh) Chrome/129.0.0.0 Safari/537.36'], $body), $app);

        $redirected = $send('https://t.example.com/a');
        $this->assertSame(302, $redirected->getStatusCode(), 'a link-domain request is redirected');
        $this->assertSame('https://example.org/a', $redirected->headers->get('location'));
        $this->assertSame(404, $send('https://t.example.com/missing')->getStatusCode(), 'a link domain answers every path itself');
        $this->assertSame('{"runlight":true,"domain":"t.example.com"}', $send('https://t.example.com/.well-known/runlight-link-domain')->getContent());
        $this->assertSame('https://example.org/a', $send('https://example.com/go/a')->headers->get('location'), 'the link path answers on the app\'s own host');
        $this->assertSame([], $reached);
        $this->assertSame('app', $send('https://t.example.com/runlight/api/sites')->getContent(), 'the dashboard\'s paths reach the app on a link domain');
        $this->assertSame('app', $send('https://example.com/a')->getContent(), 'the app\'s own host reaches the app');
        $this->assertSame('app', $send('https://example.com/go/missing')->getContent(), 'a slug with no link is the app\'s to answer');
        $this->assertSame('app', $send('https://example.com/go/%E0%A4%A')->getContent(), 'so is one that is not valid percent-encoding');
        $this->assertSame('app', $send('https://example.com/form', 'POST', 'name=x')->getContent());
        $this->assertSame([
            't.example.com GET /runlight/api/sites ',
            'example.com GET /a ',
            'example.com GET /go/missing ',
            'example.com GET /go/%E0%A4%A ',
            'example.com POST /form name=x',
        ], $reached);

        // Symfony's kernel.request event, as a listener before the router gets it.
        $event = new class (Request::create('https://t.example.com/a')) {
            public ?SymfonyResponse $response = null;

            public function __construct(private readonly Request $request)
            {
            }

            public function getRequest(): Request
            {
                return $this->request;
            }

            public function setResponse(SymfonyResponse $response): void
            {
                $this->response = $response;
            }
        };
        $middleware->onKernelRequest($event);
        $this->assertSame(302, $event->response?->getStatusCode());
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
