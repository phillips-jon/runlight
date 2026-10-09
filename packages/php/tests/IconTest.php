<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Http\Response;
use Runlight\Icon;
use Runlight\Tests\Support\FakeFetcher;

/** A site's icon: the links picked as TypeScript picks them, and the fetches with their caps. */
final class IconTest extends TestCase
{
    private string $dir;

    protected function setUp(): void
    {
        $this->dir = sys_get_temp_dir() . '/runlight-icon-test-' . bin2hex(random_bytes(4));
        mkdir($this->dir);
    }

    protected function tearDown(): void
    {
        foreach (glob("{$this->dir}/runlight-icons/*") ?: [] as $file) {
            unlink($file);
        }
        @rmdir("{$this->dir}/runlight-icons");
        @rmdir($this->dir);
    }

    public function testIconLinksMatchTypeScript(): void
    {
        foreach (MailTest::fixture()['icons'] as $case) {
            $this->assertSame($case['links'], Icon::iconLinks($case['html'], $case['base']), $case['html']);
        }
    }

    public function testTheBestLinkedIconIsFetchedWithItsCaps(): void
    {
        // An address as the origin, so no name is looked up.
        $origin = 'https://93.184.215.14';
        $fetcher = new FakeFetcher(static function (string $url): Response {
            return match ($url) {
                "https://93.184.215.14/" => new Response('<link rel="apple-touch-icon" href="/touch.png"><link rel="icon" href="/i.svg">', 200, ['content-type' => 'text/html; charset=utf-8']),
                "https://93.184.215.14/touch.png" => new Response('<html>', 200, ['content-type' => 'text/html']),
                "https://93.184.215.14/i.svg" => new Response('<svg/>', 200, ['content-type' => 'Image/SVG+xml; charset=utf-8']),
                default => new Response('', 404),
            };
        });
        $now = 1_791_471_600_000;
        $icon = Icon::fetchIcon($origin, $now, $fetcher, $this->dir);
        $this->assertSame(['body' => '<svg/>', 'type' => 'image/svg+xml'], $icon);
        $this->assertSame(['https://93.184.215.14/', 'https://93.184.215.14/touch.png', 'https://93.184.215.14/i.svg'], array_column($fetcher->requests, 'url'));
        $this->assertSame(['maxBytes' => 200_000, 'truncate' => true], array_intersect_key($fetcher->inits[0], ['maxBytes' => 1, 'truncate' => 1]));
        $this->assertSame(262_144, $fetcher->inits[1]['maxBytes']);
        $this->assertArrayNotHasKey('truncate', $fetcher->inits[1], 'an image must arrive whole');
        $this->assertSame('Runlight (+https://runlight.sh)', $fetcher->requests[0]['headers']['user-agent']);
        $this->assertLessThanOrEqual(4000, $fetcher->inits[0]['timeoutMs']);

        // Cached for a day, even across requests (here, with the process cache emptied).
        $this->assertSame($icon, Icon::fetchIcon($origin, $now + 86_399_000, $fetcher, $this->dir));
        $this->assertCount(3, $fetcher->requests);
        $flush = new \ReflectionProperty(Icon::class, 'cache');
        $flush->setValue(null, []);
        $this->assertSame($icon, Icon::fetchIcon($origin, $now + 86_399_000, $fetcher, $this->dir));
        $this->assertCount(3, $fetcher->requests);
        Icon::fetchIcon($origin, $now + 86_400_000, $fetcher, $this->dir);
        $this->assertCount(6, $fetcher->requests, 'and looked up again after it');
    }

    public function testFaviconIsTheFallbackAndNoIconIsRememberedForAnHour(): void
    {
        $origin = 'https://1.1.1.1';
        $answers = ['https://1.1.1.1/favicon.ico' => new Response('', 200, ['content-type' => 'image/x-icon'])];
        $fetcher = new FakeFetcher(static fn (string $url) => $answers[$url] ?? new Response('nope', 500));
        $now = 1_791_471_600_000;
        $this->assertNull(Icon::fetchIcon($origin, $now, $fetcher, $this->dir), 'an empty image is no icon');
        $this->assertSame(['https://1.1.1.1/', 'https://1.1.1.1/favicon.ico'], array_column($fetcher->requests, 'url'));
        $this->assertNull(Icon::fetchIcon($origin, $now + 3_599_000, $fetcher, $this->dir));
        $this->assertCount(2, $fetcher->requests);
        Icon::fetchIcon($origin, $now + 3_600_000, $fetcher, $this->dir);
        $this->assertCount(4, $fetcher->requests);
    }

    public function testAPrivateOriginIsNeverFetched(): void
    {
        $fetcher = new FakeFetcher(static fn () => new Response('x', 200, ['content-type' => 'image/png']));
        $this->assertNull(Icon::fetchIcon('https://192.168.1.1', 0, $fetcher, $this->dir));
        $this->assertSame([], $fetcher->requests);
    }
}
