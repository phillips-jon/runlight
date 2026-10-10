<?php

declare(strict_types=1);

namespace Runlight\Http;

/**
 * An absolute http or https URL, parsed the way browsers and JavaScript's URL
 * do for those schemes: the host lowercased, backslashes read as slashes, dot
 * segments resolved, and the path and query percent-encoded with the WHATWG
 * sets, so a path recorded here matches what the tracker sent and what the
 * TypeScript SDK stores.
 */
final class Url
{
    public string $protocol;
    public string $username = '';
    public string $password = '';
    public string $hostname;
    public string $port;
    public string $pathname;
    public string $search;
    public string $hash;

    /** A URL of another scheme written with an authority, such as android-app://com.google.android.gm/. */
    private bool $hasAuthority = false;

    private const DEFAULT_PORTS = ['http:' => '80', 'https:' => '443', 'ws:' => '80', 'wss:' => '443', 'ftp:' => '21'];

    /** Throws \InvalidArgumentException when `$input` is not a URL, as `new URL()` throws a TypeError. */
    public function __construct(string $input, ?string $base = null)
    {
        $input = trim($input, "\x00..\x20");
        $input = str_replace(["\t", "\n", "\r"], '', $input);
        if (!preg_match('/^([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)$/s', $input, $m)) {
            if ($base === null) {
                throw new \InvalidArgumentException("Invalid URL: $input");
            }
            $this->resolve($input, new self($base));
            return;
        }
        $this->protocol = strtolower($m[1]) . ':';
        $rest = $m[2];
        if (!isset(self::DEFAULT_PORTS[$this->protocol])) {
            // Not a special scheme (mailto:, data:, javascript:): kept as it came.
            $this->hostname = '';
            $this->port = '';
            if (str_starts_with($rest, '//')) {
                // An authority after the scheme (android-app://com.google.android.gm/) is an opaque host, kept in its case.
                $rest = substr($rest, 2);
                $end = strcspn($rest, '/?#');
                $this->opaqueAuthority(substr($rest, 0, $end));
                $this->hasAuthority = true;
                $this->tail(substr($rest, $end), '');
                return;
            }
            [$rest, $this->hash] = self::cut($rest, '#');
            [$this->pathname, $this->search] = self::cut($rest, '?');
            return;
        }
        $rest = str_replace('\\', '/', $rest);
        $rest = ltrim($rest, '/');
        $end = strcspn($rest, '/?#');
        $this->authority(substr($rest, 0, $end));
        $this->tail(substr($rest, $end), '/');
    }

    public static function parse(string $input, ?string $base = null): ?self
    {
        try {
            return new self($input, $base);
        } catch (\InvalidArgumentException) {
            return null;
        }
    }

    public static function canParse(string $input, ?string $base = null): bool
    {
        return self::parse($input, $base) !== null;
    }

    public function host(): string
    {
        return $this->port === '' ? $this->hostname : "$this->hostname:$this->port";
    }

    public function origin(): string
    {
        return isset(self::DEFAULT_PORTS[$this->protocol]) ? "$this->protocol//" . $this->host() : 'null';
    }

    public function href(): string
    {
        if (!isset(self::DEFAULT_PORTS[$this->protocol]) && !$this->hasAuthority) {
            return $this->protocol . $this->pathname . $this->search . $this->hash;
        }
        $auth = $this->username !== '' || $this->password !== '' ? $this->username . ($this->password !== '' ? ":$this->password" : '') . '@' : '';
        return "$this->protocol//$auth" . $this->host() . $this->pathname . $this->search . $this->hash;
    }

    public function __toString(): string
    {
        return $this->href();
    }

    public function searchParams(): SearchParams
    {
        return new SearchParams($this->search);
    }

    /** Replaces the query with these parameters, as assigning url.search does. */
    public function setSearchParams(SearchParams $params): void
    {
        $text = $params->toString();
        $this->search = $text === '' ? '' : "?$text";
    }

    /** Replaces the path, as assigning url.pathname does: tabs and newlines dropped, and for http and https a backslash read as a slash. */
    public function setPathname(string $path): void
    {
        $path = str_replace(["\t", "\n", "\r"], '', $path);
        if (isset(self::DEFAULT_PORTS[$this->protocol])) {
            $path = str_replace('\\', '/', $path);
        }
        $this->pathname = self::path($path === '' || $path[0] !== '/' ? "/$path" : $path);
    }

    /**
     * Replaces the query, as assigning url.search does for http and https: one leading "?" is dropped and the
     * rest percent-encoded, and an empty value removes the query. A lone "?" leaves an empty query, which href
     * still writes, as JavaScript does.
     */
    public function setSearch(string $search): void
    {
        if ($search === '') {
            $this->search = '';
            return;
        }
        $search = str_replace(["\t", "\n", "\r"], '', $search);
        $this->search = '?' . self::query(str_starts_with($search, '?') ? substr($search, 1) : $search);
    }

