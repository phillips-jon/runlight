<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Journeys: the paths visits take through a site, page by page. Each visit's
 * pages are read in order, a page seen twice in a row (a refresh) counts once,
 * and the path is cut to a number of steps, from a start page and to an end
 * page when those are chosen. The answer lines the paths up in columns, one
 * per step, with the flows between them, as Umami's journeys do.
 *
 * Options: steps, and optionally start, end, and through (array{step: int, value: string}: only paths that show
 * this page at this step, 0-based, to follow one page).
 *
 * The answer: visits; columns, each with items (the pages seen at this step, most visits first, with the rest as
 * "" for other pages), visits (that reached this step), and left (that went no further); links, visits moving from
 * a page at one step to a page at the next, "" being any other page; and paths, the commonest whole paths.
 */
final class Journeys
{
    /** How many pages of a visit to read: enough to find a start page and still have the steps after it. */
    public const PAGES_PER_VISIT = 40;
    private const TOP = 8;

    /**
     * @param iterable<array{session: string, path: string}> $rows
     * @param array{steps: int|float, start?: string, end?: string, through?: array{step: int|float, value: string}} $options
     * @return array{visits: int, columns: list<array{items: list<array{value: string, visits: int}>, visits: int, left: int}>, links: list<array{step: int, from: string, to: string, visits: int}>, paths: list<array{pages: list<string>, visits: int}>}
     */
    public static function journeys(iterable $rows, array $options): array
    {
        $floor = floor((float) ($options['steps'] ?? NAN));
        $steps = (int) min(max(is_nan($floor) || $floor == 0 ? 5 : $floor, 2), 8);
        // Group each visit's pages, dropping refreshes. Keys get a prefix so PHP keeps them as text.
        $visits = [];
        foreach ($rows as $row) {
            $key = 's' . $row['session'];
            $pages = $visits[$key] ?? [];
            if ($pages === [] || $pages[count($pages) - 1] !== $row['path']) {
                $pages[] = $row['path'];
            }
            $visits[$key] = $pages;
        }
        $start = $options['start'] ?? null;
        $end = $options['end'] ?? null;
        $through = $options['through'] ?? null;
        $sequences = [];
        // Visits that went on past the last step shown, so they never count as having gone no further.
        $cut = [];
        foreach ($visits as $pages) {
            if ($start !== null && $start !== '') {
                $at = array_search($start, $pages, true);
                if ($at === false) {
                    continue;
                }
                $pages = array_slice($pages, $at);
            }
            if ($end !== null && $end !== '') {
                $at = array_search($end, $pages, true);
                if ($at === false) {
                    continue;
                }
                $pages = array_slice($pages, 0, $at + 1);
            }
            $more = count($pages) > $steps;
            $pages = array_slice($pages, 0, $steps);
            if ($through !== null && self::at($pages, $through['step']) !== $through['value']) {
                continue;
            }
            $cut[count($sequences)] = $more;
            $sequences[] = $pages;
        }

        $columns = [];
        $kept = [];
        for ($i = 0; $i < $steps; $i++) {
            $counts = [];
            $reached = 0;
            $left = 0;
            foreach ($sequences as $n => $s) {
                if (count($s) <= $i) {
                    continue;
                }
                $reached++;
                if (count($s) === $i + 1 && !$cut[$n]) {
                    $left++;
                }
                $counts['p' . $s[$i]] = ($counts['p' . $s[$i]] ?? 0) + 1;
            }
            $sorted = [];
            foreach ($counts as $key => $count) {
                $sorted[] = [substr((string) $key, 1), $count];
            }
            usort($sorted, fn ($a, $b) => $b[1] - $a[1] ?: (Js::compare($a[0], $b[0]) < 0 ? -1 : 1));
            $top = array_slice($sorted, 0, self::TOP);
            $rest = 0;
            foreach (array_slice($sorted, self::TOP) as [, $v]) {
                $rest += $v;
            }
            $kept[] = array_fill_keys(array_map(fn ($entry) => 'p' . $entry[0], $top), true);
            if (!$reached) {
                break;
            }
            $items = array_map(fn ($entry) => ['value' => $entry[0], 'visits' => $entry[1]], $top);
            if ($rest) {
                $items[] = ['value' => '', 'visits' => $rest];
            }
            $columns[] = ['items' => $items, 'visits' => $reached, 'left' => $left];
        }

        $linkCounts = [];
        foreach ($sequences as $s) {
            for ($i = 0; $i + 1 < count($s) && $i + 1 < count($columns); $i++) {
                $from = isset($kept[$i]['p' . $s[$i]]) ? $s[$i] : '';
                $to = isset($kept[$i + 1]['p' . $s[$i + 1]]) ? $s[$i + 1] : '';
                $key = "$i\0$from\0$to";
                $linkCounts[$key] ??= ['step' => $i, 'from' => $from, 'to' => $to, 'visits' => 0];
                $linkCounts[$key]['visits']++;
            }
        }
        $links = array_values($linkCounts);
        // Ties go by page, as the columns and paths do, so the order never follows the visits' random ids.
        usort($links, fn ($a, $b) => $a['step'] - $b['step'] ?: $b['visits'] - $a['visits'] ?: Js::compare($a['from'], $b['from']) ?: Js::compare($a['to'], $b['to']));

        $pathCounts = [];
        foreach ($sequences as $s) {
            $key = 'p' . implode("\0", $s);
            $pathCounts[$key] ??= ['key' => substr($key, 1), 'pages' => $s, 'visits' => 0];
            $pathCounts[$key]['visits']++;
        }
        $paths = array_values($pathCounts);
        usort($paths, fn ($x, $y) => $y['visits'] - $x['visits'] ?: (Js::compare($x['key'], $y['key']) < 0 ? -1 : 1));
        $paths = array_map(fn ($p) => ['pages' => $p['pages'], 'visits' => $p['visits']], array_slice($paths, 0, 20));

        return ['visits' => count($sequences), 'columns' => $columns, 'links' => $links, 'paths' => $paths];
    }

    /** pages[step], which is undefined for a step that is not a whole number in range. */
    private static function at(array $pages, int|float $step): ?string
    {
        if (is_float($step)) {
            if ($step != floor($step)) {
                return null;
            }
            $step = (int) $step;
        }
        return $pages[$step] ?? null;
    }
}
