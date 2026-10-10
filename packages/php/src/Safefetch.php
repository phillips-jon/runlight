<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Response;
use Runlight\Http\Url;

/**
 * Fetches from addresses that other people's input names, such as the icon
 * links on a site's home page or a link domain, and only from the public
 * internet. Only https is fetched, never a private, loopback, link-local,
 * or metadata address, and redirects are followed by hand under the same
 * rules. The name is resolved and every address it gives is checked before
 * each hop, and the request is pinned to the checked addresses (the Fetcher's
 * `resolve`), so a name that answers differently a moment later gets nowhere.
 */
final class Safefetch
{
    /** @return list<int>|null */
    private static function v4(string $text): ?array
    {
        $parts = explode('.', $text);
        if (count($parts) !== 4) {
            return null;
        }
        foreach ($parts as $p) {
            if (!preg_match('/^\d{1,3}$/', $p) || (int) $p > 255) {
                return null;
            }
        }
        return array_map('intval', $parts);
    }

    /** @param list<int> $four */
    private static function publicV4(array $four): bool
    {
        [$a, $b, $c] = $four;
        if ($a === 0 || $a === 10 || $a === 127 || $a >= 224) {
            return false;
        }
        if ($a === 100 && $b >= 64 && $b < 128) {
            return false;
        }
        if ($a === 169 && $b === 254) {
            return false;
        }
        if ($a === 172 && $b >= 16 && $b < 32) {
            return false;
        }
        if ($a === 192 && $b === 168) {
            return false;
        }
        if ($a === 192 && $b === 0 && ($c === 0 || $c === 2)) {
            return false;
        }
        if ($a === 198 && ($b === 18 || $b === 19)) {
            return false;
        }
        if ($a === 198 && $b === 51 && $c === 100) {
            return false;
        }
        if ($a === 203 && $b === 0 && $c === 113) {
            return false;
        }
        return true;
    }

    /**
     * An IPv6 address as eight 16-bit groups, or null when it is not one.
     *
     * @return list<int>|null
     */
    private static function v6(string $text): ?array
    {
        $address = strtolower(explode('%', (string) preg_replace('/^\[|\]$/', '', $text))[0]);
        // A trailing IPv4 address becomes the last two groups.
        if (preg_match('/(\d{1,3}(?:\.\d{1,3}){3})$/', $address, $tail)) {
            $four = self::v4($tail[1]);
            if ($four === null) {
                return null;
            }
            $address = substr($address, 0, -strlen($tail[1])) . dechex(($four[0] << 8) | $four[1]) . ':' . dechex(($four[2] << 8) | $four[3]);
        }
        $halves = explode('::', $address);
        if (count($halves) > 2) {
            return null;
        }
        $head = $halves[0] !== '' ? explode(':', $halves[0]) : [];
        $rest = count($halves) === 2 && $halves[1] !== '' ? explode(':', $halves[1]) : [];
        $missing = 8 - count($head) - count($rest);
        if (count($halves) === 1 ? $missing !== 0 : $missing < 1) {
            return null;
        }
        $groups = [...$head, ...array_fill(0, count($halves) === 2 ? $missing : 0, '0'), ...$rest];
        foreach ($groups as $g) {
            if (!preg_match('/^[0-9a-f]{1,4}$/', $g)) {
                return null;
            }
        }
        return array_map('hexdec', $groups);
    }

