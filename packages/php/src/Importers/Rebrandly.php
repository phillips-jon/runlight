<?php

declare(strict_types=1);

namespace Runlight\Importers;

/**
 * Rebrandly. Its API gives only total clicks, with no dates, so links come
 * across with their slugs and domains and start their history fresh.
 *
 * https://developers.rebrandly.com/docs
 */
final class Rebrandly implements Importer
{
    private const BASE = 'https://api.rebrandly.com/v1';
    private const PAGE = 25;

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
            throw new ImportError('Enter a Rebrandly API key', 'import_key', ['service' => 'Rebrandly']);
        }
        $headers = ['apikey' => $key];
        $workspace = Http::trim((string) ($credentials['workspace'] ?? ''));
        if ($workspace !== '') {
            $headers['workspace'] = $workspace;
        }
        $last = $cursor !== null && $cursor !== '' ? '&last=' . Http::encodeURIComponent($cursor) : '';
        $list = $this->http->getJson(self::BASE . '/links?orderBy=createdAt&orderDir=desc&limit=' . self::PAGE . $last, ['headers' => $headers]);
        $links = array_map(function ($l) {
            $created = Http::parseDate($l['createdAt'] ?? null);
            return ['link' => [
                'sourceId' => Http::str($l['id']), 'slug' => $l['slashtag'], 'domain' => Http::coalesce(Http::field(Http::field($l, 'domain'), 'fullName'), ''),
                'name' => Http::truthy($l['title'] ?? null) ? $l['title'] : '', 'url' => $l['destination'],
                'createdAt' => Http::truthy($created) ? $created : ($this->now)(),
            ]];
        }, $list);
        $end = $list === [] ? null : $list[count($list) - 1];
        return ['cursor' => count($list) === self::PAGE && Http::truthy($end) ? Http::str($end['id']) : null, 'total' => null, 'links' => $links];
    }
}
