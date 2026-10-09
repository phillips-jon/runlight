<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Accounts\Web;
use Runlight\Http\FetchError;
use Runlight\Http\Headers;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Importers\Http as ImportHttp;
use Runlight\Importers\ImportError;
use Runlight\Importers\Index as Importers;
use Runlight\Importers\Visits;
use Runlight\Mail\MailError;
use Runlight\Mail\Transports;
use Runlight\Store\SqlStore;

/**
 * The dashboard, its API, the tracker, the MCP server, and OAuth, under one base path, as routes.ts serves them.
 *
 * Options (the TypeScript names, read with array_key_exists where absence means something):
 * - basePath: where the routes are mounted. Default "/runlight".
 * - token: required to read stats. Send it as `Authorization: Bearer <token>`, or open the dashboard once with
 *   `?token=<token>` and a cookie is set. Absent means RUNLIGHT_TOKEN. Without one, the dashboard and API are
 *   open only when NODE_ENV is "development", and answer 503 everywhere else. Pass null to leave them open
 *   everywhere, for example behind your own auth middleware.
 * - authorize: callable(Request): bool|'member'|'read', your own check instead of a token. True is full access,
 *   "member" changes everything but the install-wide controls (the mail service, the assistant's settings, and
 *   deleting a site), "read" reads every site's stats and changes nothing (as an API token can).
 * - cronSecret: also accepted as a bearer token on POST /api/check. Defaults to CRON_SECRET.
 * - observeKey: lets another site report AI agent fetches to POST /api/observe. Defaults to RUNLIGHT_OBSERVE_KEY.
 * - signOut, signIn: links the dashboard shows. The standalone server sets them.
 * - accounts: true for sign-in accounts, or a Runlight\Accounts\Web of your own.
 * - geoCredit: credits DB-IP in the dashboard's footer.
 * - origin: the address people open the app at, such as https://example.com.
 * - ownHosts: callable(): iterable<string>, more names the dashboard is reached at.
 * - accountOf: callable(Request): ?string, the account a request comes from (internal, for the standalone server).
 * - tokenMade: callable(array $token, string $by): bool, notes who made a token (internal).
 */
final class Routes
{
    public const COOKIE = 'runlight_token';
    public const IMPLEMENTATION = ['library' => 'runlight/runlight', 'language' => 'php'];

    /** API tokens start with this, so they are told apart from the main token. */
    public const TOKEN_PREFIX = 'rl_';
    /** The header a shared dashboard sends its share id in. */
    public const SHARE_HEADER = 'x-runlight-share';
    /** What a share can read: one site's reports, nothing that changes anything. */
    public const SHARED_PATHS = ['/api/sites', '/api/icon', '/api/realtime', '/api/stats', '/api/series', '/api/rhythm', '/api/breakdown', '/api/goals', '/api/event-props', '/api/export', '/api/funnels', '/api/journeys'];
    /** Where the tracker's click rules go; the script ships with this string in their place. */
    private const RULES_PLACEHOLDER = '"__RUNLIGHT_RULES__"';
    /** Where the picker's one allowed receiver goes, the dashboard origin its ticket names. */
    private const PICK_TARGET_PLACEHOLDER = '"__RUNLIGHT_PICK_TARGET__"';
    /** Where the hostnames of the site its ticket names go, as JSON inside a string. */
    private const PICK_HOSTS_PLACEHOLDER = '"__RUNLIGHT_PICK_HOSTS__"';
    /** How long a picker ticket works: long enough to find the element, not to be kept. */
    public const PICK_TICKET_MS = 30 * 60_000;
    /** Questions one person may put to the assistant in an hour, and at once. */
    public const ASK_PER_HOUR = 30;
    public const ASK_AT_ONCE = 2;
    /** Questions each viewer may ask a day, until an owner sets another number. */
    public const VIEWER_DAILY = 50;
    private const SHARE_ID = '/^[a-f0-9]{32}\z/';
    private const PATH_DIMENSIONS = ['page', 'entry', 'exit', 'ai_page'];
    /** runlight.ts's LINK_DOMAIN_CHECK: the path on every link domain that answers when the domain reaches this Runlight. */
    private const LINK_DOMAIN_CHECK = '/.well-known/runlight-link-domain';
    /** runlight.ts's RETENTION_MONTHS: the choices for how long a site keeps its visits. */
    private const RETENTION_MONTHS = [6, 12, 24, 36, 60];

    public const DASHBOARD_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

    /** A domain name, such as go.example.com. */
    public const DOMAIN_NAME = '/^(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/';

    /** @var array<string, string> the files in assets/, read once per process */
    private static array $assets = [];

    /** @var \Runlight\Runlight */
    private readonly object $rl;
    private readonly string $base;
    private readonly ?string $token;
    private readonly ?string $cronSecret;
    private readonly ?string $observeKey;
    private readonly ?string $origin;
    /** @var array<string, mixed> */
    private readonly array $options;
    private bool $warned = false;
    private readonly ?Web $web;
    private readonly ?string $signIn;
    private readonly ?string $signOut;
    /** @var (\Closure(Request): ?string)|null */
    private readonly ?\Closure $accountOf;
    /** @var (\Closure(array<string, mixed>, string): bool)|null */
    private readonly ?\Closure $tokenMade;
    /** @var array<string, mixed> */
    private readonly array $oauth;

    /** Requests from a manage token, already checked against its one site, act as the owner's. */
    private \WeakMap $managed;
    /** Requests from a member: full access apart from the install-wide controls. */
    private \WeakMap $members;
    /** Questions to the assistant being answered now, per person, in this process. */
    private array $open = [];
    /** @var array<string, array{body: string, etag: string, at: int}> the tracker per site, rebuilt when goals change */
    private array $trackers = [];

    /**
     * @param \Runlight\Runlight $runlight
     * @param array<string, mixed> $options
     */
    public function __construct(object $runlight, array $options = [])
    {
        $this->rl = $runlight;
        $this->options = $options;
        $this->managed = new \WeakMap();
        $this->members = new \WeakMap();
        $this->base = self::normaliseBase(array_key_exists('basePath', $options) && $options['basePath'] !== null ? (string) $options['basePath'] : '/runlight');
        // Null leaves the routes open on purpose; an unset RUNLIGHT_TOKEN is no token (""), never open.
        $this->token = array_key_exists('token', $options) ? ($options['token'] === null ? null : (string) $options['token']) : (Env::get('RUNLIGHT_TOKEN') ?? '');
        $this->cronSecret = isset($options['cronSecret']) ? (string) $options['cronSecret'] : Env::get('CRON_SECRET');
        $this->observeKey = isset($options['observeKey']) ? (string) $options['observeKey'] : Env::get('RUNLIGHT_OBSERVE_KEY');
        $this->origin = Js::truthy($options['origin'] ?? null) ? (new Url((string) $options['origin']))->origin() : null;
        // A link domain leaves these paths to the app, so the dashboard stays reachable on every name.
        $mount = $this->base !== '' ? $this->base : '/';
        if (!in_array($mount, $runlight->routeBases, true)) {
            $runlight->routeBases[] = $mount;
        }

        // Accounts: the standalone server passes its own, and an app turns them on with true. Sessions need a secret
        // that outlives the process; in development without one, a made-up one does, so a restart signs everyone out.
        // An app left open on purpose (token: null) is treated like development here.
        $token = $this->token;
        $openSetup = $token === null || (($token === '') && self::isDevelopment());
        $accountSecret = $runlight->secret ?? ($openSetup ? Hash::randomId(32) : null);
        $accounts = $options['accounts'] ?? null;
        if ($accounts instanceof Web) {
            $this->web = $accounts;
        } elseif ($accounts === true && $accountSecret !== null && $accountSecret !== '') {
            $web = [
                'runlight' => $runlight,
                'secret' => $accountSecret,
                'base' => $this->base,
                'now' => fn (): int => $runlight->now(),
                // The app's token proves who may make the first account; in development without one, anyone may.
                'firstAccount' => $token !== null && $token !== '' ? ['token' => $token] : ($openSetup ? 'open' : 'locked'),
                'forgot' => 'https://runlight.sh/docs/configuration/#accounts',
            ];
            if (Js::truthy($options['origin'] ?? null)) {
                $home = (new Url((string) $options['origin']))->origin();
                $web['home'] = fn (): ?string => $home;
            }
            $this->web = new Web($web);
        } else {
            $this->web = null;
        }

        $web = $this->web;
        $this->signIn = isset($options['signIn']) ? (string) $options['signIn'] : ($web ? "{$this->base}/login" : null);
        $this->signOut = isset($options['signOut']) ? (string) $options['signOut'] : ($web ? "{$this->base}/logout" : null);
        $this->accountOf = isset($options['accountOf']) ? \Closure::fromCallable($options['accountOf']) : ($web ? fn (Request $r): ?string => $web->accountOf($r) : null);
        $this->tokenMade = isset($options['tokenMade']) ? \Closure::fromCallable($options['tokenMade']) : ($web ? fn (array $row, string $by): bool => $web->tokenMade($row, $by) : null);
        $authorize = $options['authorize'] ?? null;
        $oauth = [
            'runlight' => $runlight,
            'base' => $this->base,
            'isOwner' => fn (Request $r): bool => $this->canRead($r) === true,
            'isReader' => fn (Request $r): bool => $authorize !== null ? $authorize($r) === 'read' : ($web ? $web->access($r) === 'read' : false),
        ];
        if ($this->signIn !== null && $this->signIn !== '') {
            $oauth['signIn'] = $this->signIn;
        }
        if ($this->accountOf !== null) {
            $oauth['accountOf'] = $this->accountOf;
        }
        if ($this->tokenMade !== null) {
            $oauth['tokenMade'] = $this->tokenMade;
        }
        $this->oauth = $oauth;
    }

    // Helpers that need nothing of an instance.

