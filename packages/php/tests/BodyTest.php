<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Body;
use Runlight\Http\BodyTooLong;
use Runlight\Http\CurlFetcher;
use Runlight\Http\Response;

/** Capped reads: Body's checks, and the Fetcher's maxBytes, truncate, and resolve against a real server. */
final class BodyTest extends TestCase
{
    /** @var resource|null */
    private static $server = null;
    private static int $port = 0;

    public static function setUpBeforeClass(): void
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        self::$port = (int) explode(':', stream_socket_get_name($probe, false))[1];
        fclose($probe);
        self::$server = proc_open([PHP_BINARY, '-S', '127.0.0.1:' . self::$port, __DIR__ . '/Support/http-router.php'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        for ($i = 0; $i < 100; $i++) {
            $socket = @stream_socket_client('tcp://127.0.0.1:' . self::$port, $errno, $errstr, 0.1);
            if ($socket !== false) {
                fclose($socket);
                return;
            }
            usleep(50_000);
        }
    }

    public static function tearDownAfterClass(): void
    {
        if (is_resource(self::$server)) {
            proc_terminate(self::$server);
            proc_close(self::$server);
        }
    }

    public function testTextIsReadUpToTheCap(): void
    {
        $this->assertSame('hello', Body::readTextCapped(new Response('hello'), 5));
        $this->assertSame(['a' => 1], Body::readJsonCapped(new Response('{"a":1}'), 100, true));
        $this->assertEquals((object) ['a' => 1], Body::readJsonCapped(new Response('{"a":1}'), 100));
        $this->assertSame("a\u{FFFD}b", Body::readTextCapped(new Response("a\xffb"), 10), 'as TextDecoder reads bytes that are not UTF-8');
        $this->assertSame('x', Body::readTextCapped(new Response("\xEF\xBB\xBFx"), 10));
        $this->expectException(BodyTooLong::class);
        $this->expectExceptionMessage('Body over 4 bytes');
        Body::readTextCapped(new Response('hello'), 4);
    }

    public function testADeclaredLengthOverTheCapIsRefusedUnread(): void
    {
        $this->expectException(BodyTooLong::class);
        Body::readTextCapped(new Response('', 200, ['content-length' => '1000']), 10);
    }

    public function testTheFetcherStopsReadingPastMaxBytes(): void
    {
        $fetcher = new CurlFetcher();
        $url = 'http://127.0.0.1:' . self::$port . '/bytes?n=300000';
        $this->assertSame(300_000, strlen($fetcher->fetch($url, ['maxBytes' => 300_000])->text()));
        try {
            $fetcher->fetch($url, ['maxBytes' => 100_000]);
            $this->fail('a body past maxBytes is refused');
        } catch (BodyTooLong $error) {
            $this->assertSame('Body over 100000 bytes', $error->getMessage());
        }
        $start = $fetcher->fetch($url, ['maxBytes' => 100_000, 'truncate' => true]);
        $this->assertSame(200, $start->status);
        $this->assertSame(str_repeat('a', 100_000), $start->text(), 'with truncate, the start comes back');
        $this->assertSame('text/html', explode(';', (string) $start->headers->get('content-type'))[0]);
    }

    public function testTheFetcherConnectsToThePinnedAddress(): void
    {
        $port = self::$port;
        $answer = (new CurlFetcher())->fetch("http://pinned.invalid:$port/", ['resolve' => ["pinned.invalid:$port:127.0.0.1"]]);
        $this->assertSame("host pinned.invalid:$port", $answer->text());
    }

    public function testTheStreamFallbackConnectsToThePinnedAddressAndCapsToo(): void
    {
        $port = self::$port;
        $streams = new \ReflectionMethod(CurlFetcher::class, 'viaStreams');
        $answer = $streams->invoke(new CurlFetcher(), "http://pinned.invalid:$port/", ['resolve' => ["pinned.invalid:$port:127.0.0.1"]]);
        $this->assertSame("host pinned.invalid:$port", $answer->text());
        $start = $streams->invoke(new CurlFetcher(), "http://127.0.0.1:$port/bytes?n=50000", ['maxBytes' => 1000, 'truncate' => true]);
        $this->assertSame(str_repeat('a', 1000), $start->text());
        $this->expectException(BodyTooLong::class);
        $streams->invoke(new CurlFetcher(), "http://127.0.0.1:$port/bytes?n=50000", ['maxBytes' => 1000]);
    }
}
