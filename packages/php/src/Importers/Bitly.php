<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Json;

/**
 * Bitly. Links are listed per group (every group in the account), with
 * archived ones. Bitly only keeps daily click counts, and only as far back
 * as the account's plan allows. A custom back-half or branded domain wins
 * over the random bit.ly one.
 *
 * https://dev.bitly.com/api-reference
 */
final class Bitly implements Importer
{
    private const BASE = 'https://api-ssl.bitly.com/v4';
    private const PAGE = 20;

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
     * A short URL's domain and back-half, from "bit.ly/abc" or "https://t.brand.com/sale".
     *
     * @return array{domain: string, slug: string}
     */
    private static function split(string $value): array
    {
        $bare = (string) preg_replace('#^https?://#', '', $value);
        $at = strpos($bare, '/');
        return $at === false ? ['domain' => $bare, 'slug' => ''] : ['domain' => substr($bare, 0, $at), 'slug' => (string) preg_replace('#/$#', '', substr($bare, $at + 1))];
    }

    public function step(array $credentials, ?string $cursor, callable $known): array
    {
        $token = Http::trim((string) ($credentials['token'] ?? ''));
        $token = $token !== '' ? $token : Http::trim((string) ($credentials['apiKey'] ?? ''));
        if ($token === '') {
            throw new ImportError('Enter a Bitly access token', 'import_key', ['service' => 'Bitly']);
        }
        $headers = ['authorization' => "Bearer $token"];
        if ($cursor !== null && $cursor !== '') {
            $state = Json::decode($cursor, true);
        } else {
            $groups = $this->http->getJson(self::BASE . '/groups', ['headers' => $headers])['groups'];
            $state = ['groups' => array_map(static fn ($g) => $g['guid'], $groups), 'g' => 0, 'after' => null];
        }
        $group = $state['groups'][$state['g']] ?? null;
        if (!Http::truthy($group)) {
            return ['cursor' => null, 'total' => null, 'links' => []];
        }

        $after = Http::truthy($state['after'] ?? null) ? '&search_after=' . Http::encodeURIComponent(Http::str($state['after'])) : '';
        $page = $this->http->getJson(self::BASE . '/groups/' . Http::str($group) . '/bitlinks?size=' . self::PAGE . "&archived=both$after", ['headers' => $headers]);

        $links = [];
        foreach ($page['links'] as $b) {
            if (Http::truthy($b['is_deleted'] ?? null)) {
                continue;
            }
            $short = self::split((string) Http::coalesce(Http::field($b['custom_bitlinks'] ?? null, 0), $b['id']));
            if ($known($b['id'], $short['slug'], $b['long_url'])) {
                $links[] = ['link' => ['sourceId' => $b['id'], 'slug' => '', 'domain' => '', 'name' => '', 'url' => $b['long_url'], 'createdAt' => 0], 'known' => true];
                continue;
            }
            $daily = null;
            try {
                $clicks = $this->http->getJson(self::BASE . '/bitlinks/' . Http::encodeURIComponent($b['id']) . '/clicks?unit=day&units=-1', ['headers' => $headers]);
                $daily = [];
                foreach ($clicks['link_clicks'] as $c) {
                    if ($c['clicks'] > 0) {
                        $daily[] = ['day' => substr($c['date'], 0, 10), 'clicks' => $c['clicks']];
                    }
                }
            } catch (HttpError $error) {
                // Plans without analytics refuse this; the link still comes across.
                if ($error->status === 401) {
                    throw $error;
                }
            }
            $created = Http::parseDate($b['created_at'] ?? null);
            $item = ['link' => [
                'sourceId' => $b['id'], 'slug' => $short['slug'], 'domain' => $short['domain'], 'name' => Http::truthy($b['title'] ?? null) ? $b['title'] : '',
                'url' => $b['long_url'], 'createdAt' => Http::truthy($created) ? $created : ($this->now)(),
            ]];
            if ($daily !== null) {
                $item['daily'] = $daily;
            }
            $links[] = $item;
        }

        $searchAfter = $page['pagination']['search_after'] ?? null;
        $next = Http::truthy($searchAfter) && count($page['links']) === self::PAGE ? $searchAfter : null;
        $more = $next !== null
            ? [...$state, 'after' => $next]
            : ($state['g'] + 1 < count($state['groups']) ? [...$state, 'g' => $state['g'] + 1, 'after' => null] : null);
        return ['cursor' => $more !== null ? Json::encode($more) : null, 'total' => null, 'links' => $links];
    }
}
