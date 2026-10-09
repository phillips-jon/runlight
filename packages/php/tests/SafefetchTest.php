<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Http\FetchError;
use Runlight\Http\Response;
use Runlight\PrivateAddressError;
use Runlight\Safefetch;
use Runlight\Tests\Support\FakeFetcher;

/** Ports safefetch.test.ts, replays the address checks in tests/fixtures/outbound.json, and covers each hop's checks. */
final class SafefetchTest extends TestCase
{
    /** A DNS stand-in. */
    private static function dns(array $names): \Closure
    {
        return static fn (string $name): array => $names[$name] ?? [];
    }

    public function testOnlyAddressesOnThePublicInternetCountAsPublic(): void
    {
        foreach (['93.184.215.14', '1.1.1.1', '2606:4700:4700::1111', '2a00:1450:4001:82a::200e'] as $ip) {
            $this->assertTrue(Safefetch::publicAddress($ip), $ip);
        }
        foreach ([
            '127.0.0.1', '10.0.0.1', '172.16.5.4', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255',
            '::1', '::', 'fe80::1', 'fd00::1', 'ff02::1', '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:169.254.169.254', '64:ff9b::a00:1',
            '2002:a00:1::', '2001:db8::1', '2001:0:4136:e378::1', '[::1]', 'not an address', '1.2.3', '1.2.3.256',
        ] as $ip) {
            $this->assertFalse(Safefetch::publicAddress($ip), $ip);
        }
    }

    public function testAddressChecksMatchTypeScript(): void
    {
        foreach (MailTest::fixture()['ips'] as $case) {
            $this->assertSame($case['public'], Safefetch::publicAddress($case['ip']), $case['ip']);
        }
    }

    public function testAPublicFetchNeverReachesTheInstallsOwnNetworkHoweverTheAddressIsWritten(): void
    {
        // Something listening locally, which none of these may reach.
        $inside = stream_socket_server('tcp://127.0.0.1:0');
        $port = (int) explode(':', stream_socket_get_name($inside, false))[1];
        try {
            foreach (["http://127.0.0.1:$port/", "https://127.0.0.1:$port/", "https://[::1]:$port/", "https://[::ffff:127.0.0.1]:$port/", "https://localhost:$port/", "https://LOCALHOST.:$port/", "https://app.localhost:$port/"] as $url) {
                try {
                    Safefetch::publicFetch($url, ['timeoutMs' => 2000]);
                    $this->fail("$url should be refused");
                } catch (PrivateAddressError) {
                    $this->addToAssertionCount(1);
                }
            }
            $read = [$inside];
            $write = $except = null;
            $this->assertSame(0, stream_select($read, $write, $except, 0), 'nothing connected');
            $this->assertTrue(Safefetch::resolvesPrivately('localhost'));
            $this->assertFalse(Safefetch::resolvesPrivately('name.that.does.not.resolve.invalid'));
            $this->assertSame([], Safefetch::publicAddresses('name.that.does.not.resolve.invalid'));
            $this->assertSame(['8.8.8.8'], Safefetch::publicAddresses('8.8.8.8'));
            $this->assertSame([], Safefetch::publicAddresses('localhost'));
        } finally {
            fclose($inside);
        }
    }

    public function testTheCheckedAddressesArePinned(): void
    {
        $fetcher = new FakeFetcher(static fn () => new Response('ok'));
        $answer = Safefetch::publicFetch('https://Example.com/icon', ['timeoutMs' => 2000, 'headers' => ['user-agent' => 'Runlight'], 'maxBytes' => 10, 'lookup' => self::dns(['example.com' => ['93.184.215.14', '2606:4700::1111']])], $fetcher);
        $this->assertSame('ok', $answer->text());
        $this->assertSame(['example.com:443:93.184.215.14,[2606:4700::1111]'], $fetcher->inits[0]['resolve']);
        $this->assertSame('manual', $fetcher->inits[0]['redirect']);
        $this->assertSame(10, $fetcher->inits[0]['maxBytes']);
        $this->assertSame(['method' => 'GET', 'url' => 'https://example.com/icon', 'headers' => ['user-agent' => 'Runlight'], 'body' => ''], $fetcher->requests[0]);

        $literal = new FakeFetcher(static fn () => new Response('ok'));
        Safefetch::publicFetch('https://93.184.215.14:8443/', ['timeoutMs' => 2000, 'lookup' => self::dns([])], $literal);
        $this->assertArrayNotHasKey('resolve', $literal->inits[0], 'an address needs no pin');
    }

