<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Data\Sources as Known;
use Runlight\Http\Url;

/**
 * Pages and where visits came from.
 *
 * A page is an array{hostname: string, path: string, utm: array{source: string, medium: string,
 * campaign: string, term: string, content: string}, ref: string, paid: bool}: `ref` is a `ref` or `source`
 * query parameter, used when there is no utm_source, and `paid` says a click id such as gclid was present
 * (the id itself is never kept). An attribution is an array{referrerHost: string, referrerPath: string,
 * source: string, channel: string}, the channel one of Direct, Organic Search, Paid Search, Social, Email,
 * AI, Referral, or Campaign.
 */
final class Sources
{
    private const CLICK_IDS = ['gclid', 'gbraid', 'wbraid', 'dclid', 'fbclid', 'msclkid', 'ttclid', 'twclid', 'li_fat_id', 'yclid'];
    private const PAID_MEDIUMS = '/^(cpc|ppc|paid|paidsearch|paid_search|paid-search|sem|cpm|cpv|display|banner|retargeting)$/D';
    private const EMAIL_MEDIUMS = '/^(e-?mail|newsletter|mail)$/D';
    private const SOCIAL_MEDIUMS = '/^(social|social-network|social-media|sm|social_network|social_media|paid_social|paid-social|paidsocial)$/D';

    /** @var array<string, array>|null */
    private static ?array $byHost = null;
    /** @var array<string, array> */
    private static array $byAlias = [];

    private static function maps(): void
    {
        if (self::$byHost !== null) {
            return;
        }
        // Later entries win, as Map.set does: the alias "kit" names Newsletter, not Kit.
        self::$byHost = [];
        foreach (Known::SOURCES as $source) {
            foreach ($source['hosts'] as $host) {
                self::$byHost[$host] = $source;
            }
            foreach ($source['aliases'] ?? [] as $alias) {
                self::$byAlias[$alias] = $source;
            }
        }
    }

    private static function clip(?string $value, int $max = 200): string
    {
        return Js::slice(Js::trim($value ?? ''), 0, $max);
    }

    public static function stripWww(string $host): string
    {
        $lower = Js::lower($host);
        return str_starts_with($lower, 'www.') ? substr($lower, 4) : $lower;
    }

    /**
     * The most specific known source for a host: mail.google.com before
     * google.com. Android apps send their package name as the referrer
     * (com.google.android.gm for Gmail), which is matched the same way. Hosts
     * known only by their shape (click trackers, webmail) come last.
     *
     * @return array{name: string, kind: string, hosts: list<string>, aliases?: list<string>}|null
     */
    public static function sourceForHost(string $host): ?array
    {
        self::maps();
        $clean = self::stripWww($host);
        $candidate = $clean;
        while (str_contains($candidate, '.')) {
            $found = self::$byHost[$candidate] ?? null;
            if ($found !== null) {
                return $found;
            }
            $candidate = substr($candidate, strpos($candidate, '.') + 1);
        }
        foreach (Known::SOURCE_PATTERNS as $rule) {
            if (preg_match($rule['pattern'], $clean)) {
                return ['name' => $rule['name'] ?? $clean, 'kind' => $rule['kind'], 'hosts' => []];
            }
        }
        return null;
    }

    /** @return array{name: string, kind: string, hosts: list<string>, aliases?: list<string>}|null */
    public static function sourceForAlias(string $value): ?array
    {
        self::maps();
        $key = Js::trim(Js::lower($value));
        return self::$byAlias[$key] ?? self::$byHost[self::stripWww($key)] ?? null;
    }

    /**
     * A path a person wrote, in the form paths are recorded: the path of a pasted URL, with a leading
     * slash, percent-encoded as the browser's URL parser encodes it, and with a hash route kept, as
     * parsePage keeps it. Null when it is not a path or a URL.
     */
    public static function recordedPath(string $input): ?string
    {
        $url = preg_match('/^https?:\/\//i', $input)
            ? Url::parse($input)
            : Url::parse(str_starts_with($input, '/') ? $input : "/$input", 'https://x.invalid');
        return $url === null ? null : self::parsePage($url)['path'];
    }