    private function resolve(string $input, self $base): void
    {
        $this->protocol = $base->protocol;
        $input = isset(self::DEFAULT_PORTS[$this->protocol]) ? str_replace('\\', '/', $input) : $input;
        if (str_starts_with($input, '//')) {
            // A special scheme skips any further slashes before the host: ///x is the host x.
            $rest = isset(self::DEFAULT_PORTS[$this->protocol]) ? ltrim($input, '/') : substr($input, 2);
            $end = strcspn($rest, '/?#');
            $this->authority(substr($rest, 0, $end));
            $this->tail(substr($rest, $end), '/');
            return;
        }
        $this->username = $base->username;
        $this->password = $base->password;
        $this->hostname = $base->hostname;
        $this->port = $base->port;
        if ($input === '') {
            $this->pathname = $base->pathname;
            $this->search = $base->search;
            $this->hash = '';
            return;
        }
        if ($input[0] === '#') {
            $this->pathname = $base->pathname;
            $this->search = $base->search;
            $this->hash = strlen($input) > 1 ? '#' . self::fragment(substr($input, 1)) : '';
            return;
        }
        if ($input[0] === '?') {
            $this->pathname = $base->pathname;
            [$query, $hash] = self::cut(substr($input, 1), '#');
            $this->search = $query === '' ? '' : '?' . self::query($query);
            $this->hash = $hash === '' ? '' : '#' . self::fragment(substr($hash, 1));
            return;
        }
        if ($input[0] === '/') {
            $this->tail($input, '/');
            return;
        }
        $dir = substr($base->pathname, 0, (int) strrpos($base->pathname, '/') + 1);
        $this->tail($dir . $input, '/');
    }

    private function authority(string $authority): void
    {
        $at = strrpos($authority, '@');
        if ($at !== false) {
            $user = substr($authority, 0, $at);
            $authority = substr($authority, $at + 1);
            [$name, $pass] = self::cut($user, ':');
            $this->username = self::encode($name, self::USERINFO);
            $this->password = $pass === '' ? '' : self::encode(substr($pass, 1), self::USERINFO);
        }
        $port = '';
        if (str_starts_with($authority, '[')) {
            $close = strpos($authority, ']');
            if ($close === false) {
                throw new \InvalidArgumentException('Invalid URL');
            }
            $host = strtolower(substr($authority, 0, $close + 1));
            $after = substr($authority, $close + 1);
            if ($after !== '') {
                if ($after[0] !== ':') {
                    throw new \InvalidArgumentException('Invalid URL');
                }
                $port = substr($after, 1);
            }
        } else {
            $colon = strrpos($authority, ':');
            $host = $colon === false ? $authority : substr($authority, 0, $colon);
            $port = $colon === false ? '' : substr($authority, $colon + 1);
            $host = self::domain($host);
        }
        if ($host === '') {
            throw new \InvalidArgumentException('Invalid URL');
        }
        if ($port !== '') {
            if (!preg_match('/^[0-9]+\z/', $port) || (int) $port > 65535) {
                throw new \InvalidArgumentException('Invalid URL');
            }
            $port = (string) (int) $port;
            if ($port === self::DEFAULT_PORTS[$this->protocol]) {
                $port = '';
            }
        }
        $this->hostname = $host;
        $this->port = $port;
    }

    private function opaqueAuthority(string $authority): void
    {
        $at = strrpos($authority, '@');
        if ($at !== false) {
            [$name, $pass] = self::cut(substr($authority, 0, $at), ':');
            $this->username = self::encode($name, self::USERINFO);
            $this->password = $pass === '' ? '' : self::encode(substr($pass, 1), self::USERINFO);
            $authority = substr($authority, $at + 1);
        }
        $colon = strrpos($authority, ':');
        $host = $colon === false ? $authority : substr($authority, 0, $colon);
        $port = $colon === false ? '' : substr($authority, $colon + 1);
        if (preg_match('/[\x00 #\/:<>?@\[\\\\\]^|]/', $host) || ($port !== '' && (!preg_match('/^[0-9]+\z/', $port) || (int) $port > 65535))) {
            throw new \InvalidArgumentException('Invalid URL');
        }
        $this->hostname = self::encode($host, '');
        $this->port = $port === '' ? '' : (string) (int) $port;
    }