    public function testANameWithAnyPrivateAddressIsRefused(): void
    {
        $fetcher = new FakeFetcher(static fn () => new Response('ok'));
        foreach (['inside.example' => ['10.0.0.5'], 'mixed.example' => ['93.184.215.14', '169.254.169.254'], 'mapped.example' => ['::ffff:127.0.0.1']] as $name => $addresses) {
            try {
                Safefetch::publicFetch("https://$name/", ['timeoutMs' => 2000, 'lookup' => self::dns([$name => $addresses])], $fetcher);
                $this->fail("$name should be refused");
            } catch (PrivateAddressError $error) {
                $this->assertSame("$name is not a public address", $error->getMessage());
            }
        }
        $this->assertSame([], $fetcher->requests);
        $this->expectException(FetchError::class);
        Safefetch::publicFetch('https://nowhere.example/', ['timeoutMs' => 2000, 'lookup' => self::dns([])], $fetcher);
    }

    public function testRedirectsAreFollowedByHandUnderTheSameRules(): void
    {
        $dns = self::dns(['a.example' => ['93.184.215.14'], 'b.example' => ['1.1.1.1'], 'inside.example' => ['192.168.0.2']]);
        $hops = static fn (array $answers) => new FakeFetcher(static function (string $url) use (&$answers): Response {
            return array_shift($answers) ?? new Response('end');
        });

        $fetcher = $hops([Response::redirect('/next', 301), Response::redirect('https://b.example/last', 302), new Response('done')]);
        $answer = Safefetch::publicFetch('https://a.example/', ['timeoutMs' => 2000, 'redirects' => 3, 'lookup' => $dns], $fetcher);
        $this->assertSame('done', $answer->text());
        $this->assertSame(['https://a.example/', 'https://a.example/next', 'https://b.example/last'], array_column($fetcher->requests, 'url'));
        $this->assertSame(['b.example:443:1.1.1.1'], $fetcher->inits[2]['resolve']);

        $fetcher = $hops([Response::redirect('https://b.example/', 302)]);
        $this->assertSame(302, Safefetch::publicFetch('https://a.example/', ['timeoutMs' => 2000, 'lookup' => $dns], $fetcher)->status, 'a redirect past the last comes back as it is');

        foreach (['https://10.0.0.1/' => '10.0.0.1', 'https://inside.example/' => 'inside.example', 'http://b.example/' => 'http://b.example/', 'https://[fe80::1]/' => 'fe80::1'] as $location => $what) {
            try {
                Safefetch::publicFetch('https://a.example/', ['timeoutMs' => 2000, 'redirects' => 3, 'lookup' => $dns], $hops([Response::redirect($location)]));
                $this->fail("$location should be refused");
            } catch (PrivateAddressError $error) {
                $this->assertSame("$what is not a public address", $error->getMessage());
            }
        }
    }

    public function testRunningOutOfTimeSaysSo(): void
    {
        $fetcher = new FakeFetcher(static fn () => throw new FetchError('Operation timed out', true));
        try {
            Safefetch::publicFetch('https://a.example/', ['timeoutMs' => 2000, 'lookup' => self::dns(['a.example' => ['1.1.1.1']])], $fetcher);
            $this->fail('should time out');
        } catch (FetchError $error) {
            $this->assertTrue($error->timedOut);
            $this->assertSame('The operation was aborted due to timeout', $error->getMessage());
        }
        $refused = new FakeFetcher(static fn () => throw new FetchError('Connection refused'));
        $this->expectExceptionMessage('Connection refused');
        Safefetch::publicFetch('https://a.example/', ['timeoutMs' => 2000, 'lookup' => self::dns(['a.example' => ['1.1.1.1']])], $refused);
    }
}
