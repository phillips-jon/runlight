<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Request;
use Runlight\Http\Response;

/**
 * The MCP server at {base}/mcp: Streamable HTTP without sessions or a stream,
 * JSON-RPC in and JSON out. Every tool is a read of the HTTP API, made with
 * the caller's own credentials, so the MCP server can see exactly what the
 * token can and nothing more.
 *
 * Reading the API is the caller's: `$readApi` is a callable(string $path, list<array{0: string, 1: string}> $params): Response
 * that reads one API path with the caller's credentials, as ApiRead does in TypeScript.
 */
final class Mcp
{
    /** Newest first; a client asking for one we do not know is answered with the newest. */
    public const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

    public const INSTRUCTIONS = <<<'TEXT'
Runlight is privacy friendly web analytics. These tools read one install's numbers: visitors, visits, pageviews, bounce rate, visit duration, where visitors came from, what they read, goals and revenue, AI assistants that sent visitors or fetched pages, and short links.

Start with list_sites when you do not know the site id; every other tool defaults to the first site. Dates are in the site's own timezone, which each answer includes. Periods: today, yesterday, 7d, 30d, 90d, month (this month so far), last_month, year (this year so far), 12mo, all; or from and to as YYYY-MM-DD. Answers compare with the period before unless compare is off.

Filters narrow any report to matching visits, written dimension:op:value with op one of is, not, contains, for example "channel:is:Organic Search" or "page:contains:/blog". Visitors are counted per day without cookies, so a visitor seen on two days counts twice across a long range.
TEXT;

    /** The dimensions a breakdown reads, as query.ts's DIMENSIONS lists them. */
    private const DIMENSIONS = [
        'page', 'hostname', 'event', 'entry', 'exit', 'referrer', 'source', 'channel', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term',
        'utm_content', 'country', 'region', 'city', 'browser', 'browser_version', 'os', 'os_version', 'device', 'screen', 'language', 'ai_agent', 'ai_page',
    ];
    /** query.ts's MAX_FILTERS. */
    private const MAX_FILTERS = 6;

    private const RANGE_KEYS = ['site', 'period', 'from', 'to', 'filters'];
    private const COMPARE_KEYS = [...self::RANGE_KEYS, 'compare', 'compare_from', 'compare_to'];

    /** @var list<array<string, mixed>>|null */
    private static ?array $tools = null;
    private static ?string $version = null;

    /** @return array<string, array<string, mixed>> */
    private static function range(): array
    {
        return [
            'site' => ['type' => 'string', 'description' => 'Site id from list_sites. Defaults to the first site.'],
            'period' => [
                'type' => 'string',
                'enum' => ['today', 'yesterday', '7d', '30d', '90d', 'month', 'last_month', 'year', '12mo', 'all'],
                'description' => 'The date range. Defaults to 30d. Ignored when from and to are given.',
            ],
            'from' => ['type' => 'string', 'description' => 'First day, YYYY-MM-DD, with to.'],
            'to' => ['type' => 'string', 'description' => 'Last day, YYYY-MM-DD, inclusive.'],
            'filters' => [
                'type' => 'array',
                'items' => ['type' => 'string'],
                'maxItems' => self::MAX_FILTERS,
                'description' => 'Narrow to matching visits, up to ' . self::MAX_FILTERS . ' at once, each "dimension:op:value" with op is, not, or contains.',
            ],
        ];
    }

    /** @return array<string, array<string, mixed>> */
    private static function compare(): array
    {
        return [
            'compare' => ['type' => 'string', 'enum' => ['previous', 'year', 'custom', 'off'], 'description' => 'What to compare with. Defaults to previous, the same length of time just before.'],
            'compare_from' => ['type' => 'string', 'description' => 'For compare custom: first day, YYYY-MM-DD.'],
            'compare_to' => ['type' => 'string', 'description' => 'For compare custom: last day, YYYY-MM-DD.'],
        ];
    }

    /**
     * @param array<mixed>|\stdClass $args
     * @param list<string> $keys
     * @return list<array{0: string, 1: string}>
     */
    private static function rangeParams(array|\stdClass $args, array $keys): array
    {
        $params = [];
        foreach ($keys as $key) {
            $value = Js::get($args, $key);
            if ($key === 'filters') {
                if (is_array($value) && array_is_list($value)) {
                    foreach ($value as $f) {
                        $params[] = ['filter', Js::string($f)];
                    }
                }
            } elseif (!$value instanceof Undefined && $value !== null && $value !== '') {
                $params[] = [$key, Js::string($value)];
            }
        }
        return $params;
    }

