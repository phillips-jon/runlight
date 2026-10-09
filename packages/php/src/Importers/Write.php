<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Hash;
use Runlight\Http\Url;
use Runlight\Js;
use Runlight\Runlight;
use Runlight\Sources;
use Runlight\Store\SqlStore;

/** Writing an imported link and its history, and the names other tools use, in Runlight's spelling. */
final class Write
{
    /** Domains run by the shorteners themselves. Links there stay on Runlight's own path. */
    private const SHORTENER_DOMAINS = ['bit.ly', 'bitly.com', 'j.mp', 'dub.sh', 'dub.co', 'dub.link', 'short.gy', 'rebrand.ly', 'rebrandly.com', 'rb.gy'];

    // Browser and system names as other tools write them, in Runlight's spelling.
    public const BROWSERS = [
        'chrome' => 'Chrome', 'crios' => 'Chrome', 'chromium-webview' => 'Android WebView', 'chrome webview' => 'Android WebView', 'safari' => 'Safari', 'ios' => 'Safari', 'ios-webview' => 'Safari',
        'mobile safari' => 'Safari', 'firefox' => 'Firefox', 'fxios' => 'Firefox', 'edge' => 'Edge', 'edge-chromium' => 'Edge', 'edge-ios' => 'Edge', 'microsoft edge' => 'Edge',
        'opera' => 'Opera', 'opera-mini' => 'Opera', 'samsung' => 'Samsung Internet', 'samsung internet' => 'Samsung Internet', 'yandexbrowser' => 'Yandex Browser',
        'facebook' => 'Facebook', 'instagram' => 'Instagram', 'brave' => 'Brave', 'duckduckgo' => 'DuckDuckGo',
    ];
    public const SYSTEMS = [
        'mac os' => 'macOS', 'mac os x' => 'macOS', 'macos' => 'macOS', 'ios' => 'iOS', 'android os' => 'Android', 'android' => 'Android',
        'windows 10' => 'Windows', 'windows 11' => 'Windows', 'windows 7' => 'Windows', 'windows' => 'Windows', 'linux' => 'Linux', 'chrome os' => 'Chrome OS', 'chromium os' => 'Chrome OS',
    ];
    public const DEVICES = ['desktop' => 'desktop', 'laptop' => 'desktop', 'mobile' => 'mobile', 'smartphone' => 'mobile', 'phone' => 'mobile', 'tablet' => 'tablet'];

    public static function hexId(string $value, int $length = 24): string
    {
        return substr(Hash::sha256($value), 0, $length);
    }

    /** The Runlight id an imported link gets, from its source and its id there. */
    public static function importedLinkId(string $source, string $sourceId): string
    {
        return self::hexId("$source:$sourceId");
    }

    /** Two destinations are the same link when they differ only by a trailing slash. */
    public static function sameUrl(string $a, string $b): bool
    {
        return preg_replace('#/$#D', '', $a) === preg_replace('#/$#D', '', $b);
    }

    /** The first letter in upper case, as TS's title() does. */
    public static function title(string $v): string
    {
        return $v === '' ? '' : Js::upper(Js::slice($v, 0, 1)) . Js::slice($v, 1);
    }

    /** A browser name in Runlight's spelling: a known one, or the name with a capital first letter. */
    public static function browser(string $name): string
    {
        return self::BROWSERS[Js::lower($name)] ?? self::title($name);
    }

    /** A system name in Runlight's spelling, or the name as given. */
    public static function system(string $name): string
    {
        return self::SYSTEMS[Js::lower($name)] ?? $name;
    }

    public static function device(string $name): string
    {
        return self::DEVICES[Js::lower($name)] ?? '';
    }

    /** A field of a foreign click as text, '' where it is missing, as `c.field || ""` reads it. */
    private static function str(array $c, string $key): string
    {
        $value = $c[$key] ?? null;
        return Js::truthy($value) ? Js::string($value) : '';
    }

