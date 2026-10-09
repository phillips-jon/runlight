<?php

declare(strict_types=1);

namespace Runlight\Importers;

/**
 * One shortener. `step` does a bounded slice of work (a few links) and hands
 * back a cursor, so imports run in small requests that fit any host's time
 * limit and can show progress. Credentials come with every step and are
 * never stored.
 *
 * The shapes are TS's, as arrays with the same keys:
 * - ForeignLink: `sourceId` (the other service's id, so a re-run recognises the link), `slug`, `domain`
 *   (the short link's domain there; shortener-owned domains such as bit.ly and dub.sh are not kept),
 *   `name`, `url`, `createdAt` (ms).
 * - ForeignClick: `ts` (ms), and whichever of `visit` (groups clicks into one visit), `referrer`, `path`,
 *   `query` (path and query of the short URL as clicked, for campaign tags), `country`, `region`, `city`,
 *   `browser`, `os`, `device`, `screen`, and `language` the service knows. A field it does not know is left out.
 * - DailyClicks: `day` (YYYY-MM-DD, UTC) and `clicks`, for services that only keep counts.
 * - ImportStep: `cursor`, `done`, `total`, `links`, `clicks`, `skipped`, `failed`.
 */
interface Importer
{
    /**
     * @param array<string, string> $credentials
     * @param callable(string, ?string=, ?string=): bool $known Whether a link from this source is already in Runlight,
     *        so its history need not be fetched again: imported from this source before, or the same slug to the
     *        same destination brought in some other way.
     * @return array{cursor: ?string, total: ?int, links: list<array{link: array, clicks?: list<array>, daily?: list<array{day: string, clicks: int}>, known?: bool}>}
     */
    public function step(array $credentials, ?string $cursor, callable $known): array;
}