    /**
     * @param list<string> $keys
     * @param (\Closure(array<mixed>|\stdClass): list<array{0: string, 1: string}>)|null $extra
     */
    private static function read(string $path, array $keys, ?\Closure $extra = null): \Closure
    {
        return static fn (array|\stdClass $args): array => [
            'path' => $path,
            'params' => [...self::rangeParams($args, $keys), ...($extra ? $extra($args) : [])],
        ];
    }

    /** Math.min(top, Math.max(1, Number(value) || fallback)) as text. */
    private static function limit(mixed $value, int $fallback): string
    {
        $n = $value instanceof Undefined ? NAN : Js::number($value);
        if (!Js::truthy($n)) {
            $n = $fallback;
        }
        return Js::string(min(100, max(1, $n)));
    }

    /**
     * The tools, each with name, title, description, inputSchema, request (args to an API path and query), and
     * shape (trims an answer before it goes back, when the API's carries more than an assistant needs) or null.
     *
     * @return list<array{name: string, title: string, description: string, inputSchema: array<string, mixed>, request: \Closure, shape: ?\Closure}>
     */
    public static function tools(): array
    {
        if (self::$tools !== null) {
            return self::$tools;
        }
        $range = self::range();
        $compare = self::compare();
        return self::$tools = [
            [
                'name' => 'list_sites',
                'title' => 'List sites',
                'description' => 'Every site this token can read, with its id, name, hostnames, timezone, and when it last had a visit.',
                'inputSchema' => ['type' => 'object', 'properties' => Json::object()],
                'request' => static fn (): array => ['path' => '/api/sites', 'params' => []],
                'shape' => null,
            ],
            [
                'name' => 'get_stats',
                'title' => 'Headline numbers',
                'description' => 'Visitors, visits, pageviews, views per visit, bounce rate (0 to 1), and visit duration (milliseconds) for a range, with the comparison range\'s numbers as previous.',
                'inputSchema' => ['type' => 'object', 'properties' => [...$range, ...$compare]],
                'request' => self::read('/api/stats', self::COMPARE_KEYS),
                'shape' => null,
            ],
            [
                'name' => 'get_timeseries',
                'title' => 'Numbers over time',
                'description' => 'The headline numbers for each hour, day, week, or month of a range, with the comparison range\'s points lined up by position.',
                'inputSchema' => [
                    'type' => 'object',
                    'properties' => [...$range, ...$compare, 'interval' => ['type' => 'string', 'enum' => ['hour', 'day', 'week', 'month'], 'description' => 'Chosen from the range when left out.']],
                ],
                'request' => self::read('/api/series', [...self::COMPARE_KEYS, 'interval']),
                'shape' => null,
            ],
            [
                'name' => 'get_breakdown',
                'title' => 'Top values of a dimension',
                'description' => 'Rows for one dimension, most visitors first: pages, entry and exit pages, referrers, sources, channels (Direct, Organic Search, Social, AI, and so on), UTM tags, countries, regions, cities, browsers, operating systems, devices, screens, languages, custom events, and AI agents that fetched pages (ai_agent, ai_page).',
                'inputSchema' => [
                    'type' => 'object',
                    'properties' => [
                        ...$range,
                        'dimension' => ['type' => 'string', 'enum' => self::DIMENSIONS],
                        'limit' => ['type' => 'integer', 'minimum' => 1, 'maximum' => 100, 'description' => 'Rows to return. Defaults to 10.'],
                        'page' => ['type' => 'integer', 'minimum' => 1, 'description' => 'For more rows: 2 is the next limit rows.'],
                    ],
                    'required' => ['dimension'],
                ],
                'request' => self::read('/api/breakdown', [...self::RANGE_KEYS, 'dimension', 'page'], static fn ($args): array => [['limit', self::limit(Js::get($args, 'limit'), 10)]]),
                'shape' => null,
            ],
            [
                'name' => 'list_funnels',
                'title' => 'Funnels',
                'description' => 'Every funnel with how many visits reached each step in order within the same visit. Divide a step by the one before it for that step\'s conversion rate.',
                'inputSchema' => ['type' => 'object', 'properties' => [...$range]],
                'request' => self::read('/api/funnels', self::RANGE_KEYS),
                'shape' => null,
            ],
            [
                'name' => 'get_event_properties',
                'title' => 'An event\'s properties',
                'description' => 'The properties sent with one custom event and the values each took, most common first. Automatic events have their own: "Outbound link" and "File download" carry url, and "404" carries path. Leave key out to see every property name and the values of the most used one.',
                'inputSchema' => [
                    'type' => 'object',
                    'properties' => [
                        ...$range,
                        'event' => ['type' => 'string', 'description' => 'The event\'s name, as get_breakdown with dimension event lists it.'],
                        'key' => ['type' => 'string', 'description' => 'Which property. Defaults to the most used one.'],
                        'limit' => ['type' => 'integer', 'minimum' => 1, 'maximum' => 100, 'description' => 'Values to return. Defaults to 25.'],
                    ],
                    'required' => ['event'],
                ],
                'request' => self::read('/api/event-props', [...self::RANGE_KEYS, 'event', 'key'], static fn ($args): array => [['limit', self::limit(Js::get($args, 'limit'), 25)]]),
                'shape' => null,
            ],
            [
                'name' => 'get_visit_times',
                'title' => 'When people visit',
                'description' => 'Visits by weekday and hour in the site\'s timezone: grid[weekday][hour], Monday first, hours 0 to 23.',
                'inputSchema' => ['type' => 'object', 'properties' => [...$range]],
                'request' => self::read('/api/rhythm', self::RANGE_KEYS),
                'shape' => static fn ($body): array => [
                    'site' => Js::get($body, 'site'),
                    'range' => Js::get($body, 'range'),
                    'weekdays' => ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
                    'grid' => Js::get($body, 'grid'),
                ],
            ],
            [
                'name' => 'get_realtime',
                'title' => 'Right now',
                'description' => 'People on the site in the last five minutes, the pages they are reading, where they came from, their countries, and the latest activity.',
                'inputSchema' => ['type' => 'object', 'properties' => ['site' => $range['site']]],
                'request' => self::read('/api/realtime', ['site']),
                'shape' => null,
            ],
            [
                'name' => 'list_goals',
                'title' => 'Goals and conversions',
                'description' => 'Every goal with its conversions, converted visitors, conversion rate (0 to 1), and revenue for a range, with the comparison range\'s numbers as previous.',
                'inputSchema' => ['type' => 'object', 'properties' => [...$range, ...$compare]],
                'request' => self::read('/api/goals', self::COMPARE_KEYS),
                'shape' => null,
            ],
            [
                'name' => 'get_goal',
                'title' => 'One goal in detail',
                'description' => 'One goal\'s conversions over time and by channel, source, and page. Find the goal_id with list_goals.',
                'inputSchema' => ['type' => 'object', 'properties' => [...$range, 'goal_id' => ['type' => 'string']], 'required' => ['goal_id']],
                'request' => static function ($args): array {
                    $id = Js::get($args, 'goal_id');
                    return [
                        'path' => '/api/goals/' . Js::encodeURIComponent(Js::string($id === null || $id instanceof Undefined ? '' : $id)),
                        'params' => self::rangeParams($args, self::RANGE_KEYS),
                    ];
                },
                'shape' => null,
            ],
            [
                'name' => 'get_journeys',
                'title' => 'Paths through the site',
                'description' => 'The paths visits take, page by page: the top pages at each step, how many went no further, the flows between steps, and the commonest whole paths. A refresh counts once. start and end follow only paths from or to a page.',
                'inputSchema' => [
                    'type' => 'object',
                    'properties' => [
                        ...$range,
                        'steps' => ['type' => 'integer', 'minimum' => 2, 'maximum' => 8, 'description' => 'How many pages of each path. Defaults to 5.'],
                        'start' => ['type' => 'string', 'description' => 'Only paths from this page, such as /pricing.'],
                        'end' => ['type' => 'string', 'description' => 'Only paths that reach this page, cut there.'],
                    ],
                ],
                'request' => self::read('/api/journeys', [...self::RANGE_KEYS, 'steps', 'start', 'end']),
                'shape' => null,
            ],
            [
                'name' => 'list_links',
                'title' => 'Short links',
                'description' => 'Every short link with its destination and its clicks in the range.',
                'inputSchema' => ['type' => 'object', 'properties' => ['site' => $range['site'], 'period' => $range['period'], 'from' => $range['from'], 'to' => $range['to']]],
                'request' => self::read('/api/links', ['site', 'period', 'from', 'to']),
                'shape' => null,
            ],
        ];
    }