    /** Whether an IP address, v4 or v6, is on the public internet. Anything that is not an address is not. */
    public static function publicAddress(string $ip): bool
    {
        $four = self::v4($ip);
        if ($four !== null) {
            return self::publicV4($four);
        }
        $g = self::v6($ip);
        if ($g === null) {
            return false;
        }
        $embedded = static fn (int $hi, int $lo): array => [$hi >> 8, $hi & 255, $lo >> 8, $lo & 255];
        $zero = static fn (array $groups): bool => array_filter($groups, static fn ($x) => $x !== 0) === [];
        // IPv4 inside IPv6: mapped (::ffff:0:0/96), the old compatible form (::/96), and NAT64 (64:ff9b::/96).
        if ($zero(array_slice($g, 0, 5)) && ($g[5] === 0xffff || $g[5] === 0)) {
            return $g[5] === 0 && $g[6] === 0 && $g[7] <= 1 ? false : self::publicV4($embedded($g[6], $g[7]));
        }
        if ($g[0] === 0x64 && $g[1] === 0xff9b && $zero(array_slice($g, 2, 4))) {
            return self::publicV4($embedded($g[6], $g[7]));
        }
        // 6to4 carries an IPv4 address in its second and third groups.
        if ($g[0] === 0x2002) {
            return self::publicV4($embedded($g[1], $g[2]));
        }
        if (($g[0] & 0xfe00) === 0xfc00 || ($g[0] & 0xffc0) === 0xfe80 || ($g[0] & 0xff00) === 0xff00) {
            return false;
        }
        // Teredo, documentation, and discard prefixes.
        if ($g[0] === 0x2001 && ($g[1] === 0 || $g[1] === 0xdb8)) {
            return false;
        }
        if ($g[0] === 0x100 && $zero(array_slice($g, 1, 3))) {
            return false;
        }
        return true;
    }

    /**
     * Every address a name resolves to, v4 and v6, as getaddrinfo() would give
     * them (the hosts file included). Empty when it does not resolve.
     *
     * @return list<string>
     */
    public static function lookup(string $name): array
    {
        $bare = (string) preg_replace('/^\[|\]$/', '', $name);
        if (self::v4($bare) !== null || self::v6($bare) !== null) {
            return [$bare];
        }
        $found = [];
        // gethostbynamel reads the hosts file as well as DNS, but only gives IPv4.
        $v4 = @gethostbynamel($bare);
        foreach ($v4 === false ? [] : $v4 as $address) {
            $found[] = $address;
        }
        $v6 = @dns_get_record($bare, DNS_AAAA);
        foreach (is_array($v6) ? $v6 : [] as $record) {
            if (isset($record['ipv6'])) {
                $found[] = $record['ipv6'];
            }
        }
        return array_values(array_unique($found));
    }

    /**
     * The public addresses a name resolves to, for setting up DNS records. None where it does not resolve.
     *
     * @param (callable(string): list<string>)|null $lookup stands in for DNS in tests
     * @return list<string>
     */
    public static function publicAddresses(string $name, ?callable $lookup = null): array
    {
        try {
            $addresses = ($lookup ?? self::lookup(...))($name);
        } catch (\Throwable) {
            return [];
        }
        return array_values(array_unique(array_filter($addresses, self::publicAddress(...))));
    }

    /**
     * Whether a name resolves to an address off the public internet. False when it does not resolve.
     *
     * @param (callable(string): list<string>)|null $lookup stands in for DNS in tests
     */
    public static function resolvesPrivately(string $name, ?callable $lookup = null): bool
    {
        try {
            $addresses = ($lookup ?? self::lookup(...))($name);
        } catch (\Throwable) {
            return false;
        }
        foreach ($addresses as $address) {
            if (!self::publicAddress($address)) {
                return true;
            }
        }
        return false;
    }

    /** @var (\Closure(string): list<string>)|null */
    private static ?\Closure $testLookup = null;

    /**
     * For tests: names are looked up here instead of in DNS, by every publicFetch not given a `lookup` of its
     * own. Every address is still checked. Null goes back to DNS.
     *
     * @param (callable(string): list<string>)|null $lookup
     */
    public static function lookupInTests(?callable $lookup): void
    {
        self::$testLookup = $lookup === null ? null : \Closure::fromCallable($lookup);
    }