    /**
     * Writes one link and its history in a single transaction: the link (and its
     * branded domain), then each click as a visit like a live one, or daily
     * counts as clicks without visitors. Ids come from the source's own ids, so
     * importing again skips what is already there.
     *
     * @param array{sourceId: string, slug: string, domain: string, name: string, url: string, createdAt: int|float} $foreign
     * @param array{clicks?: list<array>, daily?: list<array{day: string, clicks: int|float}>} $history
     * @return array{status: string, clicks: int, reason?: string, code?: string, params?: array<string, string>}
     */
    public static function writeLink(Runlight $runlight, string $site, string $source, array $foreign, array $history): array
    {
        $id = self::importedLinkId($source, (string) $foreign['sourceId']);
        if ($runlight->store->linkById($id) !== null) {
            return ['status' => 'skipped', 'clicks' => 0];
        }
        $slug = (string) $foreign['slug'];
        $taken = $runlight->store->linkBySlug($slug);
        // The same slug to the same place is this link, brought in earlier some other way.
        if ($taken !== null && self::sameUrl($taken['url'], (string) $foreign['url'])) {
            return ['status' => 'skipped', 'clicks' => 0];
        }
        if ($taken !== null) {
            return ['status' => 'failed', 'clicks' => 0, 'reason' => "/$slug is already used by \"{$taken['name']}\"", 'code' => 'import_slug_taken', 'params' => ['slug' => $slug, 'name' => $taken['name']]];
        }
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/D', $slug)) {
            return ['status' => 'failed', 'clicks' => 0, 'reason' => "/$slug has characters Runlight slugs cannot use", 'code' => 'import_slug_bad', 'params' => ['slug' => $slug]];
        }

