<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Json;
use Runlight\Undefined;

/**
 * Dub. Links come from GET /links (cursor pages of up to 100, archived
 * included). Click history is per click from /events where the plan allows,
 * else daily counts from /analytics, else none; the first link decides.
 * What the account's plan lets us read rides in the cursor as `history`:
 * "events" (Business), "daily" (Pro), "none" (Free), or null before the first link.
 *
 * https://dub.co/docs/api-reference
 */
final class Dub implements Importer
{
    private const BASE = 'https://api.dub.co';
    private const PAGE = 10;

    private readonly Http $http;
    /** @var \Closure(): int */
    private readonly \Closure $now;

    /** @param (\Closure(): int)|null $now milliseconds */
    public function __construct(?Http $http = null, ?\Closure $now = null)
    {
        $this->http = $http ?? new Http();
        $this->now = $now ?? static fn (): int => (int) floor(microtime(true) * 1000);
    }

    public function step(array $credentials, ?string $cursor, callable $known): array
    {
        $key = Http::trim((string) ($credentials['apiKey'] ?? ''));
        if ($key === '') {
            throw new ImportError('Enter a Dub API key', 'import_key', ['service' => 'Dub']);
        }
        $headers = ['authorization' => "Bearer $key"];
        $state = $cursor !== null && $cursor !== '' ? Json::decode($cursor, true) : ['after' => null, 'history' => null];
        $history = Http::field($state, 'history');
        $after = Http::truthy($state['after'] ?? null) ? '&startingAfter=' . Http::encodeURIComponent(Http::str($state['after'])) : '';
        $list = $this->http->getJson(self::BASE . '/links?pageSize=' . self::PAGE . "&showArchived=true$after", ['headers' => $headers]);

        $links = [];
        foreach ($list as $l) {
            if ($known($l['id'], $l['key'], $l['url'])) {
                $links[] = ['link' => ['sourceId' => $l['id'], 'slug' => $l['key'], 'domain' => '', 'name' => '', 'url' => $l['url'], 'createdAt' => 0], 'known' => true];
                continue;
            }
            $clicks = null;
            $daily = null;
            if ($history === null || $history === 'events') {
                try {
                    $clicks = [];
                    for ($page = 1; ; $page++) {
                        $events = $this->http->getJson(
                            self::BASE . '/events?event=clicks&linkId=' . Http::encodeURIComponent($l['id']) . "&interval=all&sortOrder=asc&limit=1000&page=$page",
                            ['headers' => $headers],
                        );
                        foreach ($events as $e) {
                            $click = Http::field($e, 'click');
                            $referer = Http::field($click, 'referer');
                            $refererUrl = Http::field($click, 'refererUrl');
                            $device = Http::field($click, 'device');
                            $clicks[] = Http::defined([
                                'ts' => Http::parseDate($e['timestamp'] ?? null),
                                'visit' => Http::field($click, 'id'),
                                'referrer' => Http::truthy($refererUrl) ? $refererUrl : (Http::truthy($referer) && $referer !== '(direct)' ? 'https://' . Http::str($referer) . '/' : ''),
                                'country' => Http::field($click, 'country'),
                                'region' => Http::field($click, 'region'),
                                'city' => Http::field($click, 'city'),
                                'device' => is_string($device) ? mb_strtolower($device) : Undefined::value(),
                                'browser' => Http::field($click, 'browser'),
                                'os' => Http::field($click, 'os'),
                            ]);
                        }
                        if (count($events) < 1000) {
                            break;
                        }
                    }
                    $history = 'events';
                } catch (HttpError $error) {
                    if (!self::planRefused($error)) {
                        throw $error;
                    }
                    $clicks = null;
                    $history = 'daily';
                }
            }
            if ($history === 'daily') {
                try {
                    $series = $this->http->getJson(
                        self::BASE . '/analytics?event=clicks&groupBy=timeseries&interval=all&linkId=' . Http::encodeURIComponent($l['id']),
                        ['headers' => $headers],
                    );
                    $daily = [];
                    foreach ($series as $p) {
                        if ($p['clicks'] > 0) {
                            $daily[] = ['day' => substr($p['start'], 0, 10), 'clicks' => $p['clicks']];
                        }
                    }
                } catch (HttpError $error) {
                    if (!self::planRefused($error)) {
                        throw $error;
                    }
                    $history = 'none';
                }
            }
            $created = Http::parseDate($l['createdAt'] ?? null);
            $item = ['link' => [
                'sourceId' => $l['id'], 'slug' => $l['key'], 'domain' => $l['domain'], 'name' => Http::truthy($l['title'] ?? null) ? $l['title'] : '',
                'url' => $l['url'], 'createdAt' => Http::truthy($created) ? $created : ($this->now)(),
            ]];
            if ($clicks !== null) {
                $item['clicks'] = $clicks;
            }
            if ($daily !== null) {
                $item['daily'] = $daily;
            }
            $links[] = $item;
        }
        $last = $list === [] ? null : $list[count($list) - 1];
        return [
            'cursor' => count($list) === self::PAGE && Http::truthy($last) ? Json::encode(['after' => $last['id'], 'history' => $history]) : null,
            'total' => null,
            'links' => $links,
        ];
    }

    /**
     * Whether Dub said the plan does not include what was asked (403, or 402).
     * Any other failure (a server error that outlasts the retries, say) fails
     * the step and leaves the history mode as it was.
     */
    private static function planRefused(HttpError $error): bool
    {
        return $error->status === 403 || $error->status === 402;
    }
}
