<?php

declare(strict_types=1);

namespace Runlight\Importers;

use Runlight\Js;
use Runlight\Runlight;

/** Link imports from other shorteners, a step at a time. */
final class Index
{
    /** The sources a link import can read, by name. */
    public const IMPORTERS = ['umami' => Umami::class, 'dub' => Dub::class, 'bitly' => Bitly::class, 'shortio' => Shortio::class, 'rebrandly' => Rebrandly::class];

    /**
     * One step of an import: fetch the next few links from the source, write
     * each with its history, and report progress. The cursor carries where to
     * pick up, so the page calls this until the cursor comes back null.
     *
     * Each importer makes its requests through the Runlight's fetcher, and reads the Runlight's clock as its
     * `now`: the date of a link the source gives none for, and where Umami's history ends.
     *
     * @param array<string, string> $credentials
     * @return array{cursor: ?string, done: int|float, total: int|float|null, links: int, clicks: int, skipped: int, failed: list<array{slug: string, reason: string, code?: string, params?: array<string, string>}>}
     */
    public static function importStep(Runlight $runlight, string $site, string $source, array $credentials, ?string $cursor, int|float $done): array
    {
        $class = self::IMPORTERS[$source] ?? null;
        if ($class === null) {
            throw new ImportError("Runlight cannot import from $source", 'import_source', ['source' => $source]);
        }
        $runlight->init();
        /** @var Importer $importer */
        $importer = new $class(new Http($runlight->fetcher), static fn (): int => $runlight->now());
        $known = static function (mixed $sourceId, mixed $slug = null, mixed $url = null) use ($runlight, $source): bool {
            if ($runlight->store->linkById(Write::importedLinkId($source, Js::string($sourceId))) !== null) {
                return true;
            }
            if (!Js::truthy($slug) || !Js::truthy($url)) {
                return false;
            }
            $taken = $runlight->store->linkBySlug(Js::string($slug));
            return $taken !== null && Write::sameUrl($taken['url'], Js::string($url));
        };
        $result = $importer->step($credentials, $cursor, $known);
        // A total that is not a number is as good as none.
        $total = $result['total'] ?? null;
        $total = is_int($total) || (is_float($total) && is_finite($total)) ? $total : null;
        $step = ['cursor' => $result['cursor'], 'done' => $done, 'total' => $total, 'links' => 0, 'clicks' => 0, 'skipped' => 0, 'failed' => []];
        foreach ($result['links'] as $item) {
            if (!empty($item['known'])) {
                $step['done']++;
                $step['skipped']++;
                continue;
            }
            $written = Write::writeLink($runlight, $site, $source, $item['link'], $item);
            $step['done']++;
            if ($written['status'] === 'created') {
                $step['links']++;
                $step['clicks'] += $written['clicks'];
            } elseif ($written['status'] === 'skipped') {
                $step['skipped']++;
            } else {
                $step['failed'][] = ['slug' => $item['link']['slug'], 'reason' => $written['reason'] ?? '', ...(isset($written['code']) ? ['code' => $written['code'], 'params' => $written['params'] ?? []] : [])];
            }
        }
        // Links the source skipped (deleted ones) still count toward progress.
        if (($result['cursor'] === null || $result['cursor'] === '') && $total !== null) {
            $step['done'] = max($step['done'], $total);
        }
        return $step;
    }
}
