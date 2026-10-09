<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Json;

/**
 * Short.io. Links are listed per domain. Daily click counts come from the
 * statistics API, paced to its limit of 60 requests a minute, so a step
 * holds only a few links.
 *
 * https://developers.short.io/reference
 */
final class Shortio implements Importer
{
    private const API = 'https://api.short.io';
    private const STATS = 'https://statistics.short.io/statistics';
    private const PAGE = 8;
    /** The statistics API allows 60 requests a minute. */
    private const STATS_GAP_MS = 1050;

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
            throw new ImportError('Enter a Short.io secret API key', 'import_key', ['service' => 'Short.io']);
        }
        $headers = ['authorization' => $key];
        if ($cursor !== null && $cursor !== '') {
            $state = Json::decode($cursor, true);
        } else {
            $domains = $this->http->getJson(self::API . '/api/domains?limit=300', ['headers' => $headers]);
            $state = [
                'domains' => array_map(static fn ($d) => ['id' => $d['id'], 'hostname' => $d['hostname']], $domains),
                'd' => 0,
                'token' => null,
                'total' => null,
            ];
        }
        $domain = $state['domains'][$state['d']] ?? null;
        if (!Http::truthy($domain)) {
            return ['cursor' => null, 'total' => null, 'links' => []];
        }

        $token = Http::truthy($state['token'] ?? null) ? '&pageToken=' . Http::encodeURIComponent(Http::str($state['token'])) : '';
        $page = $this->http->getJson(self::API . '/api/links?domain_id=' . Http::str($domain['id']) . '&limit=' . self::PAGE . $token, ['headers' => $headers]);

        $links = [];
        foreach ($page['links'] as $l) {
            $id = Http::str(Http::coalesce(Http::field($l, 'idString'), $l['id']));
            if ($known($id, $l['path'], $l['originalURL'])) {
                $links[] = ['link' => ['sourceId' => $id, 'slug' => $l['path'], 'domain' => '', 'name' => '', 'url' => $l['originalURL'], 'createdAt' => 0], 'known' => true];
                continue;
            }
            $daily = null;
            try {
                $this->http->pause(self::STATS_GAP_MS);
                $body = $this->http->getJson(self::STATS . '/link/' . Http::encodeURIComponent($id) . '/by_interval', [
                    'method' => 'POST',
                    'headers' => [...$headers, 'content-type' => 'application/json'],
                    'body' => Json::encode(['period' => 'total', 'clicksChartInterval' => 'day', 'tz' => 'UTC']),
                ]);
                $raw = $body['clickStatistics'] ?? null;
                $points = is_array($raw) && array_is_list($raw) ? $raw : (is_array($raw) ? ($raw['datasets'][0]['data'] ?? []) : []);
                $daily = [];
                foreach ($points as $p) {
                    if (self::positive($p['y'] ?? null)) {
                        $x = $p['x'] ?? null;
                        $ms = is_int($x) || is_float($x) ? $x : Http::parseDate($x);
                        // A point whose date cannot be read is left out, not the link.
                        try {
                            $day = substr(Http::isoString($ms), 0, 10);
                        } catch (\RangeException) {
                            continue;
                        }
                        $daily[] = ['day' => $day, 'clicks' => $p['y']];
                    }
                }
            } catch (HttpError $error) {
                if ($error->status === 401) {
                    throw $error;
                }
            }
            $created = Http::parseDate($l['createdAt'] ?? null);
            $item = ['link' => [
                'sourceId' => $id, 'slug' => $l['path'], 'domain' => $domain['hostname'], 'name' => Http::truthy($l['title'] ?? null) ? $l['title'] : '',
                'url' => $l['originalURL'], 'createdAt' => Http::truthy($created) ? $created : ($this->now)(),
            ]];
            if ($daily !== null) {
                $item['daily'] = $daily;
            }
            $links[] = $item;
        }

        $next = $page['nextPageToken'] ?? null;
        $more = Http::truthy($next)
            ? [...$state, 'token' => $next]
            : ($state['d'] + 1 < count($state['domains']) ? [...$state, 'd' => $state['d'] + 1, 'token' => null] : null);
        return ['cursor' => $more !== null ? Json::encode($more) : null, 'total' => null, 'links' => $links];
    }

    /** `y > 0` as JavaScript compares it. */
    private static function positive(mixed $y): bool
    {
        if (is_int($y) || is_float($y)) {
            return $y > 0;
        }
        if (is_string($y)) {
            return Http::number($y) > 0;
        }
        return $y === true;
    }
}