    /** @return array{jsonrpc: string, id: mixed, error: array{code: int, message: string}} */
    private static function rpcError(mixed $id, int $code, string $message): array
    {
        return ['jsonrpc' => '2.0', 'id' => $id instanceof Undefined ? null : $id, 'error' => ['code' => $code, 'message' => $message]];
    }

    /**
     * Runs one tool by name, as the MCP server does; the dashboard's assistant calls it too.
     *
     * @param array<mixed>|\stdClass $params name and arguments
     * @param callable(string, list<array{0: string, 1: string}>): Response $readApi
     * @return array{content: list<array{type: string, text: string}>, isError?: true}
     * @throws McpError for an unknown tool
     */
    public static function callTool(array|\stdClass $params, callable $readApi): array
    {
        $name = Js::get($params, 'name');
        $tool = null;
        foreach (self::tools() as $one) {
            if ($one['name'] === $name) {
                $tool = $one;
                break;
            }
        }
        if ($tool === null) {
            throw new McpError('Unknown tool "' . Js::string($name) . '"', -32602);
        }
        $given = Js::get($params, 'arguments');
        $args = Js::truthy($given) && Js::isObject($given) ? $given : [];
        ['path' => $path, 'params' => $query] = ($tool['request'])($args);
        $answer = $readApi($path, $query);
        [$parsed, $body] = Js::parseJson($answer->text());
        if (!$parsed) {
            $body = Json::object();
        }
        if (!$answer->ok()) {
            $error = Js::get($body, 'error');
            return ['content' => [['type' => 'text', 'text' => Js::string($error === null || $error instanceof Undefined ? "Runlight answered {$answer->status}" : $error)]], 'isError' => true];
        }
        return ['content' => [['type' => 'text', 'text' => Json::encode($tool['shape'] ? ($tool['shape'])($body) : $body)]]];
    }