    private static function escapeHtml(string $value): string
    {
        return strtr($value, ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;']);
    }

    /** The discovery documents OAuth clients read: two of OAuth's own, and OpenID's, which some clients try first. */
    private static function isOauthDocument(string $path): bool
    {
        return str_starts_with($path, '/.well-known/oauth-') || str_starts_with($path, '/.well-known/openid-configuration');
    }

    private static function isDevelopment(): bool
    {
        return Env::get('NODE_ENV') === 'development';
    }

    /**
     * An error the dashboard can show in its own language: `code` names it and
     * `params` fill its placeholders, while `error` stays the English message.
     *
     * @param array<string, string>|null $params
     * @param array<string, string> $headers
     */
    public static function coded(string $error, string $code, int $status, ?array $params = null, array $headers = []): Response
    {
        $body = ['error' => $error, 'code' => $code];
        if ($params !== null) {
            $body['params'] = (object) $params;
        }
        return self::json($body, $status, $headers);
    }

    /**
     * A refusal from a check elsewhere: its own code and params when the error
     * carries them, or else `fallback` with its English words as `detail`.
     */
    private static function refused(\Throwable $error, string $fallback, int $status = 400): Response
    {
        // Only public properties are seen from here, as only an error with its own code has one.
        $own = get_object_vars($error);
        if (is_string($own['code'] ?? null)) {
            return self::coded($error->getMessage(), $own['code'], $status, is_array($own['params'] ?? null) ? $own['params'] : null);
        }
        return self::coded($error->getMessage(), $fallback, $status, ['detail' => $error->getMessage()]);
    }

    /** @param array<string, string> $headers */
    public static function json(mixed $body, int $status = 200, array $headers = []): Response
    {
        return new Response(Json::encode($body), $status, array_merge(['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store', 'x-content-type-options' => 'nosniff'], $headers));
    }

    /**
     * Whether a request's body is JSON by its media type. A cross-site form or a
     * no-cors fetch can only send text/plain, urlencoded, or multipart, so a JSON
     * media type proves the request came from a page allowed to send it. A
     * substring test would accept "text/plain; application/json", which can.
     */
    public static function isJson(Request $request): bool
    {
        return Js::lower(Js::trim(explode(';', $request->headers->get('content-type') ?? '')[0])) === 'application/json';
    }

    /** A Host or X-Forwarded-Host value as a bare name: lowercase, with no port, no final dot, and no www. */
    public static function hostName(string $value): string
    {
        $first = Js::lower(Js::trim(explode(',', $value)[0]));
        if (str_starts_with($first, '[')) {
            $close = strpos($first, ']');
            $name = $close === false ? '' : substr($first, 0, $close + 1);
        } else {
            $name = (string) preg_replace('/:\d*\z/', '', $first);
        }
        return (string) preg_replace('/^www\./', '', (string) preg_replace('/\.+\z/', '', $name));
    }

    /**
     * Whether a domain name is one kept for private networks or tests, or has
     * an IPv4 address inside it (as nip.io answers). The link-domain check
     * fetches from it, so a name inside the install's own network must never
     * get that far; names that only resolve there are refused when fetched.
     */
    private static function privateName(string $domain): bool
    {
        if (preg_match('/(^|\.)\d{1,3}(\.\d{1,3}){3}(\.|\z)/', $domain)) {
            return true;
        }
        return (bool) preg_match('/\.(internal|intranet|private|local|localhost|localdomain|lan|home|corp|home\.arpa|arpa|test|invalid|example)\z/', $domain);
    }

    /** What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets. */
    private static function isEmail(string $value): bool
    {
        $no = '[^' . Js::SPACE . '@<>"]+';
        return (bool) preg_match("/^$no@$no\\.$no\\z/u", Js::scrub($value));
    }

    /**
     * Answers a read for a site counted by another install by asking that install,
     * with its token and its own id for the site, and handing back what it says.
     *
     * @param array<string, mixed> $remote
     */
    private function passThrough(array $remote, string $path, Url $url, ?Request $request = null): Response
    {
        $target = new Url($remote['url'] . $path);
        $query = $target->searchParams();
        foreach ($url->searchParams() as $key => $value) {
            $query->append((string) $key, $value);
        }
        $query->set('site', (string) $remote['site']);
        $target->setSearchParams($query);
        // A change made from the hub goes on to the install with its JSON body; reads carry none.
        $write = $request !== null && $request->method !== 'GET' && $request->method !== 'HEAD';
        $headers = ['authorization' => "Bearer {$remote['token']}"];
        if ($write && Js::truthy($request->headers->get('content-type'))) {
            $headers['content-type'] = (string) $request->headers->get('content-type');
        }
        $host = (new Url((string) $remote['url']))->host();
        try {
            $init = [
                'method' => $write ? $request->method : 'GET',
                'headers' => $headers,
                // An install that answers with a redirect gets no fetch of somewhere else on its behalf.
                'redirect' => 'manual',
                // A long report or an export is worked out in full before the install sends a byte, so reads get
                // two minutes.
                'timeoutMs' => $write ? 30_000 : 120_000,
            ];
            if ($write) {
                $init['body'] = $request->text();
            }
            $answer = $this->rl->fetcher->fetch($target->href(), $init);
        } catch (\Throwable $error) {
            if ($error instanceof FetchError && $error->timedOut) {
                return self::coded("$host took too long to answer. Try a shorter range.", 'remote_slow', 504, ['host' => $host]);
            }
            return self::coded("Could not reach $host", 'unreachable', 502, ['host' => $host]);
        }
        // What comes back is shown from this server's origin, so it is never taken as a page:
        // JSON, or a download for exports, with sniffing off and nothing allowed to run.
        $download = $path === '/api/export' || ($path === '/api/breakdown' && $url->searchParams()->get('format') === 'csv');
        $back = [
            'cache-control' => 'private, no-store',
            'x-content-type-options' => 'nosniff',
            'content-security-policy' => "default-src 'none'; frame-ancestors 'none'",
            'content-type' => $download ? (str_starts_with($answer->headers->get('content-type') ?? '', 'text/csv') ? 'text/csv; charset=utf-8' : 'application/zip') : 'application/json; charset=utf-8',
        ];
        if ($download) {
            $name = preg_match('/filename="([A-Za-z0-9._-]+)"/', $answer->headers->get('content-disposition') ?? '', $m) ? $m[1] : 'runlight-export';
            $back['content-disposition'] = "attachment; filename=\"$name\"";
        }
        if ($answer->status >= 300 && $answer->status < 400) {
            return self::coded("$host answered with a redirect", 'redirected', 502, ['host' => $host]);
        }
        // The install's own errors say what went wrong there; a refused token is this server's problem to report.
        if ($answer->status === 401) {
            return self::coded("$host refused the token. Connect it again from the site's settings.", 'token_refused', 502, ['host' => $host]);
        }
        // An install's own error is shown here, so it says where it came from, keeps only short text, and
        // carries its code and params for the dashboard to put in its own words.
        if ($answer->status >= 400 && !$download) {
            try {
                $text = Body::utf8($answer->text());
            } catch (\Throwable) {
                $text = '';
            }
            $body = null;
            if (Js::length($text) <= 65_536) {
                [$parsed, $value] = Js::parseJson($text);
                $body = $parsed && Js::isObject($value) ? $value : null;
            }
            $read = fn (string $key): mixed => $body === null ? null : Js::get($body, $key);
            $params = [];
            $given = $read('params');
            if (Js::truthy($given) && Js::isObject($given)) {
                foreach ((array) $given as $k => $v) {
                    if (is_string($v)) {
                        $params[] = [Js::slice((string) $k, 0, 40), Js::slice($v, 0, 200)];
                    }
                }
                $params = array_slice($params, 0, 10);
            }
            $error = $read('error');
            $out = ['error' => "$host: " . (is_string($error) ? Js::slice($error, 0, 300) : "answered {$answer->status}")];
            $code = $read('code');
            if (is_string($code) && preg_match('/^[a-z_]{1,40}\z/', $code)) {
                $out['code'] = $code;
                $fields = [];
                foreach ($params as [$k, $v]) {
                    $fields[$k] = $v;
                }
                $out['params'] = (object) $fields;
            }
            return self::json($out, $answer->status, $back);
        }
        return new Response($answer->text(), $answer->status, $back);
    }

    /** A plain page in a visitor's language, for unsubscribing and for a share link that is gone. */
    private static function smallPage(string $lang, string $body, int $status = 200): Response
    {
        return new Response(
            "<!doctype html><html lang=\"$lang\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>Runlight</title>\n"
            . '<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f5;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;color:#111827}main{max-width:420px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7eb;border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 20px;color:#4b5563}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:#111827;color:#fff;font:inherit;font-weight:600;cursor:pointer}</style></head><body><main>'
            . "$body</main></body></html>",
            $status,
            [
                'content-type' => 'text/html; charset=utf-8',
                'cache-control' => 'no-store',
                'content-security-policy' => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
                'referrer-policy' => 'no-referrer',
            ],
        );
    }

    /** The first language a browser asks for that the dashboard speaks, else English. */
    private static function acceptedLanguage(Request $request): string
    {
        foreach (explode(',', $request->headers->get('accept-language') ?? '') as $part) {
            $code = Js::lower(Js::slice(Js::trim(explode(';', $part)[0]), 0, 2));
            if (in_array($code, Messages::languages(), true)) {
                return $code;
            }
        }
        return 'en';
    }

    /**
     * Rows of objects as CSV, with a column for every key the first row has, in the units a spreadsheet reads.
     *
     * @param list<array<string, mixed>> $rows
     * @param array{timezone: string, interval?: string, dimension?: string} $sheet
     */
    private static function rowsCsv(array $rows, array $sheet): string
    {
        $readable = array_map(fn (array $r) => self::sheetRow($r, $sheet), $rows);
        $header = $readable ? array_map('strval', array_keys($readable[0])) : ['value'];
        return Zip::csv($header, array_map(fn (array $r) => array_map(fn (string $k) => array_key_exists($k, $r) ? $r[$k] : null, $header), $readable));
    }

    /**
     * One row for a spreadsheet: a bucket's start as the site's local date (and hour), rates as percents,
     * durations in seconds, and paths as people write them.
     *
     * @param array<string, mixed> $row
     * @param array{timezone: string, interval?: string, dimension?: string} $sheet
     * @return array<string, mixed>
     */
    private static function sheetRow(array $row, array $sheet): array
    {
        $out = [];
        foreach ($row as $key => $value) {
            $key = (string) $key;
            $number = is_int($value) || is_float($value);
            if ($key === 'start' && $number) {
                $hour = ($sheet['interval'] ?? null) === 'hour' ? ' ' . str_pad((string) Time::localWeekdayHour((int) $value, $sheet['timezone'])[1], 2, '0', STR_PAD_LEFT) . ':00' : '';
                $out['date'] = Time::localDate((int) $value, $sheet['timezone']) . $hour;
            } elseif ($key === 'bounceRate' && $number) {
                $out['bounceRatePercent'] = Js::round($value * 1000) / 10;
            } elseif (($key === 'visitDuration' || $key === 'timeOnPage') && $number) {
                $out["{$key}Seconds"] = Js::round($value / 1000);
            } elseif ($key === 'value' && is_string($value) && in_array($sheet['dimension'] ?? '', self::PATH_DIMENSIONS, true)) {
                $out['value'] = Sources::readablePath($value);
            } else {
                $out[$key] = $value;
            }
        }
        return $out;
    }

    /** A file to save, never shown in the browser or kept in a shared cache. */
    private static function download(string $name, string $body, string $type): Response
    {
        return new Response($body, 200, [
            'content-type' => $type,
            'content-disposition' => 'attachment; filename="' . preg_replace('/[^A-Za-z0-9._-]/u', '-', $name) . '"',
            'cache-control' => 'private, no-store',
        ]);
    }

    private static function constantTimeEqual(string $a, string $b): bool
    {
        return strlen($a) === strlen($b) && hash_equals($a, $b);
    }

    public static function cookieValue(string $token): string
    {
        return Hash::sha256("runlight-cookie:$token");
    }

    public static function readCookie(Request $request, string $name): string
    {
        foreach (explode(';', $request->headers->get('cookie') ?? '') as $part) {
            $pieces = explode('=', Js::trim($part));
            if (array_shift($pieces) === $name) {
                return implode('=', $pieces);
            }
        }
        return '';
    }

    public static function bearer(Request $request): string
    {
        $header = $request->headers->get('authorization') ?? '';
        return strtolower(substr($header, 0, 7)) === 'bearer ' ? Js::trim(substr($header, 7)) : '';
    }

    public static function normaliseBase(string $path): string
    {
        $trimmed = '/' . preg_replace('#^/+|/+\z#', '', $path);
        return $trimmed === '/' ? '' : $trimmed;
    }

    private static function escapeAttr(string $value): string
    {
        return strtr($value, ['&' => '&#38;', '"' => '&#34;', '<' => '&#60;', '>' => '&#62;']);
    }

    /** A file from assets/, which scripts/php-assets.mts copies from the TypeScript SDK's generated files. */
    private static function asset(string $name): string
    {
        if (!isset(self::$assets[$name])) {
            $text = @file_get_contents(__DIR__ . "/../assets/$name");
            if ($text === false) {
                throw new \RuntimeException("Runlight: assets/$name is missing; run npm run php-assets.");
            }
            self::$assets[$name] = $text;
        }
        return self::$assets[$name];
    }

    /** @return array<string, string> each language but English, as the dashboard fetches them */
    private static function locales(): array
    {
        static $locales = null;
        if ($locales === null) {
            $all = Json::decode(self::asset('locales.json'), true);
            unset($all['en']);
            $locales = $all;
        }
        return $locales;
    }

    private static function hash(string $name): string
    {
        return (string) Version::build()[$name];
    }

    private static function localeUrls(string $base): string
    {
        $urls = [];
        foreach (array_keys(self::locales()) as $code) {
            $urls[$code] = "$base/assets/locale.$code." . self::hash('localesHash') . '.json';
        }
        return Json::encode((object) $urls);
    }

    /** The dashboard's page, which holds no data: the API it calls checks access. */
    public static function dashboard(string $base, string $share = '', string $signOut = '', bool $geoCredit = false, bool $accounts = false, string $signIn = ''): string
    {
        $b = self::escapeAttr($base);
        $hash = self::hash('dashboardHash');
        $attributes = ($share !== '' ? ' data-share="' . self::escapeAttr($share) . '"' : '')
            . ($signOut !== '' ? ' data-sign-out="' . self::escapeAttr($signOut) . '"' : '')
            . ($signIn !== '' ? ' data-sign-in="' . self::escapeAttr($signIn) . '"' : '')
            . ($geoCredit ? ' data-geo-credit=""' : '')
            . ($accounts ? ' data-accounts=""' : '');
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"robots\" content=\"noindex\">\n<title>Runlight</title>\n"
            . '<link rel="icon" href="' . Brand::runlightIcon() . "\">\n"
            . "<link rel=\"stylesheet\" href=\"$b/assets/app.$hash.css\">\n</head>\n<body>\n"
            . "<div id=\"app\" data-base=\"$b\"$attributes data-world=\"$b/assets/world." . self::hash('worldHash') . '.json" data-locales="' . self::escapeAttr(self::localeUrls($base)) . "\"></div>\n"
            . "<script type=\"module\" src=\"$b/assets/app.$hash.js\"></script>\n</body>\n</html>\n";
    }

    private static function sharedPath(string $path): bool
    {
        return in_array($path, self::SHARED_PATHS, true) || (bool) preg_match('#^/api/goals/[a-f0-9]{24}\z#', $path);
    }

    /**
     * What a manage token, held by a Runlight hub, may read and change: one
     * site's goals, funnels, short links, link domains, email reports, and share
     * links, along with its name, timezone, and retention, and tickets for the
     * element picker. It may read which mail service sends reports, through GET
     * /api/mail, which hides the service's keys. Never people, tokens, changes to
     * the mail service, imports, or other sites.
     */
    public static function managePath(string $method, string $path): bool
    {
        if (preg_match('#^/api/links/import#', $path)) {
            return false;
        }
        if (preg_match('#^/api/(links|link-domains|reports|goals|funnels|shares)(/|\z)#', $path)) {
            return true;
        }
        if ($path === '/api/pick') {
            return $method === 'POST';
        }
        if ($path === '/api/mail') {
            return $method === 'GET';
        }
        if (preg_match('#^/api/sites/[^/]+\z#', $path)) {
            return $method === 'PATCH';
        }
        return false;
    }

    /** A dashboard's origin, which a picker ticket names. */
    private static function isOrigin(string $value): bool
    {
        return (bool) preg_match('#^https?://[^/?\#' . Js::SPACE . ']+\z#u', Js::scrub($value));
    }

    /** decodeURIComponent, which throws on a broken escape, as the TypeScript does (an internal error there). */
    private static function decode(string $text): string
    {
        $decoded = Js::decodeURIComponent($text);
        if ($decoded === null) {
            throw new \InvalidArgumentException('URI malformed');
        }
        return $decoded;
    }

    /** `String(body[key] ?? fallback)`. */
    private static function text(\stdClass $body, string $key, string $fallback = ''): string
    {
        $value = Js::get($body, $key);
        return $value === null || $value instanceof Undefined ? $fallback : Js::string($value);
    }

    private static function defined(\stdClass $body, string $key): bool
    {
        return !(Js::get($body, $key) instanceof Undefined);
    }

    /** A JSON value as plain PHP arrays, the shape the core's methods take; undefined becomes null. */
    private static function plain(mixed $value): mixed
    {
        if ($value instanceof Undefined) {
            return null;
        }
        return Json::decode(Json::encode($value), true);
    }

    /** `Object.fromEntries(Object.entries(value).map(([k, v]) => [k, String(v)]))` for an object, else nothing. */
    private static function credentials(mixed $value): array
    {
        $out = [];
        if (Js::truthy($value) && Js::isObject($value)) {
            foreach ((array) $value as $k => $v) {
                $out[(string) $k] = Js::string($v);
            }
        }
        return $out;
    }

    /** `Math.min(1000, Math.max(1, Number(value) || fallback))`. */
    private static function limit(?string $value, int $fallback): int|float
    {
        $n = Js::number($value);
        $n = is_float($n) && is_nan($n) || $n == 0 ? $fallback : $n;
        return min(1000, max(1, $n));
    }

    // The routes.

    private function sites(): array
    {
        return $this->rl->sites();
    }

    private function store(): SqlStore
    {
        return $this->rl->store;
    }

    /** Whether this request acts as the owner. "read" is someone signed in who may only read, such as a viewer. */
    private function canRead(Request $request): bool|string
    {
        if (isset($this->managed[$request])) {
            return true;
        }
        $authorize = $this->options['authorize'] ?? null;
        if ($authorize !== null || $this->web !== null) {
            // A script's bearer token still has full access beside the sign-ins.
            $given = self::bearer($request);
            if ($authorize === null && $this->token !== null && $this->token !== '' && $given !== '' && self::constantTimeEqual($given, $this->token)) {
                return true;
            }
            $answer = $authorize !== null ? $authorize($request) : $this->web->access($request);
            // A member changes things like an owner, apart from the few controls adminOnly() names.
            if ($answer === 'member') {
                $this->members[$request] = true;
            }
            return $answer === 'read' ? 'read' : ($answer === true || $answer === 'member');
        }
        if ($this->token === null) {
            return true;
        }
        if ($this->token === '') {
            // Fails closed: only a process that says it is in development runs open.
            if (!self::isDevelopment()) {
                return 'unconfigured';
            }
            if (!$this->warned) {
                $this->warned = true;
                error_log('Runlight: no RUNLIGHT_TOKEN set, so the dashboard is open because NODE_ENV is development. Anywhere else it answers 503 until a token is set.');
            }
            return true;
        }
        $given = self::bearer($request);
        if ($given !== '' && self::constantTimeEqual($given, $this->token)) {
            return true;
        }
        $cookie = self::readCookie($request, self::COOKIE);
        return $cookie !== '' && self::constantTimeEqual($cookie, self::cookieValue($this->token));
    }

    /** The controls a member cannot change: the mail service and its keys, the assistant's settings, and deleting a site. */
    private static function adminOnly(string $path, string $method): bool
    {
        return ($path === '/api/mail' && ($method === 'PUT' || $method === 'DELETE'))
            || ($path === '/api/assistant' && ($method === 'PUT' || $method === 'DELETE'))
            || ($path === '/api/assistant/limits' && $method === 'PUT')
            || ($path === '/api/assistant/models' && $method === 'POST')
            || (preg_match('#^/api/sites/[^/]+\z#', $path) && $method === 'DELETE');
    }

    /**
     * An API token from the bearer header: read-only, and maybe limited to one site.
     *
     * @return array<string, mixed>|null
     */
    private function apiToken(Request $request): ?array
    {
        $given = self::bearer($request);
        if (!str_starts_with($given, self::TOKEN_PREFIX)) {
            return null;
        }
        $this->rl->init();
        $row = $this->store()->tokenByHash(Hash::sha256($given));
        if ($row === null) {
            return null;
        }
        $now = $this->rl->now();
        // At most once a minute, so a busy assistant does not write on every call.
        if ($row['lastUsedAt'] === null || $now - $row['lastUsedAt'] > 60_000) {
            $this->store()->touchToken($row['id'], $now);
        }
        return $row;
    }

    /**
     * Who may read stats: the owner (true), an API token or a read-only sign-in, or nobody.
     *
     * @return true|array<string, mixed>|false|'unconfigured'
     */
    private function reader(Request $request): bool|array|string
    {
        $token = $this->apiToken($request);
        if ($token !== null) {
            return $token;
        }
        if (($this->options['authorize'] ?? null) !== null || $this->web !== null) {
            $access = $this->canRead($request);
            // A read-only sign-in reads like an API token for every site.
            return $access === 'read' ? ['id' => '', 'name' => '', 'site' => '', 'scope' => 'read', 'hash' => '', 'hint' => '', 'createdAt' => 0, 'lastUsedAt' => null] : $access === true;
        }
        $access = $this->canRead($request);
        return $access === 'read' ? false : $access;
    }

    /** The refusal for a hub that asks for something only safe once this app knows its own address. */
    private static function originNeeded(): Response
    {
        return self::coded("Set this Runlight's own address first (RUNLIGHT_URL on the server, or origin in routes()), so a connected hub can add link domains and email reports.", 'origin_needed', 400);
    }

    private static function denied(bool|string $result): Response
    {
        if ($result === 'read') {
            return self::coded('Only an owner can change this', 'owner_only', 403);
        }
        return $result === 'unconfigured'
            ? self::coded('Set RUNLIGHT_TOKEN, or pass token or authorize to routes(). Without one, Runlight only runs open when NODE_ENV is development.', 'token_unset', 503)
            : self::coded('Unauthorized', 'unauthorized', 401);
    }

    /** @return array<string, mixed>|Response */
    private function querySite(Url $url): array|Response
    {
        return $this->rl->site($url->searchParams()->get('site')) ?? self::coded('Unknown site', 'unknown_site', 404);
    }

    /**
     * @param array<string, mixed> $site
     * @return array{query: array<string, mixed>, range: array<string, mixed>, compared: ?array<string, mixed>}|Response
     */
    private function readQuery(Url $url, array $site): array|Response
    {
        $params = $url->searchParams();
        $filters = [];
        if (count($params->getAll('filter')) > Query::MAX_FILTERS) {
            return self::coded('Use at most ' . Query::MAX_FILTERS . ' filters at once.', 'filters_max', 400, ['max' => (string) Query::MAX_FILTERS]);
        }
        foreach ($params->getAll('filter') as $raw) {
            $filter = Query::parseFilter($raw);
            if ($filter === null) {
                return self::coded("Bad filter \"$raw\". Use dimension:is|not|contains:value.", 'filter_bad', 400, ['filter' => $raw]);
            }
            $filters[] = $filter;
        }
        $now = $this->rl->now();
        $firstDate = null;
        if ($params->get('period') === 'all') {
            $first = $this->store()->firstSeen($site['id']);
            if ($first !== null) {
                $firstDate = Time::localDate((int) $first, $site['timezone']);
            }
        }
        $range = Time::resolveRange(['period' => $params->get('period'), 'from' => $params->get('from'), 'to' => $params->get('to'), 'interval' => $params->get('interval')], $site['timezone'], $now, $firstDate);
        if ($range === null) {
            return self::coded('Bad date range. Use period, or from and to as YYYY-MM-DD.', 'range_bad', 400);
        }
        $query = ['site' => $site['id'], 'from' => $range['from'], 'to' => $range['to'], 'filters' => $filters];
        // compare=false is the older spelling of off.
        $raw = $params->get('compare') ?? 'previous';
        $mode = $raw === 'false' ? 'off' : $raw;
        if (!in_array($mode, ['previous', 'year', 'custom', 'off'], true)) {
            return self::coded("Bad compare \"$raw\". Use previous, year, custom, or off.", 'compare_bad', 400, ['compare' => $raw]);
        }
        $compared = Time::compareRange($range, $mode, $site['timezone'], ['from' => $params->get('compare_from'), 'to' => $params->get('compare_to')]);
        if ($mode === 'custom' && $compared === null) {
            return self::coded('Bad comparison range. Use compare_from and compare_to as YYYY-MM-DD.', 'compare_range_bad', 400);
        }
        return ['query' => $query, 'range' => $range, 'compared' => $compared];
    }

    private static function readJson(Request $request): \stdClass|Response
    {
        // A form posted from another site cannot carry this content type without CORS.
        if (!self::isJson($request)) {
            return self::coded('Send JSON', 'send_json', 415);
        }
        [$parsed, $body] = Js::parseJson($request->text());
        return $parsed && $body instanceof \stdClass ? $body : self::coded('Send a JSON object', 'send_object', 400);
    }

    private function linksApi(Request $request, string $path, Url $url): Response
    {
        $this->rl->init();
        $site = $this->querySite($url);
        if ($site instanceof Response) {
            return $site;
        }
        $store = $this->store();
        $ownDomains = fn (): array => array_values(array_map(fn (array $d) => $d['domain'], array_filter($store->linkDomains(), fn (array $d) => $d['site'] === $site['id'])));
        try {
            if ($path === '/api/link-domains') {
                if ($request->method === 'GET') {
                    return self::json(['domains' => $ownDomains()]);
                }
                if ($request->method === 'POST') {
                    $body = self::readJson($request);
                    if ($body instanceof Response) {
                        return $body;
                    }
                    $domain = Js::lower(Js::trim(self::text($body, 'domain')));
                    $domain = (string) preg_replace('#^https?://#', '', $domain);
                    $domain = (string) preg_replace('#/.*\z#', '', $domain);
                    $domain = (string) preg_replace('/\.+\z/', '', $domain);
                    $domain = (string) preg_replace('/^www\./', '', $domain);
                    if (!preg_match(self::DOMAIN_NAME, $domain)) {
                        return self::coded('That is not a domain name', 'domain_invalid', 400);
                    }
                    if (self::privateName($domain) || Safefetch::resolvesPrivately($domain)) {
                        return self::coded("$domain is not a public domain name. Use one that browsers anywhere can reach.", 'domain_not_public', 400, ['domain' => $domain]);
                    }
                    // A link domain answers every path on it, so it must never be where the dashboard or a counted site lives.
                    // The request's own Host is the caller's to choose, so the configured address and the names people
                    // signed in from count too. A hub cannot know every name this app answers on, so it adds none until
                    // the app knows its own address.
                    if (isset($this->managed[$request]) && $this->origin === null) {
                        return self::originNeeded();
                    }
                    $here = array_filter([$request->headers->get('host'), $request->headers->get('x-forwarded-host'), $url->host()], fn ($h) => Js::truthy($h));
                    $own = [...($this->origin !== null ? [(new Url($this->origin))->host()] : []), ...$here];
                    if (isset($this->options['ownHosts'])) {
                        foreach (($this->options['ownHosts'])() as $host) {
                            $own[] = (string) $host;
                        }
                    }
                    $taken = array_map(self::hostName(...), $own);
                    foreach ($this->sites() as $s) {
                        array_push($taken, ...$s['hostnames']);
                        array_push($taken, ...($this->rl->remote($s['id'])['hostnames'] ?? []));
                    }
                    if (in_array($domain, $taken, true)) {
                        return self::coded("$domain is where this dashboard or one of your sites lives. Use a separate domain or subdomain for short links, such as go.$domain.", 'domain_in_use', 400, ['domain' => $domain]);
                    }
                    foreach ($store->linkDomains() as $d) {
                        if ($d['domain'] === $domain) {
                            if ($d['site'] !== $site['id']) {
                                return self::coded("$domain already belongs to another site", 'domain_taken', 409, ['domain' => $domain]);
                            }
                            break;
                        }
                    }
                    $store->addLinkDomain($domain, $site['id'], $this->rl->now());
                    $this->rl->forgetLinkDomains();
                    return self::json(['domain' => $domain], 201);
                }
            }
            if (preg_match('#^/api/link-domains/([^/]+)/check\z#', $path, $checkMatch) && $request->method === 'GET') {
                $domain = self::decode($checkMatch[1]);
                if (!in_array($domain, $ownDomains(), true)) {
                    return self::coded('Unknown domain', 'unknown_domain', 404);
                }
                // One added before names inside private networks were refused is never fetched.
                // What the check found, as a code the dashboard says in its own words, beside the English reason.
                // Where the domain should point, for the setup steps: this server's name, and its public addresses
                // for a bare domain, which takes an A record. A server reached by its address has no name to give.
                $ownHost = $this->origin !== null ? (new Url($this->origin))->hostname : $url->hostname;
                $target = ['host' => $ownHost, 'addresses' => Safefetch::publicAddresses($ownHost)];
                $result = function (string $code, string $reason, ?array $params = null) use ($domain, $target): Response {
                    $out = ['domain' => $domain, 'working' => $code === '', 'reason' => $reason, 'target' => $target];
                    if ($code !== '') {
                        $out['code'] = $code;
                        if ($params !== null) {
                            $out['params'] = (object) $params;
                        }
                    }
                    return self::json($out);
                };
                if (!preg_match(self::DOMAIN_NAME, $domain) || self::privateName($domain)) {
                    return $result('check_not_public', 'is not a public domain name');
                }
                try {
                    // Only a public address is fetched, whatever the name resolves to now, so the check cannot be pointed
                    // into a private network.
                    $answer = Safefetch::publicFetch("https://$domain" . self::LINK_DOMAIN_CHECK, ['timeoutMs' => 5000], $this->rl->fetcher);
                    try {
                        [$parsed, $body] = Js::parseJson($answer->text());
                    } catch (\Throwable) {
                        $parsed = false;
                        $body = null;
                    }
                    $body = $parsed && Js::isObject($body) ? $body : null;
                    if ($answer->ok() && $body !== null && Js::get($body, 'runlight') === true && Js::get($body, 'domain') === $domain) {
                        return $result('', '');
                    }
                    return $answer->ok() ? $result('check_not_runlight', 'answered, but not from Runlight') : $result('check_status', "answered {$answer->status}", ['status' => (string) $answer->status]);
                } catch (\Throwable $error) {
                    // A refused private address answers as a closed port does, so the check tells nothing about a private network.
                    return $error instanceof FetchError && $error->timedOut ? $result('check_timeout', 'timed out') : $result('check_https', 'could not connect over HTTPS');
                }
            }

            if (preg_match('#^/api/link-domains/([^/]+)\z#', $path, $domainMatch) && $request->method === 'DELETE') {
                $domain = self::decode($domainMatch[1]);
                if (!in_array($domain, $ownDomains(), true)) {
                    return self::coded('Unknown domain', 'unknown_domain', 404);
                }
                $store->removeLinkDomain($domain);
                $this->rl->forgetLinkDomains();
                return self::json(['ok' => true]);
            }

            if ($path === '/api/links') {
                if ($request->method === 'GET') {
                    $read = $this->readQuery($url, $site);
                    if ($read instanceof Response) {
                        return $read;
                    }
                    $links = $store->links($site['id'], $read['range']['from'], $read['range']['to']);
                    // Links on a removed domain are served from the app's own path until it is added back.
                    return self::json(['prefix' => $url->origin() . $this->rl->linkPath, 'domains' => $ownDomains(), 'links' => $links]);
                }
                if ($request->method === 'POST') {
                    $body = self::readJson($request);
                    if ($body instanceof Response) {
                        return $body;
                    }
                    $input = ['url' => self::text($body, 'url')];
                    foreach (['name', 'slug', 'domain'] as $key) {
                        if (self::defined($body, $key)) {
                            $input[$key] = Js::string(Js::get($body, $key));
                        }
                    }
                    $link = $this->rl->links->create($site['id'], $input);
                    return self::json(['link' => $link], 201);
                }
            }

            // One step of an import from another shortener; the page calls again with the cursor.
            if (preg_match('#^/api/links/import/([a-z]+)\z#', $path, $importMatch) && $request->method === 'POST') {
                $body = self::readJson($request);
                if ($body instanceof Response) {
                    return $body;
                }
                $cursor = Js::get($body, 'cursor');
                $done = Js::number(Js::get($body, 'done') instanceof Undefined ? NAN : Js::get($body, 'done'));
                try {
                    $step = Importers::importStep(
                        $this->rl,
                        $site['id'],
                        $importMatch[1],
                        self::credentials(Js::get($body, 'credentials')),
                        is_string($cursor) ? $cursor : null,
                        is_float($done) && is_nan($done) ? 0 : $done,
                    );
                    return self::json($step);
                } catch (ImportError $error) {
                    return self::refused($error, 'import_failed');
                }
            }

            if ($path === '/api/links/import' && $request->method === 'POST') {
                $body = self::readJson($request);
                if ($body instanceof Response) {
                    return $body;
                }
                // Rows that are not objects (null, a number) are dropped rather than failing the import.
                $given = Js::get($body, 'rows');
                if (!is_array($given)) {
                    return self::coded('Send rows as a list', 'rows_needed', 400);
                }
                $rows = array_slice(array_values(array_filter($given, fn ($row) => $row instanceof \stdClass)), 0, 5000);
                return self::json($this->rl->links->import($site['id'], array_map(self::plain(...), $rows)));
            }

            if (preg_match('#^/api/links/([a-f0-9]+)\z#', $path, $linkMatch)) {
                $id = $linkMatch[1];
                if ($request->method === 'GET') {
                    $link = $store->linkById($id);
                    if ($link === null || $link['site'] !== $site['id']) {
                        return self::coded('Unknown link', 'unknown_link', 404);
                    }
                    $read = $this->readQuery($url, $site);
                    if ($read instanceof Response) {
                        return $read;
                    }
                    $range = $read['range'];
                    $by = fn (string $dimension): array => Query::isSessionDimension($dimension) ? $store->linkBreakdown($site['id'], $id, $range['from'], $range['to'], $dimension, 10) : [];
                    $series = $store->linkSeries($site['id'], $id, Time::buckets($range, $site['timezone']));
                    $clicks = 0;
                    foreach ($series as $p) {
                        $clicks += $p['clicks'];
                    }
                    return self::json([
                        'link' => $link,
                        'range' => ['from' => $range['fromDate'], 'to' => $range['toDate'], 'interval' => $range['interval'], 'timezone' => $site['timezone']],
                        'clicks' => $clicks,
                        'series' => $series,
                        'sources' => $by('source'),
                        'referrers' => $by('referrer'),
                        'countries' => $by('country'),
                        'devices' => $by('device'),
                        'browsers' => $by('browser'),
                    ]);
                }
                $owned = $store->linkById($id);
                if ($owned === null || $owned['site'] !== $site['id']) {
                    return self::coded('Unknown link', 'unknown_link', 404);
                }
                if ($request->method === 'PATCH') {
                    $body = self::readJson($request);
                    if ($body instanceof Response) {
                        return $body;
                    }
                    $patch = [];
                    foreach (['url', 'name', 'slug', 'domain'] as $key) {
                        if (self::defined($body, $key)) {
                            $patch[$key] = Js::string(Js::get($body, $key));
                        }
                    }
                    return self::json(['link' => $this->rl->links->update($id, $patch)]);
                }
                if ($request->method === 'DELETE') {
                    $this->rl->links->remove($id);
                    return self::json(['ok' => true]);
                }
            }
        } catch (LinkError $error) {
            return self::coded($error->getMessage(), $error->code, 400, $error->params);
        } catch (\RangeException $error) {
            return self::coded($error->getMessage(), 'unknown_link', 404);
        }
        return self::coded('Not found', 'not_found', 404);
    }

    /** The key picker tickets are signed with, made on first use and kept in the database for every process. */
    private function pickKey(): string
    {
        $this->rl->init();
        $saved = $this->store()->setting('pick-key');
        if ($saved !== null && $saved !== '') {
            return $saved;
        }
        $made = Hash::randomId(32);
        $this->store()->setSetting('pick-key', $made);
        return $made;
    }

    /** A ticket that lets the picker, on `site`'s pages, send its choice to `origin`, the dashboard that asked, for half an hour. */
    private function pickTicket(string $origin, string $site): string
    {
        $payload = ($this->rl->now() + self::PICK_TICKET_MS) . '.' . bin2hex($site) . '.' . bin2hex($origin);
        return "$payload." . Hash::hmac($this->pickKey(), $payload);
    }

    /**
     * The dashboard origin and site a picker ticket names, or null when it is not one this install signed or has run out.
     *
     * @return array{origin: string, site: string}|null
     */
    private function pickTarget(string $ticket): ?array
    {
        if (!preg_match('/^(\d+)\.([a-f0-9]{2,512})\.([a-f0-9]{2,512})\.([a-f0-9]{64})\z/', $ticket, $parts) || Js::number($parts[1]) < $this->rl->now()) {
            return null;
        }
        if (!self::constantTimeEqual($parts[4], Hash::hmac($this->pickKey(), "{$parts[1]}.{$parts[2]}.{$parts[3]}"))) {
            return null;
        }
        $unhex = fn (string $text): string => Js::scrub((string) hex2bin(substr($text, 0, strlen($text) - strlen($text) % 2)));
        $origin = $unhex($parts[3]);
        return self::isOrigin($origin) ? ['origin' => $origin, 'site' => $unhex($parts[2])] : null;
    }

    /**
     * The tracker with click rules inside, rebuilt when goals change. With ?site= it carries only that site's rules,
     * so one site's visitors never see another site's domains or goals. The standalone server's snippet always names
     * the site; without a name it serves no rules, and an app's own install, whose sites all belong to one owner,
     * serves every site's.
     *
     * @return array{body: string, etag: string, at: int}
     */
    private function trackerScript(?string $siteId): array
    {
        $key = $siteId ?? '';
        $cached = $this->trackers[$key] ?? null;
        if ($cached !== null && $this->rl->now() - $cached['at'] < 60_000) {
            return $cached;
        }
        $this->rl->init();
        $sites = $siteId !== null ? array_values(array_filter($this->sites(), fn (array $s) => $s['id'] === $siteId)) : ($this->rl->managedSites ? [] : $this->sites());
        $rules = Json::encode((object) Goals::clickRules($sites, $this->store()->goals()));
        $tracker = self::asset('tracker.js');
        $at = strpos($tracker, self::RULES_PLACEHOLDER);
        $body = $at === false ? $tracker : substr_replace($tracker, $rules, $at, strlen(self::RULES_PLACEHOLDER));
        $script = ['body' => $body, 'etag' => '"' . self::hash('trackerHash') . '-' . substr(Hash::sha256($rules), 0, 8) . '"', 'at' => $this->rl->now()];
        // One entry per site at most; a query naming no real site gets the empty script without filling the map.
        if ($siteId === null || $sites) {
            $this->trackers[$key] = $script;
        }
        return $script;
    }

    private function goalWrites(Request $request, string $path, Url $url): Response
    {
        $this->rl->init();
        $site = $this->querySite($url);
        if ($site instanceof Response) {
            return $site;
        }
        $existing = $this->store()->goals($site['id']);
        $id = $path === '/api/goals' ? null : self::decode(substr($path, strlen('/api/goals/')));
        $before = null;
        foreach ($existing as $g) {
            if ($g['id'] === $id) {
                $before = $g;
            }
        }
        if ($id !== null && $before === null) {
            return self::coded('Unknown goal', 'unknown_goal', 404);
        }
        $this->trackers = [];
        if ($request->method === 'DELETE') {
            $this->store()->deleteGoal($id);
            return self::json(['ok' => true]);
        }
        $body = self::readJson($request);
        if ($body instanceof Response) {
            return $body;
        }
        try {
            $goal = Goals::goalFrom($body, $site['id'], $existing, $this->rl->now(), $id);
            $this->store()->saveGoal($goal, $before);
            return self::json(['goal' => $goal], $id !== null && $id !== '' ? 200 : 201);
        } catch (GoalError $error) {
            return self::refused($error, 'goal_invalid');
        }
    }

    /** @param array<string, mixed> $r */
    private static function reportView(array $r): array
    {
        return ['id' => $r['id'], 'site' => $r['site'], 'email' => $r['email'], 'frequency' => $r['frequency'], 'lang' => $r['lang'], 'lastSentAt' => $r['lastSentAt'], 'createdAt' => $r['createdAt']];
    }

    private function mailApi(Request $request, string $path, Url $url): Response
    {
        $this->rl->init();
        try {
            if ($path === '/api/mail') {
                if ($request->method === 'GET') {
                    $settings = $this->rl->mailSettings();
                    $service = null;
                    foreach (Transports::SERVICES as $s) {
                        if ($s['id'] === ($settings['service'] ?? null)) {
                            $service = $s;
                            break;
                        }
                    }
                    // Secret fields come back only as "saved", never as their value.
                    $fields = [];
                    $saved = [];
                    foreach ($service['fields'] ?? [] as $f) {
                        if (!empty($f['secret'])) {
                            if (Js::truthy($settings[$f['name']] ?? null)) {
                                $saved[] = $f['name'];
                            }
                        } else {
                            $value = $settings[$f['name']] ?? null;
                            $fields[$f['name']] = $value === null ? '' : Js::string($value);
                        }
                    }
                    // A hub with a manage token learns which service sends the reports and from where, nothing more.
                    $viaManage = isset($this->managed[$request]);
                    return self::json([
                        'source' => $settings['source'] ?? null,
                        'service' => $settings['service'] ?? '',
                        'from' => $settings['from'] ?? '',
                        'fromName' => $settings['fromName'] ?? '',
                        'fields' => $viaManage ? Json::object() : (object) $fields,
                        'saved' => $viaManage ? [] : $saved,
                        'encrypted' => $this->rl->secret !== null,
                        'services' => Transports::SERVICES,
                    ]);
                }
                if ($request->method === 'PUT') {
                    $body = self::readJson($request);
                    if ($body instanceof Response) {
                        return $body;
                    }
                    $this->rl->saveMailSettings(self::plain($body));
                    return self::json(['ok' => true]);
                }
                if ($request->method === 'DELETE') {
                    $this->rl->saveMailSettings(null);
                    return self::json(['ok' => true]);
                }
                return self::coded('Method not allowed', 'method_not_allowed', 405);
            }

            if ($path === '/api/mail/test' && $request->method === 'POST') {
                $body = self::readJson($request);
                if ($body instanceof Response) {
                    return $body;
                }
                $to = Js::trim(self::text($body, 'to'));
                if (!self::isEmail($to)) {
                    return self::coded('Enter an email address to send the test to', 'test_email', 400);
                }
                $settings = $this->rl->mailSettings();
                if ($settings === null) {
                    return self::coded('Set up a mail service first', 'mail_unset', 400);
                }
                $t = Messages::translator(self::text($body, 'lang', 'en'))['t'];
                $name = '';
                foreach (Transports::SERVICES as $s) {
                    if ($s['id'] === $settings['service']) {
                        $name = $s['name'];
                        break;
                    }
                }
                $this->rl->sendMail([
                    'to' => $to,
                    'subject' => $t('email.test.subject'),
                    'text' => $t('email.test.body', ['service' => $name]),
                    'html' => '<p style="font-family:sans-serif;font-size:15px">' . self::escapeHtml($t('email.test.body', ['service' => $name])) . '</p>',
                ]);
                return self::json(['ok' => true]);
            }

            $site = $this->querySite($url);
            if ($site instanceof Response) {
                return $site;
            }

            if ($path === '/api/reports') {
                if ($request->method === 'GET') {
                    return self::json(['reports' => array_map(self::reportView(...), $this->store()->reports($site['id'])), 'languages' => Messages::languages()]);
                }
                if ($request->method === 'POST') {
                    $body = self::readJson($request);
                    if ($body instanceof Response) {
                        return $body;
                    }
                    $email = Js::lower(Js::trim(self::text($body, 'email')));
                    if (!self::isEmail($email)) {
                        return self::coded('Enter an email address', 'email_invalid', 400);
                    }
                    $frequency = Js::get($body, 'frequency') === 'monthly' ? 'monthly' : 'weekly';
                    $existing = $this->store()->reports($site['id']);
                    foreach ($existing as $r) {
                        if ($r['email'] === $email && $r['frequency'] === $frequency) {
                            return self::coded("$email already gets the $frequency report", 'report_exists', 400, ['email' => $email]);
                        }
                    }
                    if (count($existing) >= 50) {
                        return self::coded('A site can send to at most 50 addresses', 'report_limit', 400);
                    }
                    // Links in the email point back to the configured address, or else to this dashboard as the
                    // browser sees it. A report made from a hub needs the configured address, where its unsubscribe
                    // link answers, since the Host its request names is the hub's to choose.
                    if (isset($this->managed[$request]) && $this->origin === null) {
                        return self::originNeeded();
                    }
                    $given = $this->origin !== null ? '' : self::text($body, 'origin');
                    $home = preg_match('#^https?://[^' . Js::SPACE . ']+\z#u', Js::scrub($given)) ? (string) preg_replace('#/+\z#', '', $given) : ($this->origin ?? $url->origin()) . $this->base;
                    // A period already due counts as sent, so a report added mid-week first goes out on the next Monday, as the form says.
                    $now = $this->rl->now();
                    $due = Reports::lastPeriod($frequency, $now, $site['timezone']);
                    $lang = Js::string(Js::get($body, 'lang'));
                    $report = [
                        'id' => Hash::randomId(),
                        'site' => $site['id'],
                        'email' => $email,
                        'frequency' => $frequency,
                        'lang' => in_array($lang, Messages::languages(), true) ? $lang : 'en',
                        'token' => Hash::randomId(16),
                        'origin' => $home,
                        'lastPeriod' => $now >= $due['dueAt'] ? $due['key'] : '',
                        'lastSentAt' => null,
                        'createdAt' => $now,
                    ];
                    $this->store()->insertReport($report);
                    return self::json(['report' => self::reportView($report)], 201);
                }
                return self::coded('Method not allowed', 'method_not_allowed', 405);
            }

            $match = preg_match('#^/api/reports/([a-f0-9]{24})(/send)?\z#', $path, $m) ? $m : null;
            $report = $match !== null ? $this->store()->reportBy('id', $match[1]) : null;
            if ($report === null || $report['site'] !== $site['id']) {
                return self::coded('Unknown report', 'unknown_report', 404);
            }
            $send = ($match[2] ?? '') !== '';
            if ($send && $request->method === 'POST') {
                // A sample at most once a minute per report, so the send button cannot be used to flood an inbox. A hub
                // sends one every ten minutes for the whole site, so adding reports again does not start a new count.
                // PHP forgets memory between requests, so when each went out is kept in the install's settings.
                $viaHub = isset($this->managed[$request]);
                $key = 'sample-sent:' . ($viaHub ? "site:{$site['id']}" : $report['id']);
                $wait = $viaHub ? 600_000 : 60_000;
                $last = (int) Js::number($this->store()->setting($key) ?? 0);
                if ($this->rl->now() - $last < $wait) {
                    return $viaHub
                        ? self::coded('A connected hub can send one sample every ten minutes. Wait a few minutes and try again.', 'sample_soon_hub', 429)
                        : self::coded('A sample went out a moment ago. Wait a minute and try again.', 'sample_soon', 429);
                }
                $this->store()->setSetting($key, (string) $this->rl->now());
                $this->rl->deliverReport($report, $site);
                return self::json(['ok' => true]);
            }
            if (!$send && $request->method === 'DELETE') {
                $this->store()->deleteReport($report['id']);
                return self::json(['ok' => true]);
            }
            return self::coded('Method not allowed', 'method_not_allowed', 405);
        } catch (MailError $error) {
            return self::coded($error->getMessage(), $error->code, 400, $error->params);
        }
    }

    /** A plain page for unsubscribing: a button, so a link scanner opening the URL changes nothing. */
    private function unsubscribePage(Request $request, string $token): Response
    {
        $this->rl->init();
        $report = preg_match('/^[a-f0-9]{32}\z/', $token) ? $this->store()->reportBy('token', $token) : null;
        $site = $report !== null ? $this->rl->site($report['site']) : null;
        ['t' => $t, 'lang' => $lang] = Messages::translator($report['lang'] ?? 'en');
        $page = fn (string $body, int $status = 200): Response => self::smallPage($lang, $body, $status);
        if ($report === null || $site === null) {
            return $page('<h1>' . self::escapeHtml($t('email.unsub.goneTitle')) . '</h1><p>' . self::escapeHtml($t('email.unsub.gone')) . '</p>', 404);
        }
        if ($request->method === 'POST') {
            $this->store()->deleteReport($report['id']);
            return $page('<h1>' . self::escapeHtml($t('email.unsub.doneTitle')) . '</h1><p>' . self::escapeHtml($t('email.unsub.done', ['site' => $site['name'], 'email' => $report['email']])) . '</p>');
        }
        return $page(
            '<h1>' . self::escapeHtml($t('email.unsub.title', ['site' => $site['name']])) . '</h1><p>' . self::escapeHtml($t('email.unsub.body', ['email' => $report['email']])) . '</p><form method="post"><button type="submit">' . self::escapeHtml($t('email.unsubscribe')) . '</button></form>',
        );
    }

    private function sharesApi(Request $request, string $path, Url $url): Response
    {
        $this->rl->init();
        $site = $this->querySite($url);
        if ($site instanceof Response) {
            return $site;
        }
        $view = fn (array $share): array => array_merge($share, ['path' => "{$this->base}/share/{$share['id']}"]);

        if ($path === '/api/shares') {
            if ($request->method === 'GET') {
                return self::json(['shares' => array_map($view, $this->store()->shares($site['id']))]);
            }
            if ($request->method === 'POST') {
                $body = self::readJson($request);
                if ($body instanceof Response) {
                    return $body;
                }
                $share = ['id' => Hash::randomId(16), 'site' => $site['id'], 'name' => Js::slice(Js::trim(self::text($body, 'name')), 0, 100), 'createdAt' => $this->rl->now()];
                $this->store()->insertShare($share);
                return self::json(['share' => $view($share)], 201);
            }
            return self::coded('Method not allowed', 'method_not_allowed', 405);
        }

        $id = self::decode(substr($path, strlen('/api/shares/')));
        $share = preg_match(self::SHARE_ID, $id) ? $this->store()->shareById($id) : null;
        if ($share === null || $share['site'] !== $site['id']) {
            return self::coded('Unknown share', 'unknown_share', 404);
        }
        if ($request->method === 'PATCH') {
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $name = Js::slice(Js::trim(self::text($body, 'name')), 0, 100);
            $this->store()->renameShare($share['id'], $name);
            $share['name'] = $name;
            return self::json(['share' => $view($share)]);
        }
        if ($request->method === 'DELETE') {
            $this->store()->deleteShare($share['id']);
            return self::json(['ok' => true]);
        }
        return self::coded('Method not allowed', 'method_not_allowed', 405);
    }

    /** How many questions each viewer may ask the assistant a day, as an owner set it. */
    private function viewerDaily(): int|float
    {
        $saved = $this->store()->setting('assistant-viewer-daily');
        return $saved === null ? self::VIEWER_DAILY : Js::number($saved);
    }

    /**
     * Counts a question to the assistant, which spends the owner's AI credit, or refuses it: past thirty an
     * hour or two at once for anyone, and past the owner's daily number for a viewer. Returns how to finish.
     *
     * The hour's questions are kept in the install's settings, since PHP forgets memory between requests;
     * how many are being answered at once is counted in this process, where a request runs to its end.
     */
    private function askTurn(string $who, bool $owner): Response|\Closure
    {
        $now = $this->rl->now();
        $hourKey = "assistant-hour:$who";
        $saved = Json::tryDecode((string) $this->store()->setting($hourKey), true);
        $at = array_values(array_filter(is_array($saved) ? $saved : [], fn ($t) => (is_int($t) || is_float($t)) && $now - $t < 3_600_000));
        $open = $this->open[$who] ?? 0;
        if (count($at) >= self::ASK_PER_HOUR || $open >= self::ASK_AT_ONCE) {
            return self::coded('You have asked a lot in a short time. Wait a little and ask again.', 'assistant_soon', 429);
        }
        if (!$owner) {
            $limit = $this->viewerDaily();
            $day = 'assistant-asked:' . gmdate('Y-m-d', intdiv($now, 1000));
            $counts = Json::decode($this->store()->setting($day) ?? '{}', true);
            if (($counts[$who] ?? 0) >= $limit) {
                return self::coded('Viewers can ask ' . Js::string($limit) . ' questions a day. Ask again tomorrow.', 'assistant_daily', 429, ['limit' => Js::string($limit)]);
            }
            $counts[$who] = ($counts[$who] ?? 0) + 1;
            $this->store()->setSetting($day, Json::encode((object) $counts));
            foreach ($this->store()->settingsStartingWith('assistant-asked:') as $entry) {
                if ($entry['key'] !== $day) {
                    $this->store()->setSetting($entry['key'], null);
                }
            }
        }
        $at[] = $now;
        $this->store()->setSetting($hourKey, Json::encode($at));
        $this->open[$who] = $open + 1;
        return function () use ($who): void {
            $this->open[$who]--;
        };
    }

    private function tokensApi(Request $request, string $path): Response
    {
        $this->rl->init();
        $view = fn (array $t): array => ['id' => $t['id'], 'name' => $t['name'], 'site' => $t['site'], 'scope' => $t['scope'], 'hint' => $t['hint'], 'createdAt' => $t['createdAt'], 'lastUsedAt' => $t['lastUsedAt']];
        if ($path === '/api/tokens' && $request->method === 'GET') {
            return self::json(['tokens' => array_map($view, $this->store()->tokens())]);
        }
        if ($path === '/api/tokens' && $request->method === 'POST') {
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $name = Js::slice(Js::trim(self::text($body, 'name')), 0, 100);
            if ($name === '') {
                return self::coded('Name the token', 'token_name', 400);
            }
            $site = self::text($body, 'site');
            if ($site !== '' && !in_array($site, array_column($this->sites(), 'id'), true)) {
                return self::coded('Unknown site', 'unknown_site', 404);
            }
            $scope = Js::get($body, 'scope') === 'manage' ? 'manage' : 'read';
            if ($scope === 'manage' && $site === '') {
                return self::coded('A token that changes settings is for one site. Pick the site.', 'token_site', 400);
            }
            $secret = self::TOKEN_PREFIX . Hash::randomId(20);
            $row = ['id' => Hash::randomId(), 'name' => $name, 'site' => $site, 'scope' => $scope, 'hash' => Hash::sha256($secret), 'hint' => substr($secret, -4), 'createdAt' => $this->rl->now(), 'lastUsedAt' => null];
            $this->store()->insertToken($row);
            $by = $this->accountOf !== null ? ($this->accountOf)($request) : null;
            if ($by !== null && $by !== '' && $this->tokenMade !== null && !($this->tokenMade)($row, $by)) {
                $this->store()->deleteToken($row['id']);
                return self::denied('read');
            }
            // The only time the token is ever shown.
            return self::json(['token' => $view($row), 'secret' => $secret], 201);
        }
        if (preg_match('#^/api/tokens/([a-f0-9]{24})\z#', $path, $match) && $request->method === 'DELETE') {
            return $this->store()->deleteToken($match[1]) ? self::json(['ok' => true]) : self::coded('Unknown token', 'unknown_token', 404);
        }
        return self::coded('Not found', 'not_found', 404);
    }

    /** A request for one API path, with the asker's own headers, as the MCP server and the assistant read it. */
    private function readApi(Request $request, Url $url, ?string $defaultSite = null): \Closure
    {
        $headers = new Headers($request->headers);
        foreach (['content-type', 'content-length', self::SHARE_HEADER] as $name) {
            $headers->delete($name);
        }
        return function (string $apiPath, array $params) use ($headers, $url, $defaultSite): Response {
            $target = new Url("{$this->base}$apiPath", $url->origin());
            $query = $target->searchParams();
            foreach ($params as [$key, $value]) {
                $query->append((string) $key, (string) $value);
            }
            // A tool that names no site reads the one on screen, not the install's first.
            if ($defaultSite !== null && $apiPath !== '/api/sites' && !$query->has('site')) {
                $query->set('site', $defaultSite);
            }
            $target->setSearchParams($query);
            return $this->api(new Request($target->href(), 'GET', $headers, '', ''), $apiPath, $target);
        };
    }

    private function api(Request $request, string $path, Url $url): Response
    {
        $rl = $this->rl;
        $method = $request->method;
        // A write must be JSON, which a form on another page cannot send, even the writes that carry no body.
        // That holds without a cookie too, since a browser also sends Basic credentials or comes from an
        // allowed address on its own. A bearer token is never sent by the browser on its own, so it needs no check.
        if (!in_array($method, ['GET', 'HEAD', 'OPTIONS', 'DELETE'], true) && self::bearer($request) === '' && !self::isJson($request)) {
            return self::coded('Send JSON', 'send_json', 415);
        }
        if ($path === '/api' && $method === 'GET') {
            return self::json(['name' => 'runlight', 'version' => Version::version(), 'api' => Version::apiVersion()] + self::IMPLEMENTATION);
        }

        // A hub asks what its token may do before offering to change anything.
        if ($path === '/api/token' && $method === 'GET') {
            $token = $this->apiToken($request);
            if ($token === null) {
                return self::denied(false);
            }
            return self::json(['scope' => $token['scope'], 'site' => $token['site']]);
        }
        // A token can delete itself, which a hub does when it disconnects a site or gets a new token.
        if ($path === '/api/token' && $method === 'DELETE') {
            $token = $this->apiToken($request);
            if ($token === null) {
                return self::denied(false);
            }
            $this->store()->deleteToken($token['id']);
            return self::json(['ok' => true]);
        }

        // Connecting another Runlight through its consent page, so nobody copies a token.
        if ($path === '/api/sites/connect' && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            if (!$rl->managedSites) {
                return self::coded('Sites are set in code', 'sites_in_code', 400);
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $site = Js::get($body, 'site');
            $given = Js::get($body, 'url');
            try {
                return self::json(['authorize' => Connect::startConnect($rl, $given instanceof Undefined ? null : $given, $url->origin() . "{$this->base}/api/sites/connect/done", is_string($site) ? $site : '')]);
            } catch (ConnectError $error) {
                return self::coded($error->getMessage(), $error->code === 'unreachable' ? 'unreachable' : "connect_{$error->code}", 400, $error->params);
            } catch (\RangeException $error) {
                return self::refused($error, 'connect_failed');
            }
        }
        if ($path === '/api/sites/connect/done' && $method === 'GET') {
            $home = $this->base !== '' ? $this->base : '/';
            $access = $this->canRead($request);
            if ($access !== true) {
                return new Response('', 303, ['location' => $home, 'cache-control' => 'no-store']);
            }
            $rl->init();
            try {
                $id = Connect::finishConnect($rl, $url->searchParams());
                // The site's settings open with a word that the connection worked, which a reconnection otherwise lacks.
                $to = "$home?site=" . Js::encodeURIComponent($id) . '&settings=general&connected=1';
            } catch (\RangeException $error) {
                // A code, never the message: the dashboard shows its own words for it, so a link cannot put text there.
                $to = "$home?connect_error=" . ($error instanceof ConnectError ? $error->code : 'failed');
            }
            return new Response('', 303, ['location' => $to, 'cache-control' => 'no-store']);
        }

        $token = str_starts_with(self::bearer($request), self::TOKEN_PREFIX) ? $this->apiToken($request) : null;
        if ($token !== null && $token['scope'] === 'manage' && self::managePath($method, $path)) {
            $asked = $url->searchParams()->get('site');
            $siteMatch = preg_match('#^/api/sites/([^/]+)\z#', $path, $sm) ? $sm : null;
            if (($asked !== null && $asked !== '' && $asked !== $token['site']) || ($siteMatch !== null && self::decode($siteMatch[1]) !== $token['site'])) {
                return self::coded('Unknown site', 'unknown_site', 404);
            }
            if ($siteMatch !== null && self::isJson($request)) {
                // Where a site lives stays with its owner: a hub may rename it, never move it.
                [$parsed, $body] = Js::parseJson($request->text());
                if ($parsed && Js::truthy($body) && Js::isObject($body) && !(Js::get($body, 'hostnames') instanceof Undefined)) {
                    return self::coded("A connected hub cannot change a site's domains", 'hub_domains', 403);
                }
            }
            $url = new Url($url->href());
            $query = $url->searchParams();
            $query->set('site', (string) $token['site']);
            $url->setSearchParams($query);
            $this->managed[$request] = $token;
        }
        // A token this install made that tries a change it may not make is known, just not allowed, as for a viewer.
        if ($token !== null && !isset($this->managed[$request]) && !in_array($method, ['GET', 'HEAD', 'OPTIONS'], true)) {
            return $token['scope'] === 'manage'
                ? self::coded('A manage token changes only its own site\'s settings', 'token_manage_only', 403)
                : self::coded('API tokens can only read', 'token_read_only', 403);
        }

        // A page another site served to an AI agent, reported by a CMS plugin.
        if ($path === '/api/observe' && $method === 'POST') {
            return $this->observeApi($request);
        }

        // GET too: Vercel Cron calls with GET and the cron secret as a bearer token.
        if ($path === '/api/check' && ($method === 'POST' || $method === 'GET')) {
            $given = self::bearer($request);
            $allowed = ($this->cronSecret !== null && $this->cronSecret !== '' && $given !== '' && self::constantTimeEqual($given, $this->cronSecret)) || $this->canRead($request) === true;
            if (!$allowed) {
                return self::coded('Unauthorized', 'unauthorized', 401);
            }
            return self::json($rl->check());
        }

        // A site counted by another install is read there. Its settings change there too,
        // through this server when the install gave a manage token, and only by an owner here.
        $asked = $url->searchParams()->get('site');
        $connected = $asked !== null && $asked !== '' ? $rl->remote($asked) : null;
        if ($connected !== null && ($connected['scope'] ?? null) === 'manage' && self::managePath($method, $path) && !($method === 'GET' && self::sharedPath($path))) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            if ($method !== 'GET') {
                $rl->forgetRemoteInfo($asked);
            }
            return $this->passThrough($connected, $path, $url, $request);
        }
        if ($connected !== null && !($method === 'GET' && (self::sharedPath($path) || $path === '/api/links'))) {
            return self::coded('This site is counted by its own Runlight. Connect it again from its settings to change it from here.', 'site_remote', 400);
        }

        // Visit history from Umami: list the account's websites, then import one a step at a time.
        if (($path === '/api/import/umami/websites' || $path === '/api/import/umami/visits') && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $credentials = self::credentials(Js::get($body, 'credentials'));
            try {
                if ($path === '/api/import/umami/websites') {
                    return self::json(['websites' => Visits::umamiWebsites($credentials, $rl->fetcher)]);
                }
                $rl->init();
                $site = $this->querySite($url);
                if ($site instanceof Response) {
                    return $site;
                }
                $cursor = Js::get($body, 'cursor');
                return self::json(Visits::importUmamiVisits($rl, $site['id'], $credentials, self::text($body, 'website'), is_string($cursor) ? $cursor : null));
            } catch (ImportError $error) {
                return self::refused($error, 'import_failed');
            }
        }

        // Visit history from a CSV file, a batch at a time.
        if ($path === '/api/import/csv/visits' && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $rl->init();
            $site = $this->querySite($url);
            if ($site instanceof Response) {
                return $site;
            }
            try {
                return self::json(Visits::importCsvVisits($rl, $site['id'], self::plain(Js::get($body, 'rows'))));
            } catch (ImportError $error) {
                return self::refused($error, 'import_failed');
            }
        }

        // Each site's key for CMS plugins reporting AI agent fetches: made on first ask, replaced on request.
        if (($path === '/api/observe-key' && $method === 'GET') || ($path === '/api/observe-key/new' && $method === 'POST')) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            $site = $this->querySite($url);
            if ($site instanceof Response) {
                return $site;
            }
            $name = "observe-key:{$site['id']}";
            $key = str_ends_with($path, '/new') ? null : $this->store()->setting($name);
            if ($key === null || $key === '') {
                $key = 'rlo_' . Hash::randomId(20);
                $this->store()->setSetting($name, $key);
            }
            return self::json(['key' => $key]);
        }

        // Making, changing, and deleting funnels; reading them is with the other reports.
        if (($path === '/api/funnels' && $method === 'POST') || (preg_match('#^/api/funnels/[a-f0-9]{24}\z#', $path) && ($method === 'PATCH' || $method === 'DELETE'))) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            $site = $this->querySite($url);
            if ($site instanceof Response) {
                return $site;
            }
            $existing = $this->store()->funnels($site['id']);
            $id = $path === '/api/funnels' ? null : substr($path, strlen('/api/funnels/'));
            if ($id !== null && !in_array($id, array_column($existing, 'id'), true)) {
                return self::coded('Unknown funnel', 'unknown_funnel', 404);
            }
            if ($method === 'DELETE') {
                $this->store()->deleteFunnel($id);
                return self::json(['ok' => true]);
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            try {
                $funnel = Funnels::funnelFrom($body, $site['id'], $existing, $rl->now(), $id);
                $this->store()->saveFunnel($funnel);
                return self::json(['funnel' => $funnel], $id !== null ? 200 : 201);
            } catch (FunnelError $error) {
                return self::refused($error, 'funnel_invalid');
            }
        }

        // The assistant: an owner sets it up; anyone signed in to the dashboard can ask it.
        if ($path === '/api/assistant') {
            $self = $this->canRead($request);
            // A member uses the assistant like anyone else, but its settings are for owners and admins.
            $owner = $self === true && !isset($this->members[$request]);
            if ($method === 'GET') {
                $access = $this->reader($request);
                if ($access === false || $access === 'unconfigured') {
                    return self::denied($access);
                }
                // Only people at the dashboard, never an API token or a share, so nobody spends the owner's AI credit from outside.
                if (is_array($access) && $access['id'] !== '') {
                    return self::coded('Only the dashboard can use the assistant', 'assistant_dashboard', 403);
                }
                $rl->init();
                $settings = $rl->assistantSettings();
                if (!$owner) {
                    return self::json(['configured' => $settings !== null]);
                }
                return self::json([
                    'configured' => $settings !== null,
                    'viewerDaily' => $this->viewerDaily(),
                    'provider' => $settings['provider'] ?? '',
                    'model' => $settings['model'] ?? '',
                    'baseUrl' => $settings['baseUrl'] ?? '',
                    'keySaved' => Js::truthy($settings['key'] ?? null),
                    'encrypted' => $rl->secret !== null,
                    'providers' => Assistant::PROVIDERS,
                ]);
            }
            if (!$owner) {
                return $self === true ? self::coded('Only an owner or admin can change this', 'admin_only', 403) : self::denied($self);
            }
            $rl->init();
            if ($method === 'DELETE') {
                $rl->saveAssistantSettings(null);
                return self::json(['ok' => true]);
            }
            if ($method === 'PUT') {
                $body = self::readJson($request);
                if ($body instanceof Response) {
                    return $body;
                }
                try {
                    $rl->saveAssistantSettings(self::plain($body));
                    return self::json(['ok' => true]);
                } catch (\RangeException $error) {
                    return self::refused($error, 'assistant_invalid');
                }
            }
            return self::coded('Method not allowed', 'method_not_allowed', 405);
        }
        // How many questions each viewer may ask a day; 0 keeps the assistant for owners.
        if ($path === '/api/assistant/limits' && $method === 'PUT') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $daily = Js::number(Js::get($body, 'viewerDaily') instanceof Undefined ? NAN : Js::get($body, 'viewerDaily'));
            if (!is_int($daily) || $daily < 0 || $daily > 1000) {
                return self::coded('Use a whole number from 0 to 1,000', 'assistant_limit', 400);
            }
            $this->store()->setSetting('assistant-viewer-daily', (string) $daily);
            return self::json(['viewerDaily' => $daily]);
        }
        // The models a service offers, for the setup form's dropdown. The key can be the one already saved.
        if ($path === '/api/assistant/models' && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $provider = self::text($body, 'provider');
            $saved = $rl->assistantSettings();
            $baseUrl = (string) preg_replace('#/+\z#', '', Js::trim(self::text($body, 'baseUrl')));
            // The saved key only for the address it was saved with.
            $sameAddress = $saved !== null && $saved['provider'] === $provider && (Js::truthy($saved['baseUrl'] ?? null) ? $saved['baseUrl'] : '') === $baseUrl;
            $key = Js::trim(self::text($body, 'key'));
            if ($key === '') {
                $key = $sameAddress ? (string) $saved['key'] : '';
            }
            try {
                return self::json(['models' => Assistant::listModels(['provider' => $provider, 'baseUrl' => Js::trim(self::text($body, 'baseUrl')), 'key' => $key], $rl->fetcher)]);
            } catch (AssistantError $error) {
                return self::refused($error, 'assistant_failed');
            }
        }
        if ($path === '/api/assistant/chat' && $method === 'POST') {
            return $this->chat($request, $url);
        }