    private function tail(string $rest, string $empty): void
    {
        [$rest, $hash] = self::cut($rest, '#');
        [$path, $query] = self::cut($rest, '?');
        $this->pathname = $path === '' && $empty === '' ? '' : self::path($path === '' ? $empty : $path);
        $this->search = strlen($query) > 1 ? '?' . self::query(substr($query, 1)) : '';
        $this->hash = strlen($hash) > 1 ? '#' . self::fragment(substr($hash, 1)) : '';
    }

    /** @return array{string, string} the part before `$mark`, and the rest starting with it */
    private static function cut(string $text, string $mark): array
    {
        $at = strpos($text, $mark);
        return $at === false ? [$text, ''] : [substr($text, 0, $at), substr($text, $at)];
    }

    private static function domain(string $host): string
    {
        $host = rawurldecode($host);
        if (preg_match('/[\x00-\x20#%\/:<>?@\[\\\\\]^|]/', $host)) {
            throw new \InvalidArgumentException('Invalid URL');
        }
        $lower = mb_strtolower($host, 'UTF-8');
        if (preg_match('/[^\x00-\x7f]/', $lower)) {
            if (!function_exists('idn_to_ascii')) {
                throw new \InvalidArgumentException('Invalid URL');
            }
            $ascii = idn_to_ascii($lower, IDNA_NONTRANSITIONAL_TO_ASCII, INTL_IDNA_VARIANT_UTS46);
            if ($ascii === false) {
                throw new \InvalidArgumentException('Invalid URL');
            }
            $lower = $ascii;
        }
        $ipv4 = self::ipv4($lower);
        return $ipv4 ?? $lower;
    }

    /** A host written as an IPv4 address in any form browsers accept, normalised to dotted decimal. */
    private static function ipv4(string $host): ?string
    {
        $parts = explode('.', $host);
        if (end($parts) === '') {
            array_pop($parts);
        }
        if ($parts === [] || count($parts) > 4) {
            return null;
        }
        $last = end($parts);
        if (!preg_match('/^(0x[0-9a-f]*|[0-9]+)$/', $last)) {
            return null;
        }
        $numbers = [];
        foreach ($parts as $part) {
            if (preg_match('/^0x([0-9a-f]*)$/', $part, $m)) {
                $numbers[] = $m[1] === '' ? 0 : hexdec($m[1]);
            } elseif (preg_match('/^0[0-7]+$/', $part)) {
                $numbers[] = octdec($part);
            } elseif (preg_match('/^[0-9]+$/', $part)) {
                $numbers[] = (int) $part;
            } else {
                throw new \InvalidArgumentException('Invalid URL');
            }
        }
        $value = array_pop($numbers);
        foreach ($numbers as $n) {
            if ($n > 255) {
                throw new \InvalidArgumentException('Invalid URL');
            }
        }
        if ($value >= 256 ** (5 - count($parts))) {
            throw new \InvalidArgumentException('Invalid URL');
        }
        foreach ($numbers as $i => $n) {
            $value += $n * 256 ** (3 - $i);
        }
        return implode('.', [($value >> 24) & 255, ($value >> 16) & 255, ($value >> 8) & 255, $value & 255]);
    }

    private const PATH = " \"#<>?`{}";
    private const QUERY = " \"#<>'";
    private const FRAGMENT = " \"<>`";
    private const USERINFO = " \"#<>?`{}/:;=@[\\]^|";

    private static function path(string $path): string
    {
        $out = [];
        $segments = explode('/', $path);
        array_shift($segments);
        $count = count($segments);
        foreach ($segments as $i => $segment) {
            $lower = strtolower($segment);
            $last = $i === $count - 1;
            if ($lower === '..' || $lower === '.%2e' || $lower === '%2e.' || $lower === '%2e%2e') {
                array_pop($out);
                if ($last) {
                    $out[] = '';
                }
            } elseif ($lower === '.' || $lower === '%2e') {
                if ($last) {
                    $out[] = '';
                }
            } else {
                $out[] = self::encode($segment, self::PATH);
            }
        }
        return '/' . implode('/', $out);
    }

    private static function query(string $query): string
    {
        return self::encode($query, self::QUERY);
    }

    private static function fragment(string $fragment): string
    {
        return self::encode($fragment, self::FRAGMENT);
    }

    /** Percent-encodes C0 controls, DEL, bytes past ASCII, and `$extra`; existing escapes stay as written. */
    public static function encode(string $text, string $extra): string
    {
        if (!mb_check_encoding($text, 'UTF-8')) {
            $text = mb_convert_encoding($text, 'UTF-8', 'UTF-8');
        }
        $out = '';
        $length = strlen($text);
        for ($i = 0; $i < $length; $i++) {
            $c = $text[$i];
            $o = ord($c);
            $out .= $o < 0x21 || $o > 0x7e || str_contains($extra, $c) ? sprintf('%%%02X', $o) : $c;
        }
        return $out;
    }
}