        $domain = Sources::stripWww(Js::truthy($foreign['domain'] ?? '') ? (string) $foreign['domain'] : '');
        if (in_array($domain, self::SHORTENER_DOMAINS, true)) {
            $domain = '';
        }
        $now = $runlight->now();
        $clicks = 0;
        // Nothing in the transaction is one link's own problem (those are checked above),
        // so a failure in it is the database's, and it stops the import rather than marking the link.
        $runlight->store->transaction(static function (SqlStore $store) use ($id, $site, $source, $foreign, $history, $slug, $domain, $now, &$clicks): void {
            // On a database without transactions (D1), a failed earlier try can have left
            // some of this link's clicks behind. Clear them, then write the link row last,
            // so a link only counts as imported once all of its history is in.
            $store->db->run("DELETE FROM rl_sessions WHERE id IN (SELECT DISTINCT session FROM rl_events WHERE link = ? AND session <> '')", [$id]);
            $store->db->run('DELETE FROM rl_events WHERE link = ?', [$id]);

            $made = [];
            foreach ($history['clicks'] ?? [] as $c) {
                $ts = $c['ts'] ?? NAN;
                if (!is_int($ts) && !(is_float($ts) && is_finite($ts))) {
                    continue;
                }
                $ts = (int) $ts;
                $visitKey = array_key_exists('visit', $c) && $c['visit'] !== null ? Js::string($c['visit']) : "$ts:$clicks";
                $session = self::hexId("$source:{$foreign['sourceId']}:$visitKey");
                // A visitor id lasts one day at most, as every other visitor id does.
                $visitor = self::hexId("$source:$visitKey:" . substr(Http::isoString($ts), 0, 10), 16);
                $path = self::str($c, 'path');
                if (!isset($made[$session])) {
                    $made[$session] = true;
                    $store->db->run('DELETE FROM rl_sessions WHERE id = ?', [$session]);
                    $host = $domain !== '' ? $domain : 'link.invalid';
                    $query = self::str($c, 'query');
                    $url = Url::parse("https://$host" . ($path !== '' ? $path : "/$slug") . ($query !== '' ? '?' . preg_replace('/^\?/', '', $query) : ''))
                        ?? new Url("https://$host/$slug");
                    $page = Sources::parsePage($url);
                    $country = Js::slice(Js::upper(self::str($c, 'country')), 0, 2);
                    $rawRegion = self::str($c, 'region');
                    $region = $rawRegion !== '' ? Js::slice(Js::upper(str_contains($rawRegion, '-') ? $rawRegion : "$country-$rawRegion"), 0, 10) : '';
                    $store->insertSession([
                        'id' => $session,
                        'site' => $site,
                        'visitor' => $visitor,
                        'startedAt' => $ts,
                        'hostname' => $page['hostname'],
                        ...Sources::attribute($page, Js::string($c['referrer'] ?? ''), []),
                        'utmSource' => $page['utm']['source'],
                        'utmMedium' => $page['utm']['medium'],
                        'utmCampaign' => $page['utm']['campaign'],
                        'utmTerm' => $page['utm']['term'],
                        'utmContent' => $page['utm']['content'],
                        'country' => preg_match('/^[A-Z]{2}$/D', $country) ? $country : '',
                        'region' => $country !== '' ? $region : '',
                        'city' => Js::slice(self::str($c, 'city'), 0, 100),
                        'browser' => self::browser(self::str($c, 'browser')),
                        'browserVersion' => '',
                        'os' => self::SYSTEMS[Js::lower(self::str($c, 'os'))] ?? Js::string($c['os'] ?? ''),
                        'osVersion' => '',
                        'device' => self::device(self::str($c, 'device')),
                        'screen' => Js::string($c['screen'] ?? ''),
                        'language' => Js::string($c['language'] ?? ''),
                    ]);
                    $store->db->run('UPDATE rl_sessions SET imported = 1 WHERE id = ?', [$session]);
                }
                $clickPath = $path !== '' ? $path : "/$slug";
                $store->touchSession($session, $ts, 'click', $clickPath);
                $store->insertEvent([
                    'site' => $site, 'ts' => $ts, 'kind' => 'click', 'visitor' => $visitor, 'session' => $session, 'pageview' => '', 'path' => Js::slice($clickPath, 0, 1000),
                    'hostname' => $domain, 'title' => '', 'name' => $slug, 'props' => null, 'engagedMs' => 0, 'scroll' => null, 'link' => $id,
                ]);
                $clicks++;
            }

            // Counts without detail: clicks spread through each day, with no visitor or visit.
            foreach ($history['daily'] ?? [] as $d) {
                $start = Http::parseDate("{$d['day']}T00:00:00Z");
                if (!is_finite((float) $start) || !($d['clicks'] > 0)) {
                    continue;
                }
                $n = min($d['clicks'], 1_000_000);
                for ($i = 0; $i < $n; $i++) {
                    $store->insertEvent([
                        'site' => $site, 'ts' => (int) $start + (int) floor((($i + 0.5) / $n) * 86_400_000), 'kind' => 'click', 'visitor' => '', 'session' => '', 'pageview' => '',
                        'path' => "/$slug", 'hostname' => $domain, 'title' => '', 'name' => $slug, 'props' => ['imported' => 'daily'], 'engagedMs' => 0, 'scroll' => null, 'link' => $id,
                    ]);
                    $clicks++;
                }
            }
            if ($domain !== '') {
                $store->addLinkDomain($domain, $site, $now);
            }
            $name = Js::truthy($foreign['name'] ?? '') ? (string) $foreign['name'] : $slug;
            $created = Js::truthy($foreign['createdAt'] ?? 0) ? (int) $foreign['createdAt'] : $now;
            $store->insertLink([
                'id' => $id,
                'site' => $site,
                'domain' => $domain,
                'slug' => $slug,
                'name' => Js::slice($name, 0, 100),
                'url' => $foreign['url'],
                'createdAt' => $created,
                'updatedAt' => $created,
            ]);
        });
        if ($domain !== '') {
            $runlight->forgetLinkDomains();
        }
        return ['status' => 'created', 'clicks' => $clicks];
    }
}
