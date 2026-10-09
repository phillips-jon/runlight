<?php

declare(strict_types=1);

namespace Runlight;

/** Funnels: checking one from the dashboard. Counting is the store's funnelCounts(). */
final class Funnels
{
    /**
     * Checks and tidies a funnel from the dashboard: a name, and two to eight
     * steps, each a page (with * as a wildcard) or an event name.
     *
     * @param list<array> $existing FunnelRows
     * @return array{id: string, site: string, name: string, steps: list<array{kind: string, match: string}>, createdAt: int}
     * @throws FunnelError
     */
    public static function funnelFrom(array|\stdClass $input, string $site, array $existing, int $now, ?string $id = null): array
    {
        $name = Js::cut(Js::trim(Goals::field($input, 'name')), 80);
        if ($name === '') {
            throw new FunnelError('Give the funnel a name', 'funnel_name');
        }
        foreach ($existing as $f) {
            if ($f['id'] !== $id && Js::lower($f['name']) === Js::lower($name)) {
                throw new FunnelError("There is already a funnel called \"$name\"", 'funnel_exists', ['name' => $name]);
            }
        }
        $raw = Js::get($input, 'steps');
        $raw = is_array($raw) && array_is_list($raw) ? $raw : [];
        $steps = [];
        foreach ($raw as $item) {
            // Anything that is not an object reads as one with no fields.
            $step = $item instanceof \stdClass || is_array($item) ? $item : [];
            $kind = Js::get($step, 'kind') === 'event' ? 'event' : 'page';
            $match = Js::cut(Js::trim(Goals::field($step, 'match')), 500);
            if ($match === '') {
                continue;
            }
            if ($kind === 'page') {
                // A full URL is fine to paste; the path is what counts.
                $path = Goals::pagePattern($match);
                if ($path === null) {
                    throw new FunnelError("\"$match\" is not a path or a URL", 'funnel_page_bad', ['match' => $match]);
                }
                $match = $path;
            }
            $steps[] = ['kind' => $kind, 'match' => $match];
        }
        if (count($steps) < 2) {
            throw new FunnelError('A funnel needs at least two steps', 'funnel_short');
        }
        if (count($steps) > 8) {
            throw new FunnelError('A funnel has at most eight steps', 'funnel_long');
        }
        $createdAt = $now;
        foreach ($existing as $f) {
            if ($f['id'] === $id) {
                $createdAt = $f['createdAt'];
                break;
            }
        }
        return ['id' => $id ?? Hash::randomId(), 'site' => $site, 'name' => $name, 'steps' => $steps, 'createdAt' => $createdAt];
    }
}
