<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Fetcher;
use Runlight\Http\Response;
use Runlight\Http\Url;

/**
 * A site's icon, for the dashboard header: the best icon its home page
 * links to, or /favicon.ico. Fetched from the site's own configured origin
 * (never from request input), cached for a day.
 *
 * PHP forgets everything between requests, so the cache lives in APCu when it
 * is loaded, else in one small file per origin in the system's temporary
 * folder, else only for this process. An icon is `['body' => bytes, 'type' => media type]`.
 */
final class Icon
{
    private const TIMEOUT_MS = 4000;
    private const MAX_BYTES = 256 * 1024;
    private const DAY = 86_400_000;
    /** A few hundred sites at most; past that the oldest go, so the cache cannot grow without end. */
    private const CACHE_SIZE = 500;

    /** @var array<string, array{at: int, icon: array{body: string, type: string}|null}> */
    private static array $cache = [];

    private static function attr(string $tag, string $name): string
    {
        $found = preg_match('/\b' . $name . '\s*=\s*("([^"]*)"|\'([^\']*)\'|([^\s>]+))/i', $tag, $match);
        if (!$found) {
            return '';
        }
        foreach ([2, 3, 4] as $i) {
            if (isset($match[$i]) && $match[$i] !== '') {
                return Mail\Transports::trim($match[$i]);
            }
        }
        // An empty quoted value matched.
        return '';
    }

    /**
     * Icon URLs a page links to, best first: apple-touch-icon, then SVG and PNG icons, then any icon.
     *
     * @return list<string>
     */
    public static function iconLinks(string $html, string $base): array
    {
        $found = [];
        preg_match_all('/<link\b[^>]*>/i', $html, $tags);
        foreach ($tags[0] as $tag) {
            $rel = preg_split('/\s+/', mb_strtolower(self::attr($tag, 'rel'))) ?: [];
            $href = self::attr($tag, 'href');
            if ($href === '' || !(in_array('icon', $rel, true) || in_array('apple-touch-icon', $rel, true))) {
                continue;
            }
            $parsed = Url::parse($href, $base);
            if ($parsed === null) {
                continue;
            }
            $url = $parsed->href();
            // Only https, which is all the fetch below takes.
            if (!str_starts_with($url, 'https://')) {
                continue;
            }
            $type = mb_strtolower(self::attr($tag, 'type'));
            $score = in_array('apple-touch-icon', $rel, true) ? 3 : (str_contains($type, 'svg') || str_ends_with($url, '.svg') ? 2 : (str_contains($type, 'png') || str_ends_with($url, '.png') ? 1 : 0));
            $found[] = ['url' => $url, 'score' => $score];
        }
        // usort is stable, as Array.prototype.sort is.
        usort($found, static fn ($a, $b) => $b['score'] <=> $a['score']);
        return array_map(static fn ($f) => $f['url'], $found);
    }

    /** A GET of a public https address, with redirects followed only to public addresses too. */
    private static function get(string $url, ?Fetcher $fetcher, array $read): ?Response
    {
        try {
            return Safefetch::publicFetch($url, ['timeoutMs' => self::TIMEOUT_MS, 'redirects' => 3, 'headers' => ['user-agent' => 'Runlight (+https://runlight.sh)'], ...$read], $fetcher);
        } catch (\Throwable) {
            return null;
        }
    }

    /** @return array{body: string, type: string}|null */
    private static function image(string $url, ?Fetcher $fetcher): ?array
    {
        // An image must arrive whole, so one longer than the cap is no use.
        $response = self::get($url, $fetcher, ['maxBytes' => self::MAX_BYTES]);
        if ($response === null || !$response->ok()) {
            return null;
        }
        $type = mb_strtolower(Mail\Transports::trim(explode(';', $response->headers->get('content-type') ?? '')[0]));
        if (!str_starts_with($type, 'image/')) {
            return null;
        }
        $declared = $response->headers->get('content-length');
        if ($declared !== null && is_numeric(trim($declared)) && (float) trim($declared) > self::MAX_BYTES) {
            return null;
        }
        $body = $response->text();
        if ($body === '' || strlen($body) > self::MAX_BYTES) {
            return null;
        }
        return ['body' => $body, 'type' => $type];
    }

