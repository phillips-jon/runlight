<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Json;
use Runlight\Undefined;

/**
 * Umami v3 (and forks with custom link domains). Signs in with an API key,
 * or with a username and password (stock self-hosted Umami has no API keys).
 * In Umami a link's clicks are events stored under the link's id, with the
 * visitor's session holding place and device.
 */
final class Umami implements Importer
{
    private const PAGE = 5;

    private readonly Http $http;
    /** @var \Closure(): int */
    private readonly \Closure $now;

    /** @param (\Closure(): int)|null $now milliseconds */
    public function __construct(?Http $http = null, ?\Closure $now = null)
    {
        $this->http = $http ?? new Http();
        $this->now = $now ?? static fn (): int => (int) floor(microtime(true) * 1000);
    }

    /**
     * Signs in to an Umami: an API key, or a username and password (stock
     * self-hosted Umami has no API keys). A token from an earlier step is reused.
     * A token the sign-in did not give is Undefined, as TS's `login.token` is then.
     *
     * @param array<string, string> $credentials
     * @return array{base: string, token: mixed}
     */
    public static function umamiSignIn(Http $http, array $credentials, mixed $token = null): array
    {
        $base = (string) preg_replace('#/+$#', '', Http::trim((string) ($credentials['url'] ?? '')));
        if (!preg_match('#^https?://[^/]+#', $base)) {
            throw new ImportError('Enter your Umami address, like https://stats.example.com', 'import_umami_address');
        }
        $key = Http::trim((string) ($credentials['apiKey'] ?? ''));
        if ($key !== '' || Http::truthy($token)) {
            return ['base' => $base, 'token' => $key !== '' ? $key : $token];
        }
        if (($credentials['username'] ?? '') === '' || ($credentials['password'] ?? '') === '') {
            throw new ImportError('Enter an API key, or a username and password', 'import_umami_login');
        }
        $login = $http->getJson("$base/api/auth/login", [
            'method' => 'POST',
            'headers' => ['content-type' => 'application/json'],
            'body' => Json::encode(['username' => $credentials['username'], 'password' => $credentials['password']]),
        ]);
        return ['base' => $base, 'token' => Http::field($login, 'token')];
    }

    public function step(array $credentials, ?string $cursor, callable $known): array
    {
        // A key comes with every step; only a sign-in token, which expires, rides in the cursor.
        $saved = $cursor !== null && $cursor !== '' ? Json::decode($cursor, true) : ['page' => 1];
        $key = Http::trim((string) ($credentials['apiKey'] ?? ''));
        ['base' => $base, 'token' => $token] = self::umamiSignIn($this->http, $credentials, Http::field($saved, 'token'));
        $state = ['page' => Http::field($saved, 'page'), 'token' => $token];
        $headers = ['authorization' => 'Bearer ' . Http::str($state['token'])];
        $list = $this->http->getJson("$base/api/links?page=" . Http::str($state['page']) . '&pageSize=' . self::PAGE, ['headers' => $headers]);

        $all = function (string $path) use ($base, $headers): array {
            $out = [];
            for ($page = 1; ; $page++) {
                $body = $this->http->getJson("$base/api$path&page=$page&pageSize=1000", ['headers' => $headers]);
                array_push($out, ...$body['data']);
                if (count($out) >= ($body['count'] ?? INF) || $body['data'] === []) {
                    return $out;
                }
            }
        };

        $links = [];
        foreach ($list['data'] as $l) {
            if (Http::truthy($l['deletedAt'] ?? null)) {
                continue;
            }
            if ($known($l['id'], $l['slug'], $l['url'])) {
                $links[] = ['link' => ['sourceId' => $l['id'], 'slug' => $l['slug'], 'domain' => '', 'name' => $l['name'], 'url' => $l['url'], 'createdAt' => 0], 'known' => true];
                continue;
            }
            $created = Http::parseDate($l['createdAt'] ?? null);
            $created = Http::truthy($created) ? $created : ($this->now)();
            $range = 'startAt=' . Http::str($created - 86_400_000) . '&endAt=' . Http::str(($this->now)() + 60_000);
            // TS asks for both at once; here one follows the other.
            $events = $all("/websites/{$l['id']}/events?$range");
            $sessions = $all("/websites/{$l['id']}/sessions?$range");
            $info = [];
            foreach ($sessions as $s) {
                $info[Http::str($s['id'])] = $s;
            }
            $clicks = array_map(static function ($e) use ($info) {
                $s = $info[Http::str($e['sessionId'] ?? Undefined::value())] ?? Undefined::value();
                $domain = Http::field($e, 'referrerDomain');
                $path = Http::field($e, 'referrerPath');
                return Http::defined([
                    'ts' => Http::parseDate($e['createdAt'] ?? null),
                    'visit' => Http::field($e, 'sessionId'),
                    'referrer' => Http::truthy($domain) ? 'https://' . Http::str($domain) . (Http::truthy($path) ? Http::str($path) : '/') : '',
                    'path' => Http::field($e, 'urlPath'),
                    'query' => Http::field($e, 'urlQuery'),
                    'country' => Http::field($e, 'country'),
                    'region' => Http::field($s, 'region'),
                    'city' => Http::field($e, 'city'),
                    'browser' => Http::field($e, 'browser'),
                    'os' => Http::field($e, 'os'),
                    'device' => Http::field($e, 'device'),
                    'screen' => Http::field($s, 'screen'),
                    'language' => Http::field($s, 'language'),
                ]);
            }, $events);
            $links[] = [
                'link' => ['sourceId' => $l['id'], 'slug' => $l['slug'], 'domain' => Http::coalesce(Http::field(Http::field($l, 'customDomain'), 'domain'), ''), 'name' => $l['name'], 'url' => $l['url'], 'createdAt' => $created],
                'clicks' => $clicks,
            ];
        }
        $more = $state['page'] * self::PAGE < $list['count'] && count($list['data']) > 0;
        $next = $key !== '' ? ['page' => $state['page'] + 1] : ['page' => $state['page'] + 1, 'token' => $state['token']];
        return ['cursor' => $more ? Json::encode($next) : null, 'total' => $list['count'], 'links' => $links];
    }
}