    private static function version(): string
    {
        if (self::$version === null) {
            $build = json_decode((string) file_get_contents(__DIR__ . '/../assets/build.json'), true);
            self::$version = (string) ($build['version'] ?? '0.0.0');
        }
        return self::$version;
    }

    /** @return array<string, mixed>|null the answer, or null for a notification */
    private static function answer(mixed $message, callable $readApi): ?array
    {
        $id = Js::get($message, 'id');
        $isNotification = $id instanceof Undefined;
        $method = Js::get($message, 'method');
        if (Js::get($message, 'jsonrpc') !== '2.0' || !is_string($method)) {
            return $isNotification ? null : self::rpcError($id, -32600, 'Invalid request');
        }
        $given = Js::get($message, 'params');
        $params = Js::truthy($given) && Js::isObject($given) ? $given : [];
        try {
            switch ($method) {
                case 'initialize':
                    $asked = Js::get($params, 'protocolVersion');
                    $asked = Js::string($asked === null || $asked instanceof Undefined ? '' : $asked);
                    $result = [
                        'protocolVersion' => in_array($asked, self::PROTOCOL_VERSIONS, true) ? $asked : self::PROTOCOL_VERSIONS[0],
                        'capabilities' => ['tools' => ['listChanged' => false]],
                        'serverInfo' => ['name' => 'runlight', 'title' => 'Runlight', 'version' => self::version()],
                        'instructions' => self::INSTRUCTIONS,
                    ];
                    break;
                case 'ping':
                    $result = Json::object();
                    break;
                case 'tools/list':
                    $result = [
                        'tools' => array_map(static fn (array $t): array => [
                            'name' => $t['name'],
                            'title' => $t['title'],
                            'description' => $t['description'],
                            'inputSchema' => $t['inputSchema'],
                            'annotations' => ['readOnlyHint' => true, 'openWorldHint' => false],
                        ], self::tools()),
                    ];
                    break;
                case 'tools/call':
                    $result = self::callTool($params, $readApi);
                    break;
                default:
                    if ($isNotification) {
                        return null;
                    }
                    return self::rpcError($id, -32601, "Unknown method \"$method\"");
            }
            return $isNotification ? null : ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
        } catch (\Throwable $error) {
            if ($isNotification) {
                return null;
            }
            return $error instanceof McpError ? self::rpcError($id, $error->getCode(), $error->getMessage()) : self::rpcError($id, -32603, 'Internal error');
        }
    }

    /**
     * Answers one POST to the MCP endpoint, already authorised.
     *
     * @param callable(string, list<array{0: string, 1: string}>): Response $readApi
     */
    public static function mcpResponse(Request $request, callable $readApi): Response
    {
        $headers = ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'];
        [$parsed, $body] = Js::parseJson($request->text());
        if (!$parsed || !Js::isObject($body)) {
            return new Response(Json::encode(self::rpcError(null, -32700, 'Send a JSON-RPC message')), 400, $headers);
        }
        // Batches were in the 2025-03-26 protocol; answering them costs nothing.
        if (is_array($body)) {
            $answers = [];
            foreach ($body as $message) {
                $one = self::answer($message, $readApi);
                if ($one !== null) {
                    $answers[] = $one;
                }
            }
            return $answers ? new Response(Json::encode($answers), 200, $headers) : new Response('', 202);
        }
        $one = self::answer($body, $readApi);
        return $one !== null ? new Response(Json::encode($one), 200, $headers) : new Response('', 202);
    }
}