    /**
     * The site's icon, or null when it has none that can be fetched.
     *
     * @param int|null $now milliseconds; the clock when null
     * @param string|null $dir where the file cache goes; the system's temporary folder when null
     * @return array{body: string, type: string}|null
     */
    public static function fetchIcon(string $origin, ?int $now = null, ?Fetcher $fetcher = null, ?string $dir = null): ?array
    {
        $now ??= (int) floor(microtime(true) * 1000);
        $cached = self::cached($origin, $dir);
        if ($cached !== null && $now - $cached['at'] < ($cached['icon'] !== null ? self::DAY : intdiv(self::DAY, 24))) {
            return $cached['icon'];
        }
        // TS shares one lookup among dashboards opening at once; a PHP request is alone, so it looks itself.
        $icon = self::lookUp($origin, $fetcher);
        self::store($origin, ['at' => $now, 'icon' => $icon], $dir);
        return $icon;
    }

    /** @return array{body: string, type: string}|null */
    private static function lookUp(string $origin, ?Fetcher $fetcher): ?array
    {
        $icon = null;
        // The head is all that is needed, so a huge page is not read to the end.
        $page = self::get("$origin/", $fetcher, ['maxBytes' => 200_000, 'truncate' => true]);
        if ($page !== null && $page->ok() && str_contains($page->headers->get('content-type') ?? '', 'html')) {
            $html = Body::utf8($page->text());
            // A Response from the Fetcher has no url of its own, as the one Node's https module gives, so links resolve against the origin.
            foreach (array_slice(self::iconLinks($html, $origin), 0, 4) as $url) {
                $icon = self::image($url, $fetcher);
                if ($icon !== null) {
                    break;
                }
            }
        }
        return $icon ?? self::image("$origin/favicon.ico", $fetcher);
    }

    /** @return array{at: int, icon: array{body: string, type: string}|null}|null */
    private static function cached(string $origin, ?string $dir): ?array
    {
        if (isset(self::$cache[$origin])) {
            return self::$cache[$origin];
        }
        $key = 'runlight:icon:' . hash('sha256', $origin);
        if (function_exists('apcu_enabled') && apcu_enabled()) {
            $hit = apcu_fetch($key, $ok);
            return $ok && is_array($hit) ? $hit : null;
        }
        $file = self::file($origin, $dir);
        $text = $file !== null ? @file_get_contents($file) : false;
        $saved = is_string($text) ? json_decode($text, true) : null;
        if (!is_array($saved) || !isset($saved['at'])) {
            return null;
        }
        $body = isset($saved['body']) ? base64_decode((string) $saved['body'], true) : false;
        return ['at' => (int) $saved['at'], 'icon' => $body === false || !isset($saved['type']) ? null : ['body' => $body, 'type' => (string) $saved['type']]];
    }

    /** @param array{at: int, icon: array{body: string, type: string}|null} $entry */
    private static function store(string $origin, array $entry, ?string $dir): void
    {
        unset(self::$cache[$origin]);
        self::$cache[$origin] = $entry;
        if (count(self::$cache) > self::CACHE_SIZE) {
            unset(self::$cache[array_key_first(self::$cache)]);
        }
        if (function_exists('apcu_enabled') && apcu_enabled()) {
            apcu_store('runlight:icon:' . hash('sha256', $origin), $entry, intdiv(self::DAY, 1000));
            return;
        }
        $file = self::file($origin, $dir);
        if ($file === null) {
            return;
        }
        $saved = ['at' => $entry['at']] + ($entry['icon'] !== null ? ['type' => $entry['icon']['type'], 'body' => base64_encode($entry['icon']['body'])] : []);
        @file_put_contents($file, (string) json_encode($saved), LOCK_EX);
        // Past the cap the oldest files go.
        $files = glob(dirname($file) . '/*.json') ?: [];
        if (count($files) > self::CACHE_SIZE) {
            usort($files, static fn ($a, $b) => (@filemtime($a) ?: 0) <=> (@filemtime($b) ?: 0));
            foreach (array_slice($files, 0, count($files) - self::CACHE_SIZE) as $old) {
                @unlink($old);
            }
        }
    }

    private static function file(string $origin, ?string $dir): ?string
    {
        $dir = ($dir ?? sys_get_temp_dir()) . '/runlight-icons';
        if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
            return null;
        }
        return "$dir/" . hash('sha256', $origin) . '.json';
    }
}