    /**
     * Fetches an https URL on the public internet, following up to `redirects`
     * redirects that stay on it, within `timeoutMs` in all. Only a GET follows
     * redirects; anything else comes back with the redirect as it is. Throws a
     * PrivateAddressError for an address off it, and a FetchError with
     * `timedOut` when time runs out. A redirect past the last one comes back as
     * it is. `maxBytes` and `truncate` go to the Fetcher, for a capped read.
     * `lookup` stands in for DNS in tests.
     *
     * @param array{timeoutMs: int, method?: string, headers?: array<string, string>, body?: string, redirects?: int, maxBytes?: int, truncate?: bool, lookup?: callable(string): list<string>} $init
     */
    public static function publicFetch(string $target, array $init, ?Fetcher $fetcher = null): Response
    {
        $fetcher ??= new CurlFetcher();
        $lookup = $init['lookup'] ?? self::$testLookup ?? self::lookup(...);
        $method = strtoupper($init['method'] ?? 'GET');
        $redirects = $method === 'GET' ? ($init['redirects'] ?? 0) : 0;
        $until = hrtime(true) + $init['timeoutMs'] * 1_000_000;
        $url = new Url($target);
        for ($hop = 0; ; $hop++) {
            if ($url->protocol !== 'https:') {
                throw new PrivateAddressError($url->href());
            }
            $host = strtolower((string) preg_replace('/^\[|\]$/', '', $url->hostname));
            $literal = self::v4($host) !== null || self::v6($host) !== null;
            if ($literal && !self::publicAddress($host)) {
                throw new PrivateAddressError($host);
            }
            if ($host === 'localhost' || str_ends_with($host, '.localhost')) {
                throw new PrivateAddressError($host);
            }
            $pin = [];
            if (!$literal) {
                // The address checked is the address used: every one the name gives must be public, and the
                // connection is pinned to them, so a second lookup cannot hand back another.
                $addresses = $lookup($host);
                if ($addresses === []) {
                    throw new FetchError("getaddrinfo ENOTFOUND $host");
                }
                foreach ($addresses as $address) {
                    if (!self::publicAddress($address)) {
                        throw new PrivateAddressError($host);
                    }
                }
                $port = $url->port !== '' ? $url->port : '443';
                $pin = ["$host:$port:" . implode(',', array_map(static fn ($a) => str_contains($a, ':') ? "[$a]" : $a, $addresses))];
            }
            $left = (int) floor(($until - hrtime(true)) / 1_000_000);
            if ($left <= 0) {
                throw self::timedOut();
            }
            $options = ['method' => $method, 'headers' => $init['headers'] ?? [], 'redirect' => 'manual', 'timeoutMs' => $left];
            foreach (['body', 'maxBytes', 'truncate'] as $key) {
                if (isset($init[$key])) {
                    $options[$key] = $init[$key];
                }
            }
            if ($pin !== []) {
                $options['resolve'] = $pin;
            }
            try {
                $answer = $fetcher->fetch($url->href(), $options);
            } catch (FetchError $error) {
                // Whichever way the request gave up, the caller hears that time ran out.
                if ($error->timedOut || hrtime(true) >= $until) {
                    throw self::timedOut();
                }
                throw $error;
            }
            $location = $answer->headers->get('location');
            if ($answer->status < 300 || $answer->status >= 400 || $location === null || $location === '' || $hop >= $redirects) {
                return $answer;
            }
            $url = new Url($location, $url->href());
        }
    }

    /** An install on this machine: http://localhost or http://127.0.0.1, with any port. */
    private const LOCAL_INSTALL = '#^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)#';

    /**
     * Whether an address can be another Runlight install's: https, or, with `local`, an install on this machine,
     * which only code can allow.
     */
    public static function installAddress(string $url, bool $local): bool
    {
        return preg_match('#^https://[^/]+#', $url) === 1 || ($local && preg_match(self::LOCAL_INSTALL, $url) === 1);
    }

    /**
     * Fetches from another Runlight install, which someone signed in named: a public address as publicFetch
     * fetches it, with no redirect followed, so a token sent there goes nowhere else. With `local`, an install
     * on this machine is fetched as it is, still without following a redirect.
     *
     * @param array{timeoutMs: int, local: bool, method?: string, headers?: array<string, string>, body?: string, maxBytes?: int} $init
     */
    public static function installFetch(string $target, array $init, ?Fetcher $fetcher = null): Response
    {
        $local = $init['local'];
        unset($init['local']);
        if ($local && preg_match(self::LOCAL_INSTALL, $target)) {
            return ($fetcher ?? new CurlFetcher())->fetch($target, ['method' => 'GET', 'headers' => [], ...$init, 'redirect' => 'manual']);
        }
        return self::publicFetch($target, [...$init, 'redirects' => 0], $fetcher);
    }

    private static function timedOut(): FetchError
    {
        return new FetchError('The operation was aborted due to timeout', true);
    }
}