        // Only the owner manages tokens: an API token cannot make or revoke one.
        if ($path === '/api/tokens' || str_starts_with($path, '/api/tokens/')) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            return $this->tokensApi($request, $path);
        }

        if ($connected !== null && $path === '/api/links') {
            $access = $this->reader($request);
            if ($access === false || $access === 'unconfigured') {
                return self::denied($access);
            }
            // A token limited to one site reads only that site's links, here as everywhere else.
            if (is_array($access) && $access['site'] !== '' && $access['site'] !== $asked) {
                return self::coded('Unknown site', 'unknown_site', 404);
            }
            return $this->passThrough($connected, $path, $url);
        }

        // An API token, or someone signed in to read, may list links and see each one's clicks, but not change them.
        if ($method === 'GET' && ($path === '/api/links' || preg_match('#^/api/links/[a-f0-9]+\z#', $path))) {
            $access = $this->reader($request);
            if ($access === false || $access === 'unconfigured') {
                return self::denied($access);
            }
            if (is_array($access)) {
                $rl->init();
                $site = $rl->site($url->searchParams()->get('site') ?? ($access['site'] !== '' ? $access['site'] : null));
                if ($site === null || ($access['site'] !== '' && $site['id'] !== $access['site'])) {
                    return self::coded('Unknown site', 'unknown_site', 404);
                }
                $scoped = new Url($url->href());
                $query = $scoped->searchParams();
                $query->set('site', $site['id']);
                $scoped->setSearchParams($query);
                return $this->linksApi($request, $path, $scoped);
            }
        }

        if ($path === '/api/links' || str_starts_with($path, '/api/links/') || $path === '/api/link-domains' || str_starts_with($path, '/api/link-domains/')) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            return $this->linksApi($request, $path, $url);
        }

        if ($path === '/api/mail' || $path === '/api/mail/test' || $path === '/api/reports' || str_starts_with($path, '/api/reports/')) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            return $this->mailApi($request, $path, $url);
        }

        // A ticket for the element picker, naming the dashboard it may send its choice to. A hub asks the install
        // that serves the site's script, with its own origin, since that install signs what the script will trust.
        if ($path === '/api/pick' && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $rl->init();
            $site = $this->querySite($url);
            if ($site instanceof Response) {
                return $site;
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            $origin = self::text($body, 'origin');
            if (!self::isOrigin($origin)) {
                return self::coded("Send the dashboard's origin, such as https://stats.example.com", 'pick_origin', 400);
            }
            // A hub's ticket only ever sends to the hub it connected from, never to an origin it names now.
            $hub = $this->managed[$request] ?? null;
            if ($hub !== null && $this->store()->setting("token-origin:{$hub['id']}") !== $origin) {
                return self::coded("This hub's address is not the one it connected from. Connect the site again from here.", 'pick_hub', 403);
            }
            return self::json(['ticket' => $this->pickTicket($origin, $site['id'])]);
        }

        if (($path === '/api/goals' && $method === 'POST') || (preg_match('#^/api/goals/[^/]+\z#', $path) && ($method === 'PATCH' || $method === 'DELETE'))) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            return $this->goalWrites($request, $path, $url);
        }

        if ($path === '/api/shares' || str_starts_with($path, '/api/shares/')) {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            return $this->sharesApi($request, $path, $url);
        }

        // Adding and deleting sites, when they are managed in the dashboard.
        if ($path === '/api/sites' && $method === 'POST') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            $body = self::readJson($request);
            if ($body instanceof Response) {
                return $body;
            }
            try {
                return self::json(['site' => $rl->addSite(self::plain($body))], 201);
            } catch (\RangeException $error) {
                return self::refused($error, 'site_invalid');
            }
        }

        if (preg_match('#^/api/sites/([^/]+)\z#', $path, $siteMatch) && $method === 'DELETE') {
            $access = $this->canRead($request);
            if ($access !== true) {
                return self::denied($access);
            }
            try {
                $rl->deleteSite(self::decode($siteMatch[1]));
                return self::json(['ok' => true]);
            } catch (\RangeException $error) {
                return $error->getMessage() === 'Unknown site' ? self::coded($error->getMessage(), 'unknown_site', 404) : self::refused($error, 'site_invalid');
            }
        }
        if ($siteMatch && $method === 'PATCH') {
            return $this->patchSite($request, $siteMatch[1], $url);
        }

        if ($method !== 'GET') {
            return self::coded('Method not allowed', 'method_not_allowed', 405);
        }
        return $this->reports($request, $path, $url);
    }

    private function observeApi(Request $request): Response
    {
        $rl = $this->rl;
        $given = self::bearer($request);
        // The install-wide key and the owner's access can report for any site.
        $anySite = ($this->observeKey !== null && $this->observeKey !== '' && $given !== '' && self::constantTimeEqual($given, $this->observeKey)) || $this->canRead($request) === true;
        if (!$anySite && $given === '') {
            return self::coded('Unauthorized', 'unauthorized', 401);
        }
        $body = self::readJson($request);
        if ($body instanceof Response) {
            return $body;
        }
        // One fetch as { url, userAgent, at? }, or up to 500 as { fetches: [...] } from a log reader.
        $fetches = Js::get($body, 'fetches');
        $batch = is_array($fetches);
        $list = $batch ? $fetches : [$body];
        if (count($list) > 500) {
            return self::coded('Send at most 500 fetches at a time', 'observe_many', 413);
        }
        $pages = [];
        foreach ($list as $item) {
            $read = fn (string $key): mixed => $item instanceof \stdClass ? Js::get($item, $key) : Undefined::value();
            $raw = $read('url');
            $page = Url::parse($raw === null || $raw instanceof Undefined ? '' : Js::string($raw));
            if ($page === null || ($page->protocol !== 'https:' && $page->protocol !== 'http:')) {
                return self::coded("Send the page's url", 'observe_url', 400);
            }
            $at = $read('at');
            $when = is_int($at) || is_float($at) ? $at : (is_string($at) ? ImportHttp::parseDate($at) : null);
            $agent = $read('userAgent');
            $pages[] = [
                'page' => $page,
                'userAgent' => Js::slice($agent === null || $agent instanceof Undefined ? '' : Js::string($agent), 0, 500),
                'at' => $when !== null && is_finite((float) $when) ? $when : null,
            ];
        }
        $rl->init();
        $keep = $pages;
        if (!$anySite) {
            // A site's own key reports only pages on that site's domains. Pages elsewhere in a batch (another
            // host in the same log, say) are skipped, not a reason to refuse the rest.
            $keySite = null;
            foreach ($this->sites() as $site) {
                $key = $this->store()->setting("observe-key:{$site['id']}");
                if ($key !== null && $key !== '' && self::constantTimeEqual($given, $key)) {
                    $keySite = $site['id'];
                }
            }
            if ($keySite === null) {
                return self::coded('Unauthorized', 'unauthorized', 401);
            }
            $keep = array_values(array_filter($pages, fn (array $p) => ($rl->siteFor($p['page']->hostname)['id'] ?? null) === $keySite));
            // A single report for another site's page is a misconfigured plugin, which should hear about it.
            if (!$batch && $keep === []) {
                return self::coded('Unauthorized', 'unauthorized', 401);
            }
        }
        $recorded = 0;
        foreach ($keep as $p) {
            if ($rl->observe(new Request($p['page']->href(), 'GET', ['user-agent' => $p['userAgent']]), $p['at'])) {
                $recorded++;
            }
        }
        // A single report, as the CMS plugins send, needs no answer; a batch learns what was kept.
        if (!$batch) {
            return new Response('', 204);
        }
        return self::json(['recorded' => $recorded, 'skipped' => count($pages) - $recorded]);
    }

    private function chat(Request $request, Url $url): Response
    {
        $rl = $this->rl;
        $access = $this->reader($request);
        if ($access === false || $access === 'unconfigured') {
            return self::denied($access);
        }
        if (is_array($access) && $access['id'] !== '') {
            return self::coded('Only the dashboard can use the assistant', 'assistant_dashboard', 403);
        }
        if ($request->headers->get(self::SHARE_HEADER) !== null) {
            return self::coded('Not available on a shared dashboard', 'share_not_available', 403);
        }
        $rl->init();
        $settings = $rl->assistantSettings();
        if ($settings === null) {
            return self::coded('The assistant is not set up yet. An owner can set it up in Settings, AI Assistant.', 'assistant_unset', 400);
        }
        $body = self::readJson($request);
        if ($body instanceof Response) {
            return $body;
        }
        $siteId = self::text($body, 'site');
        $site = $rl->site($siteId !== '' ? $siteId : null);
        if ($site === null) {
            return self::coded('Unknown site', 'unknown_site', 404);
        }
        $messages = [];
        $given = Js::get($body, 'messages');
        if (is_array($given)) {
            foreach ($given as $m) {
                if ($m instanceof \stdClass && (Js::get($m, 'role') === 'user' || Js::get($m, 'role') === 'assistant') && is_string(Js::get($m, 'content'))) {
                    $messages[] = ['role' => $m->role, 'content' => $m->content];
                }
            }
        }
        if (!$messages || $messages[count($messages) - 1]['role'] !== 'user') {
            return self::coded('Ask a question', 'question_needed', 400);
        }
        $owner = $access === true;
        $who = $this->accountOf !== null ? ($this->accountOf)($request) : null;
        $turn = $this->askTurn($who ?? ($owner ? 'owner' : 'viewer'), $owner);
        if ($turn instanceof Response) {
            return $turn;
        }
        $language = Js::string(Js::get($body, 'language'));
        try {
            $answer = Assistant::chat(
                $settings,
                $messages,
                [
                    'site' => ['id' => $site['id'], 'name' => $site['name'], 'timezone' => $site['timezone']],
                    'today' => Time::localDate($rl->now(), $site['timezone']),
                    'view' => Js::slice(self::text($body, 'view', 'the last 30 days'), 0, 200),
                    'language' => preg_match('/^[a-z]{2}\z/', $language) ? $language : 'en',
                ],
                // Each tool reads the HTTP API with the asker's own headers, as the MCP server does.
                $this->readApi($request, $url, $site['id']),
                $rl->fetcher,
                fn (): int => $rl->now(),
            );
            return self::json($answer);
        } catch (AssistantError $error) {
            return self::refused($error, 'assistant_failed', 502);
        } finally {
            $turn();
        }
    }

    private function patchSite(Request $request, string $rawId, Url $url): Response
    {
        $rl = $this->rl;
        $access = $this->canRead($request);
        if ($access !== true) {
            return self::denied($access);
        }
        // A form posted from another site cannot carry this content type without CORS.
        $body = self::readJson($request);
        if ($body instanceof Response) {
            return $body;
        }
        $rl->init();
        // Every field is checked before any changes, since a shorter retention deletes visits at once.
        if (self::defined($body, 'name')) {
            $name = Js::trim(Js::string(Js::get($body, 'name')));
            if (!($name !== '' && Js::length($name) <= 80)) {
                return self::coded('A site name is 1 to 80 characters', 'site_name', 400);
            }
        }
        if (self::defined($body, 'timezone') && !Time::isTimezone(Js::string(Js::get($body, 'timezone')))) {
            $timezone = Js::string(Js::get($body, 'timezone'));
            return self::coded("Unknown timezone \"$timezone\"", 'unknown_timezone', 400, ['timezone' => $timezone]);
        }
        $retention = Js::get($body, 'retentionMonths');
        if (!($retention instanceof Undefined) && $retention !== null && !in_array(Js::number($retention), self::RETENTION_MONTHS, true)) {
            $months = implode(', ', self::RETENTION_MONTHS);
            return self::coded("Keep visits for $months months, or forever", 'retention_bad', 400, ['months' => $months]);
        }
        try {
            $id = self::decode($rawId);
            $remote = $rl->remote($id);
            // How long a connected site keeps visits, and the timezone its days follow, are the install's
            // settings: this server passes them on, and changes its own row only once the install took them.
            $forward = [];
            if (!($retention instanceof Undefined)) {
                $forward['retentionMonths'] = $retention;
            }
            if (self::defined($body, 'timezone') && Js::string(Js::get($body, 'timezone')) !== ($rl->site($id)['timezone'] ?? null)) {
                $forward['timezone'] = Js::string(Js::get($body, 'timezone'));
            }
            if ($remote !== null && $forward !== []) {
                if (($remote['scope'] ?? null) !== 'manage') {
                    return self::coded('Connect this site again to change it from here', 'connect_again', 400);
                }
                $answer = $this->passThrough(
                    $remote,
                    '/api/sites/' . Js::encodeURIComponent((string) $remote['site']),
                    new Url($url->href()),
                    new Request($request->url, 'PATCH', ['content-type' => 'application/json'], Json::encode($forward)),
                );
                if (!$answer->ok()) {
                    return $answer;
                }
                $rl->forgetRemoteInfo($id);
            } elseif ($remote === null && !($retention instanceof Undefined)) {
                $rl->setRetention($id, $retention === null ? null : Js::number($retention));
            }
            $patch = [];
            if (self::defined($body, 'name')) {
                $patch['name'] = Js::string(Js::get($body, 'name'));
            }
            if (self::defined($body, 'timezone')) {
                $patch['timezone'] = Js::string(Js::get($body, 'timezone'));
            }
            if (self::defined($body, 'hostnames') && $rl->managedSites) {
                $patch['hostnames'] = self::plain(Js::get($body, 'hostnames'));
            }
            $site = $rl->updateSite(self::decode($rawId), $patch);
            // A connected site answers as the list shows it, so the dashboard keeps its install and domains.
            if ($remote !== null) {
                $site['remote'] = $remote['url'];
                $site['remoteSite'] = $remote['site'];
                $site['manage'] = ($remote['scope'] ?? null) === 'manage';
                $site['hostnames'] = $remote['hostnames'];
            }
            return self::json(['site' => $site]);
        } catch (\RangeException $error) {
            return $error->getMessage() === 'Unknown site' ? self::coded($error->getMessage(), 'unknown_site', 404) : self::refused($error, 'site_invalid');
        }
    }

    /** The reads: sites, stats, and every report, for the owner, a token, a viewer, or a share. */
    private function reports(Request $request, string $path, Url $url): Response
    {
        $rl = $this->rl;
        $store = $this->store();
        $params = $url->searchParams();
        $rl->init();
        // A shared dashboard sees exactly what its visitors see, even for someone signed in.
        $shareId = $request->headers->get(self::SHARE_HEADER);
        $shared = null;
        // The one site a share or a site's API token may read; null for every site.
        $only = null;
        if ($shareId !== null) {
            $shared = preg_match(self::SHARE_ID, $shareId) ? $store->shareById($shareId) : null;
            if ($shared === null) {
                return self::coded('This share link no longer works', 'share_gone', 404);
            }
            if (!self::sharedPath($path)) {
                return self::coded('Not available on a shared dashboard', 'share_not_available', 403);
            }
            $only = $shared['site'];
        } else {
            $access = $this->reader($request);
            if ($access === false || $access === 'unconfigured') {
                return self::denied($access);
            }
            if ($access !== true) {
                if (!self::sharedPath($path)) {
                    return self::coded('API tokens can only read', 'token_read_only', 403);
                }
                $only = $access['site'] !== '' ? $access['site'] : null;
            }
        }

        if ($path === '/api/sites') {
            $visible = $only !== null ? array_values(array_filter($this->sites(), fn (array $s) => $s['id'] === $only)) : $this->sites();
            $sites = [];
            foreach ($visible as $site) {
                $remote = $rl->remote($site['id']);
                $row = $site;
                // A connected install's address, so the dashboard can say where the site is counted.
                // Its domains as the install reported them, for the goal picker; tracker hits never match them here.
                if ($remote !== null && $shared === null) {
                    $row['remote'] = $remote['url'];
                    $row['remoteSite'] = $remote['site'];
                    $row['manage'] = ($remote['scope'] ?? null) === 'manage';
                    $row['hostnames'] = $remote['hostnames'];
                }
                // Hostnames say where the site lives; a share shows only its name.
                if ($shared !== null) {
                    $row['hostnames'] = [];
                }
                $row['lastSeen'] = $remote !== null ? $rl->remoteLastSeen($site['id']) : $store->lastSeen($site['id']);
                // Left out for a connected install that cannot be reached, so nobody reads "forever" by mistake.
                if ($shared === null) {
                    $row['retentionMonths'] = $remote !== null ? self::field($rl->remoteInfo($site['id']), 'retentionMonths') : $rl->retention($site['id']);
                }
                // Whether a connected install still takes this server's token, so the dashboard offers to connect it
                // again only when it no longer does.
                if ($remote !== null && $shared === null) {
                    $row['connection'] = self::field($rl->remoteInfo($site['id']), 'connection');
                }
                $sites[] = $row;
            }
            // A share never learns how the install is run.
            return self::json($shared !== null ? ['sites' => $sites] : ['sites' => $sites, 'managed' => $rl->managedSites]);
        }

        $site = $shared !== null ? $rl->site($shared['site']) : ($only !== null ? $rl->site($params->get('site') ?? $only) : $this->querySite($url));
        if ($site instanceof Response) {
            return $site;
        }
        if ($site === null || ($only !== null && $site['id'] !== $only)) {
            return self::coded('Unknown site', 'unknown_site', 404);
        }
        $remote = $rl->remote($site['id']);
        if ($remote !== null) {
            return $this->passThrough($remote, $path, $url, $request);
        }

        if ($path === '/api/icon') {
            $host = $site['hostnames'][0] ?? null;
            // Only a site's own domain, never the request's Host header, which a caller can write.
            $icon = $host !== null && $host !== '' ? Icon::fetchIcon("https://$host", $rl->now(), $rl->fetcher) : null;
            if ($icon === null) {
                return self::coded('No icon', 'icon_none', 404, null, ['cache-control' => 'private, max-age=3600']);
            }
            return new Response($icon['body'], 200, [
                'content-type' => $icon['type'],
                'cache-control' => 'private, max-age=86400',
                // An SVG served from this origin must never run script.
                'content-security-policy' => "default-src 'none'; style-src 'unsafe-inline'; sandbox",
                'x-content-type-options' => 'nosniff',
            ]);
        }

        if ($path === '/api/realtime') {
            return self::json($store->realtime($site['id'], $rl->now()));
        }

        $read = $this->readQuery($url, $site);
        if ($read instanceof Response) {
            return $read;
        }
        ['query' => $query, 'range' => $range, 'compared' => $compared] = $read;
        $rangeOut = ['from' => $range['fromDate'], 'to' => $range['toDate'], 'interval' => $range['interval'], 'timezone' => $site['timezone']];
        $compareOut = $compared !== null ? ['from' => $compared['fromDate'], 'to' => $compared['toDate']] : Undefined::value();
        $before = $compared !== null ? ['from' => $compared['from'], 'to' => $compared['to']] + $query : null;

        if ($path === '/api/stats') {
            $stats = $store->stats($query);
            $previous = $before !== null ? $store->stats($before) : Undefined::value();
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'compare' => $compareOut, 'stats' => $stats, 'previous' => $previous]);
        }

        if ($path === '/api/goals') {
            $goals = $store->goals($site['id']);
            $visitors = $store->visitors($query);
            $previousVisitors = $before !== null ? $store->visitors($before) : 0;
            // Every goal in one pass for the range, and one more for the comparison.
            $nowAll = $store->goalTotalsAll($query, $goals);
            $beforeAll = $before !== null ? $store->goalTotalsAll($before, $goals) : null;
            $rows = [];
            foreach ($goals as $goal) {
                $now = $nowAll[$goal['id']];
                $then = $beforeAll[$goal['id']] ?? null;
                $row = array_merge($goal, $now);
                $row['rate'] = $visitors ? $now['visitors'] / $visitors : 0;
                $row['previous'] = $then !== null ? array_merge($then, ['rate' => $previousVisitors ? $then['visitors'] / $previousVisitors : 0]) : Undefined::value();
                $rows[] = $row;
            }
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'compare' => $compareOut, 'visitors' => $visitors, 'goals' => $rows]);
        }

        if (preg_match('#^/api/goals/([a-f0-9]{24})\z#', $path, $goalMatch)) {
            $goal = $store->goalById($goalMatch[1]);
            if ($goal === null || $goal['site'] !== $site['id']) {
                return self::coded('Unknown goal', 'unknown_goal', 404);
            }
            $visitors = $store->visitors($query);
            $totals = $store->goalTotals($query, $goal);
            $series = $store->goalSeries($query, $goal, Time::buckets($range, $site['timezone']));
            $sources = $store->goalBreakdown($query, $goal, 'source');
            $channels = $store->goalBreakdown($query, $goal, 'channel');
            $pages = $store->goalBreakdown($query, $goal, 'path');
            $totals['rate'] = $visitors ? $totals['visitors'] / $visitors : 0;
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'goal' => $goal, 'totals' => $totals, 'series' => $series, 'sources' => $sources, 'channels' => $channels, 'pages' => $pages]);
        }

        if ($path === '/api/series') {
            $points = $store->series($query, Time::buckets($range, $site['timezone']));
            // Comparison points line up with the main ones by position.
            $previous = $compared !== null ? array_slice($store->series($query, Time::buckets($compared, $site['timezone'])), 0, count($points)) : Undefined::value();
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'compare' => $compareOut, 'points' => $points, 'previous' => $previous]);
        }

        if ($path === '/api/rhythm') {
            // Visits per weekday and hour, plus each cell's details for its tooltip.
            // Visitors are summed over the hours folded into a cell, so someone who
            // came on two Tuesdays at 2pm counts twice there.
            $grid = array_fill(0, 7, array_fill(0, 24, 0));
            $cells = array_fill(0, 7, array_fill(0, 24, ['visits' => 0, 'visitors' => 0, 'pageviews' => 0, 'bounced' => 0]));
            foreach ($store->hourly($query) as $row) {
                [$weekday, $h] = Time::localWeekdayHour((int) ($row['quarter'] * 900_000), $site['timezone']);
                $grid[$weekday][$h] += $row['visits'];
                $cells[$weekday][$h]['visits'] += $row['visits'];
                $cells[$weekday][$h]['visitors'] += $row['visitors'];
                $cells[$weekday][$h]['pageviews'] += $row['pageviews'];
                $cells[$weekday][$h]['bounced'] += $row['bounced'];
            }
            $details = array_map(fn (array $day) => array_map(fn (array $c) => ['visits' => $c['visits'], 'visitors' => $c['visitors'], 'pageviews' => $c['pageviews'], 'bounceRate' => $c['visits'] ? $c['bounced'] / $c['visits'] : 0], $day), $cells);
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'grid' => $grid, 'cells' => $details]);
        }

        if ($path === '/api/journeys') {
            $through = preg_match('/^(\d+):(.+)\z/', $params->get('through') ?? '', $tm) ? $tm : null;
            // Journeys reads the newest visits up to a cap; say when it was reached.
            ['rows' => $rows, 'sampled' => $sampled] = $store->journeyPages($query, Journeys::PAGES_PER_VISIT);
            $options = ['steps' => Js::number($params->get('steps') ?? 5)];
            if (Js::truthy($params->get('start'))) {
                $options['start'] = $params->get('start');
            }
            if (Js::truthy($params->get('end'))) {
                $options['end'] = $params->get('end');
            }
            if ($through !== null) {
                $options['through'] = ['step' => Js::number($through[1]), 'value' => $through[2]];
            }
            $answer = ['site' => $site['id'], 'range' => $rangeOut] + Journeys::journeys($rows, $options);
            if ($sampled) {
                $answer['sampled'] = SqlStore::JOURNEY_VISITS;
            }
            return self::json($answer);
        }

        if ($path === '/api/funnels') {
            // One funnel at a time, so a page of funnels never takes every database connection at once.
            $rows = [];
            foreach ($store->funnels($site['id']) as $funnel) {
                $counts = $store->funnelCounts($query, $funnel);
                $funnel['steps'] = array_map(fn (array $step, int $i) => array_merge($step, ['visits' => $counts[$i]]), $funnel['steps'], array_keys($funnel['steps']));
                $rows[] = $funnel;
            }
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'funnels' => $rows]);
        }

        if ($path === '/api/event-props') {
            $event = $params->get('event') ?? '';
            if ($event === '') {
                return self::coded('Name the event', 'event_needed', 400);
            }
            $keys = $store->eventPropKeys($query, $event);
            $asked = $params->get('key');
            // A property name goes into a JSON path on SQLite, so quotes and backslashes are refused.
            if ($asked !== null && !preg_match('/^[^"\\\\]{1,64}\z/u', $asked)) {
                return self::coded('Bad property name', 'property_bad', 400);
            }
            $key = $asked ?? ($keys[0]['key'] ?? null);
            $limit = self::limit($params->get('limit'), 100);
            $rows = $key !== null && $key !== '' ? $store->eventPropValues($query, $event, $key, (int) $limit) : [];
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'event' => $event, 'keys' => $keys, 'key' => $key, 'rows' => $rows]);
        }

        if ($path === '/api/breakdown') {
            $dimension = $params->get('dimension') ?? '';
            if (!Query::isDimension($dimension)) {
                return self::coded("Unknown dimension \"$dimension\"", 'unknown_dimension', 400, ['dimension' => $dimension]);
            }
            $limit = self::limit($params->get('limit'), 10);
            $page = Js::number($params->get('page'));
            $page = max(1, is_float($page) && is_nan($page) || $page == 0 ? 1 : $page);
            $rows = $store->breakdown($query, $dimension, (int) $limit, (int) (($page - 1) * $limit));
            if ($params->get('format') === 'csv') {
                return self::download("{$site['id']}-$dimension-{$range['fromDate']}-{$range['toDate']}.csv", self::rowsCsv($rows, ['timezone' => $site['timezone'], 'dimension' => $dimension]), 'text/csv; charset=utf-8');
            }
            return self::json(['site' => $site['id'], 'range' => $rangeOut, 'dimension' => $dimension, 'rows' => $rows]);
        }

        // Everything the dashboard shows for a view, as a ZIP of CSV files.
        if ($path === '/api/export') {
            $files = [];
            $stats = $store->stats($query);
            $previous = $before !== null ? $store->stats($before) : null;
            $now = self::sheetRow($stats, ['timezone' => $site['timezone']]);
            $then = $previous !== null ? self::sheetRow($previous, ['timezone' => $site['timezone']]) : null;
            $overview = [];
            foreach ($now as $m => $value) {
                $overview[] = $then !== null ? [(string) $m, $value, $then[$m] ?? null] : [(string) $m, $value];
            }
            $files[] = ['name' => 'overview.csv', 'text' => Zip::csv($then !== null ? ['metric', 'value', 'previous'] : ['metric', 'value'], $overview)];
            $points = $store->series($query, Time::buckets($range, $site['timezone']));
            $files[] = ['name' => 'over-time.csv', 'text' => self::rowsCsv($points, ['timezone' => $site['timezone'], 'interval' => $range['interval']])];
            foreach (Query::DIMENSIONS as $dimension) {
                $rows = $store->breakdown($query, $dimension, 1000, 0);
                if ($rows) {
                    $files[] = ['name' => "$dimension.csv", 'text' => self::rowsCsv($rows, ['timezone' => $site['timezone'], 'dimension' => $dimension])];
                }
            }
            $goals = $store->goals($site['id']);
            if ($goals) {
                $totals = $store->goalTotalsAll($query, $goals);
                $files[] = [
                    'name' => 'goals.csv',
                    'text' => Zip::csv(['goal', 'conversions', 'visitors', 'revenue', 'currency'], array_map(fn (array $g) => [$g['name'], $totals[$g['id']]['conversions'], $totals[$g['id']]['visitors'], $totals[$g['id']]['revenue'], $g['currency']], $goals)),
                ];
            }
            return self::download("{$site['id']}-{$range['fromDate']}-{$range['toDate']}.zip", Zip::zip($files, $rl->now()), 'application/zip');
        }

        return self::coded('Not found', 'not_found', 404);
    }

    /** A field of a remote's info, or undefined when there is none, which JSON leaves out. */
    private static function field(?array $info, string $key): mixed
    {
        return $info !== null && array_key_exists($key, $info) ? $info[$key] : Undefined::value();
    }

    /**
     * Answers one request under the base path: the dashboard and its assets, the tracker, the API, MCP,
     * OAuth, accounts, and the small pages, as the TypeScript handler does.
     *
     * @param array{ip?: string} $context
     */
    public function handle(Request $request, array $context = []): Response
    {
        $url = new Url($request->url);
        $base = $this->base;
        // OAuth clients look for these at the site's root; an app routes them here when it wants OAuth.
        if ($base !== '' && self::isOauthDocument($url->pathname)) {
            try {
                return OAuth::oauthResponse($this->oauth, $request, $url->pathname, $url, $context) ?? self::coded('Not found', 'not_found', 404);
            } catch (\Throwable $error) {
                error_log("Runlight: $error");
                return self::coded('Internal error', 'internal', 500);
            }
        }
        if ($base !== '' && $url->pathname !== $base && !str_starts_with($url->pathname, "$base/")) {
            return self::coded('Not found', 'not_found', 404);
        }
        $path = substr($url->pathname, strlen($base));
        $path = $path === '' ? '/' : $path;

        try {
            return $this->route($request, $path, $url, $context);
        } catch (\Throwable $error) {
            error_log("Runlight: $error");
            return self::coded('Internal error', 'internal', 500);
        }
    }

    /** @param array{ip?: string} $context */
    private function route(Request $request, string $path, Url $url, array $context): Response
    {
        $rl = $this->rl;
        $base = $this->base;
        $method = $request->method;
        // Checked before any route, so a connected site's pass-through to its install is held to it too.
        if (self::adminOnly($path, $method) && $this->canRead($request) === true && isset($this->members[$request])) {
            return self::coded('Only an owner or admin can change this', 'admin_only', 403);
        }
        // Sign-in, setup, invites, and the Account and People APIs, and the dashboard sends anyone signed out to sign in.
        if ($this->web !== null) {
            $answered = $this->web->handle($request, $path, $context);
            if ($answered !== null) {
                return $answered;
            }
        }
        if ($path === '/s.js' && $method === 'GET') {
            $script = $this->trackerScript($url->searchParams()->get('site'));
            $headers = [
                'content-type' => 'application/javascript; charset=utf-8',
                // Short, so a new click goal reaches visitors within minutes; the etag makes rechecks cheap.
                'cache-control' => 'public, max-age=300',
                'etag' => $script['etag'],
            ];
            if ($request->headers->get('if-none-match') === $script['etag']) {
                return new Response('', 304, $headers);
            }
            return new Response($script['body'], 200, $headers);
        }

        if ($path === '/pick.js' && $method === 'GET') {
            // The picker sends what it picked only to the dashboard its ticket names; without a good ticket it does nothing.
            // It also runs only on the pages of the site the ticket names.
            $target = $this->pickTarget($url->searchParams()->get('runlight_ticket') ?? '');
            if ($target !== null) {
                $rl->init();
            }
            $hosts = $target !== null ? ($rl->site($target['site'])['hostnames'] ?? null) : [];
            $script = self::replaceOnce(self::asset('picker.js'), self::PICK_TARGET_PLACEHOLDER, Json::encode($hosts !== null ? ($target['origin'] ?? '') : ''));
            $script = self::replaceOnce($script, self::PICK_HOSTS_PLACEHOLDER, Json::encode(Json::encode($hosts ?? [])));
            return new Response($script, 200, ['content-type' => 'application/javascript; charset=utf-8', 'cache-control' => 'no-store']);
        }

        if ($path === '/assets/world.' . self::hash('worldHash') . '.json' && $method === 'GET') {
            return new Response(self::asset('world.json'), 200, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'public, max-age=31536000, immutable']);
        }

        if (preg_match('/^\/assets\/locale\.([a-z]{2,3})\.([a-f0-9]+)\.json\z/', $path, $locale) && $locale[2] === self::hash('localesHash') && Js::truthy(self::locales()[$locale[1]] ?? null) && $method === 'GET') {
            return new Response(self::locales()[$locale[1]], 200, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'public, max-age=31536000, immutable']);
        }

        if (str_starts_with($path, '/assets/app.') && $method === 'GET') {
            $hash = self::hash('dashboardHash');
            $asset = $path === "/assets/app.$hash.js" ? self::asset('dashboard.js') : ($path === "/assets/app.$hash.css" ? self::asset('dashboard.css') : null);
            if ($asset === null) {
                return self::coded('Not found', 'not_found', 404);
            }
            return new Response($asset, 200, [
                'content-type' => str_ends_with($path, '.js') ? 'application/javascript; charset=utf-8' : 'text/css; charset=utf-8',
                'cache-control' => 'public, max-age=31536000, immutable',
            ]);
        }

        if ($path === '/e') {
            if ($method === 'OPTIONS') {
                return new Response('', 204, ['access-control-allow-origin' => '*', 'access-control-allow-methods' => 'POST', 'access-control-max-age' => '86400']);
            }
            if ($method !== 'POST') {
                return self::coded('Method not allowed', 'method_not_allowed', 405);
            }
            try {
                $rl->collect($request, $context);
            } catch (\Throwable $error) {
                error_log("Runlight: could not record an event $error");
            }
            // The same answer whatever happened, so the endpoint reveals nothing.
            return new Response('', 202, ['access-control-allow-origin' => '*']);
        }

        if ($path === '/api' || str_starts_with($path, '/api/')) {
            return $this->api($request, $path, $url);
        }

        if (str_starts_with($path, '/oauth/') || self::isOauthDocument($path)) {
            $answer = OAuth::oauthResponse($this->oauth, $request, $path, $url, $context);
            if ($answer !== null) {
                return $answer;
            }
        }

        if ($path === '/mcp') {
            // No server-sent stream and no sessions: every message is one POST.
            if ($method !== 'POST') {
                return self::coded('Method not allowed', 'method_not_allowed', 405, null, ['allow' => 'POST']);
            }
            $access = $this->reader($request);
            if ($access === false || $access === 'unconfigured') {
                $refused = self::denied($access);
                // Points an OAuth client at the metadata that starts the sign-in.
                $refused->headers->set('www-authenticate', 'Bearer realm="runlight", resource_metadata="' . OAuth::resourceMetadataUrl($url->origin(), $base) . '"');
                return $refused;
            }
            // Each tool reads the HTTP API with the caller's own headers, so it sees what they may.
            return Mcp::mcpResponse($request, $this->readApi($request, $url));
        }

        if (preg_match('#^/unsubscribe/([^/]+)/?\z#', $path, $unsubscribe) && ($method === 'GET' || $method === 'POST')) {
            return $this->unsubscribePage($request, $unsubscribe[1]);
        }

        if (preg_match('#^/share/([^/]+)/?\z#', $path, $sharePage) && $method === 'GET') {
            $rl->init();
            $id = $sharePage[1];
            $share = preg_match(self::SHARE_ID, $id) ? $this->store()->shareById($id) : null;
            if ($share === null) {
                ['t' => $t, 'lang' => $lang] = Messages::translator(self::acceptedLanguage($request));
                return self::smallPage($lang, '<h1>' . self::escapeHtml($t('share.goneTitle')) . '</h1><p>' . self::escapeHtml($t('share.gone')) . '</p>', 404);
            }
            return new Response(self::dashboard($base, $share['id'], '', !empty($this->options['geoCredit'])), 200, [
                'content-type' => 'text/html; charset=utf-8',
                'cache-control' => 'no-store',
                'content-security-policy' => self::DASHBOARD_CSP,
                'x-frame-options' => 'DENY',
                // The share id is the key; never send it on to another site.
                'referrer-policy' => 'no-referrer',
                'x-robots-tag' => 'noindex',
            ]);
        }

        if (($path === '/' || $path === '') && $method === 'GET') {
            $given = $url->searchParams()->get('token');
            if ($given !== null && $given !== '' && $this->token !== null && $this->token !== '' && self::constantTimeEqual($given, $this->token)) {
                $query = $url->searchParams();
                $query->delete('token');
                $url->setSearchParams($query);
                $secure = $url->protocol === 'https:' ? '; Secure' : '';
                return new Response('', 303, [
                    'location' => $url->pathname . $url->search,
                    'set-cookie' => self::COOKIE . '=' . self::cookieValue($this->token) . '; Path=' . ($base !== '' ? $base : '/') . "; HttpOnly; SameSite=Lax; Max-Age=2592000$secure",
                ]);
            }
            // The page itself holds no data; the API it calls checks access and
            // the page explains how to sign in when it is refused.
            return new Response(self::dashboard($base, '', $this->signOut ?? '', !empty($this->options['geoCredit']), $this->web !== null, $this->signIn ?? ''), 200, [
                'content-type' => 'text/html; charset=utf-8',
                'cache-control' => 'no-store',
                'content-security-policy' => self::DASHBOARD_CSP,
                'x-frame-options' => 'DENY',
                'referrer-policy' => 'same-origin',
            ]);
        }

        return self::coded('Not found', 'not_found', 404);
    }

    /** `text.replace(search, () => value)`: the first match only, with nothing in `value` read as a pattern. */
    private static function replaceOnce(string $text, string $search, string $value): string
    {
        $at = strpos($text, $search);
        return $at === false ? $text : substr_replace($text, $value, $at, strlen($search));
    }
}
