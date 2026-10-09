<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Report queries: which dimensions exist, where each lives, and how filters
 * are read from a URL. Shared by every store.
 *
 * A filter is an array{dimension: string, op: 'is'|'not'|'contains', value: string}. A query is an
 * array{site: string, from: int, to: int, filters: list<array>}, `from` inclusive and `to` exclusive, both
 * epoch milliseconds.
 */
final class Query
{
    /** Dimensions recorded per event. */
    public const EVENT_DIMENSIONS = [
        'page' => 'path',
        'hostname' => 'hostname',
        'event' => 'name',
    ];

    /** Dimensions recorded once per session, from its first request. */
    public const SESSION_DIMENSIONS = [
        'entry' => 'entry_path',
        'exit' => 'exit_path',
        'referrer' => 'referrer_host',
        'source' => 'source',
        'channel' => 'channel',
        'utm_source' => 'utm_source',
        'utm_medium' => 'utm_medium',
        'utm_campaign' => 'utm_campaign',
        'utm_term' => 'utm_term',
        'utm_content' => 'utm_content',
        'country' => 'country',
        'region' => 'region',
        'city' => 'city',
        'browser' => 'browser',
        'browser_version' => 'browser_version',
        'os' => 'os',
        'os_version' => 'os_version',
        'device' => 'device',
        'screen' => 'screen',
        'language' => 'language',
    ];

    /** AI agent fetches are their own rows, outside visits. */
    public const FETCH_DIMENSIONS = ['ai_agent', 'ai_page'];

    /** Every dimension: the event ones, the session ones, then the fetch ones. */
    public const DIMENSIONS = [
        'page', 'hostname', 'event',
        'entry', 'exit', 'referrer', 'source', 'channel', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
        'country', 'region', 'city', 'browser', 'browser_version', 'os', 'os_version', 'device', 'screen', 'language',
        'ai_agent', 'ai_page',
    ];

    /** The most filters a query takes, which keeps every statement within Cloudflare D1's 100 values. */
    public const MAX_FILTERS = 6;

    public static function isDimension(string $value): bool
    {
        return in_array($value, self::DIMENSIONS, true);
    }

    public static function isSessionDimension(string $value): bool
    {
        return array_key_exists($value, self::SESSION_DIMENSIONS);
    }

    public static function isEventDimension(string $value): bool
    {
        return array_key_exists($value, self::EVENT_DIMENSIONS);
    }

    /**
     * `dimension:op:value`, where the value may itself contain colons.
     *
     * @return array{dimension: string, op: string, value: string}|null
     */
    public static function parseFilter(string $text): ?array
    {
        $first = strpos($text, ':');
        $second = $first === false ? false : strpos($text, ':', $first + 1);
        if ($second === false) {
            return null;
        }
        $dimension = substr($text, 0, $first);
        $op = substr($text, $first + 1, $second - $first - 1);
        $value = substr($text, $second + 1);
        if (!self::isSessionDimension($dimension) && !self::isEventDimension($dimension)) {
            return null;
        }
        if ($op !== 'is' && $op !== 'not' && $op !== 'contains') {
            return null;
        }
        return ['dimension' => $dimension, 'op' => $op, 'value' => Js::slice($value, 0, 500)];
    }
}
