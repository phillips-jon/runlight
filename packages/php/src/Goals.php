<?php

declare(strict_types=1);

namespace Runlight;

/** Goals: checking one from the dashboard, and the click rules the tracker carries. */
final class Goals
{
    private const KINDS = ['event', 'page', 'click'];
    private const MODES = ['none', 'fixed', 'prop'];
    private const PROP = '/^[A-Za-z0-9_.-]{1,40}$/D';

    /**
     * A page to match, written the way paths are recorded: the path of a pasted URL, with a leading slash,
     * percent-encoded as browsers send it, so /café matches the recorded /caf%C3%A9, and with a hash
     * route kept, so /#/thanks counts only that route. `*` stays a wildcard. Null when it is not a path or a URL.
     */
    public static function pagePattern(string $input): ?string
    {
        $starred = str_replace('*', '__STAR__', $input);
        // A pattern written to start with * keeps that start, rather than gaining a slash.
        $path = Sources::recordedPath(str_starts_with($starred, '__STAR__') ? "/$starred" : $starred);
        if ($path === null) {
            return null;
        }
        $pattern = str_replace('__STAR__', '*', $path);
        return str_starts_with($input, '*') ? (string) preg_replace('/^\//', '', $pattern) : $pattern;
    }

    /** String(input[key] ?? ""), from a decoded JSON object as an array or a stdClass. */
    public static function field(array|\stdClass $input, string $key): string
    {
        $value = Js::get($input, $key);
        return $value === null || $value instanceof Undefined ? '' : Js::string($value);
    }

    /**
     * Checks and tidies a goal from the dashboard. `existing` is the site's
     * other goals, so two goals cannot share a name.
     *
     * @param list<array> $existing GoalRows
     * @return array GoalRow
     * @throws GoalError
     */
    public static function goalFrom(array|\stdClass $input, string $site, array $existing, int $now, ?string $id = null): array
    {
        $text = static fn (string $key, int $max): string => Js::cut(Js::trim(self::field($input, $key)), $max);
        $name = $text('name', 80);
        if ($name === '') {
            throw new GoalError('Give the goal a name', 'goal_name');
        }
        foreach ($existing as $g) {
            if ($g['id'] !== $id && Js::lower($g['name']) === Js::lower($name)) {
                throw new GoalError("There is already a goal called \"$name\"", 'goal_exists', ['name' => $name]);
            }
        }

        $kind = self::field($input, 'kind');
        if (!in_array($kind, self::KINDS, true)) {
            throw new GoalError('Pick what the goal counts: an event, a page visit, or a click', 'goal_kind');
        }

        $match = $text('match', 500);
        $clickBy = '';
        if ($kind === 'event' && $match === '') {
            throw new GoalError("Enter the event's name", 'goal_event');
        }
        if ($kind === 'page') {
            if ($match === '') {
                throw new GoalError('Enter a page path, like /thanks or /blog/*', 'goal_page');
            }
            // A full URL is fine to paste; the path is what counts.
            $path = self::pagePattern($match);
            if ($path === null) {
                throw new GoalError('That page is not a path or a URL', 'goal_page_bad');
            }
            $match = $path;
        }
        if ($kind === 'click') {
            $clickBy = Js::get($input, 'clickBy') === 'link' ? 'link' : 'selector';
            if ($match === '') {
                throw $clickBy === 'link'
                    ? new GoalError("Enter the link's address, like https://buy.stripe.com/*", 'goal_link')
                    : new GoalError('Enter a CSS selector, like #signup or .buy-button', 'goal_selector');
            }
        }

        // A click goal sends an event named after itself, so its name and an event goal's match must not meet.
        $others = array_values(array_filter($existing, static fn (array $g): bool => $g['id'] !== $id));
        if ($kind === 'click') {
            foreach ($others as $g) {
                if ($g['kind'] === 'event' && Js::lower($g['match']) === Js::lower($name)) {
                    throw new GoalError("An event goal already counts events called \"$name\", so give this click goal another name", 'goal_event_taken', ['name' => $name]);
                }
            }
        }
        if ($kind === 'event') {
            foreach ($others as $g) {
                if ($g['kind'] === 'click' && Js::lower($g['name']) === Js::lower($match)) {
                    throw new GoalError("The click goal \"$match\" already sends events with that name", 'goal_click_taken', ['match' => $match]);
                }
            }
        }

        $mode = Js::string(Js::get($input, 'valueMode'));
        $valueMode = in_array($mode, self::MODES, true) ? $mode : 'none';
        // Page visits and click rules carry no properties, so only an event can send its own amount.
        if ($valueMode === 'prop' && $kind !== 'event') {
            throw new GoalError('Only an event goal can take its amount from the event; use a fixed amount instead', 'goal_prop_kind');
        }
        $value = $valueMode === 'fixed' ? Js::number(Js::get($input, 'value')) : 0;
        if ($valueMode === 'fixed' && !(is_finite((float) $value) && $value >= 0 && $value < 1e9)) {
            throw new GoalError('Enter an amount, like 49 or 9.99', 'goal_amount');
        }
        $valueProp = '';
        if ($valueMode === 'prop') {
            $valueProp = $text('valueProp', 40);
            if ($valueProp === '') {
                $valueProp = 'revenue';
            }
        }
        if ($valueMode === 'prop' && !preg_match(self::PROP, $valueProp)) {
            throw new GoalError('A property name uses letters, numbers, dots, dashes, and underscores', 'goal_prop_name');
        }
        $currency = Js::upper($text('currency', 20));
        if ($currency === '') {
            $currency = 'USD';
        }
        if (!preg_match('/^[A-Z]{3}$/D', $currency)) {
            throw new GoalError('Use a three-letter currency code, like USD or EUR', 'goal_currency');
        }

        $before = null;
        foreach ($existing as $g) {
            if ($g['id'] === $id) {
                $before = $g;
                break;
            }
        }
        $rounded = Js::round((float) $value * 100) / 100;
        return [
            'id' => $id ?? Hash::randomId(),
            'site' => $site,
            'name' => $name,
            'kind' => $kind,
            'match' => $match,
            'clickBy' => $clickBy,
            'valueMode' => $valueMode,
            // One number type in JavaScript: a whole amount is an int here.
            'value' => $rounded == floor($rounded) && abs($rounded) < 2 ** 53 ? (int) $rounded : $rounded,
            'valueProp' => $valueProp,
            'currency' => $currency,
            'createdAt' => $before['createdAt'] ?? $now,
        ];
    }

    /**
     * Click rules for the tracker, keyed by site id and by each of the site's
     * hostnames (or "*" for a site with none), so the script finds its own. One rule is
     * [s for selector or h for a link, what to match, the event to send].
     *
     * @param list<array{id: string, hostnames: list<string>}> $sites
     * @param list<array> $goals
     * @return array<string, list<array{0: string, 1: string, 2: string}>>
     */
    public static function clickRules(array $sites, array $goals): array
    {
        $out = [];
        foreach ($sites as $site) {
            $rules = [];
            foreach ($goals as $g) {
                if ($g['site'] === $site['id'] && $g['kind'] === 'click') {
                    $rules[] = [$g['clickBy'] === 'link' ? 'h' : 's', $g['match'], $g['name']];
                }
            }
            if (!$rules) {
                continue;
            }
            $out[$site['id']] = $rules;
            foreach ($site['hostnames'] ?: ['*'] as $host) {
                $out[(string) preg_replace('/^www\./', '', $host)] = $rules;
            }
        }
        return $out;
    }
}