    /**
     * A recorded path as people write it, for showing and exporting: /caf%C3%A9 as /café. Only text is
     * decoded; an encoded slash, space, or other mark that would change the path's meaning stays as it is.
     */
    public static function readablePath(string $path): string
    {
        return (string) preg_replace_callback('/(?:%[0-9A-Fa-f]{2})+/', function (array $m): string {
            $text = Js::decodeURIComponent($m[0]);
            if ($text === null) {
                return $m[0];
            }
            return preg_match('/[' . Js::SPACE . '\/?#%\p{C}]/u', $text) ? $m[0] : $text;
        }, Js::scrub($path));
    }

    /** @return array{hostname: string, path: string, utm: array{source: string, medium: string, campaign: string, term: string, content: string}, ref: string, paid: bool} */
    public static function parsePage(Url $url): array
    {
        $q = $url->searchParams();
        $path = $url->pathname !== '' ? $url->pathname : '/';
        // The tracker only sends a hash when the site asked for hash routing.
        if (Js::length($url->hash) > 1) {
            $path .= $url->hash;
        }
        $paid = false;
        foreach (self::CLICK_IDS as $id) {
            if ($q->has($id)) {
                $paid = true;
                break;
            }
        }
        return [
            'hostname' => self::stripWww($url->hostname),
            'path' => Js::slice($path, 0, 1000),
            'utm' => [
                'source' => self::clip($q->get('utm_source')),
                'medium' => Js::lower(self::clip($q->get('utm_medium'))),
                'campaign' => self::clip($q->get('utm_campaign')),
                'term' => self::clip($q->get('utm_term')),
                'content' => self::clip($q->get('utm_content')),
            ],
            'ref' => self::clip($q->get('ref') ?? $q->get('source')),
            'paid' => $paid,
        ];
    }

    /**
     * Where a visit came from. `$internalHosts` are the site's own hostnames: a
     * referrer on one of them is navigation within the site, not a source.
     *
     * @param array{hostname: string, path: string, utm: array, ref: string, paid: bool} $page
     * @param list<string> $internalHosts
     * @return array{referrerHost: string, referrerPath: string, source: string, channel: string}
     */
    public static function attribute(array $page, string $referrer, array $internalHosts): array
    {
        $referrerHost = '';
        $referrerPath = '';
        if ($referrer !== '') {
            // Not a URL is treated as no referrer.
            $url = Url::parse($referrer);
            // Android apps refer as android-app://<package>/.
            if ($url !== null && in_array($url->protocol, ['http:', 'https:', 'android-app:'], true)) {
                $host = self::stripWww($url->hostname);
                if ($host !== $page['hostname'] && !in_array($host, $internalHosts, true)) {
                    $referrerHost = $host;
                    $referrerPath = $url->protocol === 'android-app:' ? '' : Js::slice($url->pathname, 0, 500);
                }
            }
        }

        $tagged = $page['utm']['source'] !== '' ? $page['utm']['source'] : $page['ref'];
        $known = $tagged !== '' ? self::sourceForAlias($tagged) : ($referrerHost !== '' ? self::sourceForHost($referrerHost) : null);
        $source = $known['name'] ?? ($tagged !== '' ? $tagged : $referrerHost);
        $kind = $known['kind'] ?? ($referrerHost !== '' ? (self::sourceForHost($referrerHost)['kind'] ?? null) : null);
        $medium = $page['utm']['medium'];

        if (($page['paid'] || preg_match(self::PAID_MEDIUMS, $medium)) && $kind === 'search') {
            $channel = 'Paid Search';
        } elseif ($kind === 'ai') {
            $channel = 'AI';
        } elseif (preg_match(self::EMAIL_MEDIUMS, $medium) || $kind === 'email') {
            $channel = 'Email';
        } elseif ($kind === 'search') {
            $channel = 'Organic Search';
        } elseif (preg_match(self::SOCIAL_MEDIUMS, $medium) || $kind === 'social') {
            $channel = 'Social';
        } elseif ($page['utm']['source'] !== '' || $page['utm']['medium'] !== '' || $page['utm']['campaign'] !== '') {
            $channel = 'Campaign';
        } elseif ($referrerHost !== '' || $page['ref'] !== '') {
            $channel = 'Referral';
        } else {
            $channel = 'Direct';
        }

        return ['referrerHost' => $referrerHost, 'referrerPath' => $referrerPath, 'source' => $source, 'channel' => $channel];
    }
}
