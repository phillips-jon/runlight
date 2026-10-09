<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\BodyTooLong;
use Runlight\Http\CurlFetcher;
use Runlight\Http\Fetcher;
use Runlight\Http\FetchError;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\Url;
use Runlight\Mail\MailError;
use Runlight\Mail\Secret;
use Runlight\Mail\Transports;
use Runlight\Store\SqlStore;

/**
 * Runlight in an app: the sites it counts, the tracker endpoint's work, short links, email reports, and the
 * scheduled upkeep. A port of the TypeScript SDK's runlight.ts.
 *
 * Options, with the TS names:
 * - store: SqlStore (required), such as Stores::sqlite('./data/runlight.db').
 * - site: array{id?: string, name?: string, hostnames?: list<string>, timezone?: string}, the site this install
 *   counts. Ignored when `sites` is given. `id` is a stable id, stored with every row, default "default".
 *   `hostnames` are the hostnames that belong to the site, without www; with one site, empty means any
 *   hostname, and with several, each site needs at least one. `timezone` is an IANA timezone for reports,
 *   such as "Europe/London", default "UTC".
 * - sites: several sites in one install, told apart by hostname.
 * - managedSites: sites are added, changed, and deleted in the dashboard and kept in the database, as the
 *   standalone server does. `site` and `sites` are ignored.
 * - geo: callable(string $ip): ?array{country, region, city}, a location for an IP when the platform sends
 *   no location headers.
 * - trustProxy: true (default), false, or one of "x-forwarded-for", "x-real-ip", "cf-connecting-ip". Read the
 *   client IP from forwarding headers: the last X-Forwarded-For entry, which the nearest proxy wrote, then
 *   X-Real-IP, then CF-Connecting-IP. Name one of them to read only that header, such as "cf-connecting-ip"
 *   behind Cloudflare and another proxy. False reads only the connection's address, for an app nothing sits
 *   in front of.
 * - linkPath: where short links on the app's own domain live, as `{linkPath}/{slug}`. Default "/go".
 * - mail: the mail service for email reports, in code (a Transports config plus `from` and `fromName`).
 *   When set, the dashboard shows it and cannot change it. Otherwise it is set up in Settings.
 * - secret: encrypts the keys kept in the database: the mail service's, the AI Assistant's, and the tokens
 *   for connected installs. Default the RUNLIGHT_SECRET environment variable, then RUNLIGHT_TOKEN.
 * - rateLimit: tracker requests allowed per visitor address per minute. Default 120, which a real visitor
 *   never reaches; false turns the limit off.
 * - now: callable(): int, the clock in milliseconds. For tests.
 * - fetcher: the Fetcher every outgoing request goes through. Default CurlFetcher.
 *
 * TS runs some work after answering or on timers. Here the retention a settings change asks for runs in
 * idle(), which an adapter calls once the answer is sent, and everything else in check().
 *
 * @phpstan-type SiteRow array{id: string, name: string, hostnames: list<string>, timezone: string}
 * @phpstan-type Remote array{url: string, token: string, site: string, hostnames: list<string>, scope?: string}
 *
 * @property-read list<array> $sites the sites, as TS's getter; sites() is the same
 */
final class Runlight
{
    /** A path on every link domain that answers when the domain reaches this Runlight. */
    public const LINK_DOMAIN_CHECK = '/.well-known/runlight-link-domain';

    /** The choices for how long a site keeps its visits. */
    public const RETENTION_MONTHS = [6, 12, 24, 36, 60];

    /** Thirty minutes without a request ends a session. */
    public const SESSION_IDLE_MS = 30 * 60 * 1000;

    /** What passes for an email address: something@somewhere.tld, with no spaces, quotes, or angle brackets. */
    public const EMAIL = '/^[^' . Js::SPACE . '@<>"]+@[^' . Js::SPACE . '@<>"]+\.[^' . Js::SPACE . '@<>"]+$/uD';

    /** Raised whenever what a rolled-up day holds changes. 2: the heatmap counts visits only. 3: a page counts the views that can report time. */
    private const ROLLUP_VERSION = 3;
    /** Days of rollups built per site in one scheduled check, and how long after a day ends it is built. */
    private const ROLLUP_BATCH = 10;
    /** The most a connected install's list of sites may weigh; a real one is a few kilobytes. */
    private const REMOTE_MAX_BYTES = 2 * 1024 * 1024;
    /** On a database that caps statements per request (Cloudflare D1), fewer days a check, about 30 statements. */
    private const METERED_ROLLUP_BATCH = 4;
    private const ROLLUP_DELAY_MS = 2 * 3_600_000;

    public readonly SqlStore $store;
    /** Whether sites are managed in the dashboard. */
    public readonly bool $managedSites;
    /** Short links: create, change, delete, and import. */
    public readonly Links $links;
    /** Where links on the app's own domain are served, such as "/go". */
    public readonly string $linkPath;
    /** Encrypts the keys kept in the database; null leaves them readable, and the dashboard says so. */
    public readonly ?string $secret;
    /** Every outgoing request goes through it. */
    public readonly Fetcher $fetcher;
    /**
     * Where routes() serves the dashboard and API, which a link domain leaves alone, as a list without
     * repeats. Middleware often runs apart from the routes, where none were made, so the default "/runlight"
     * stands in there.
     *
     * @var list<string>
     */
    public array $routeBases = [];

    /** @var list<array> the sites as configured in code, or as kept in the database when they are managed */
    private array $configured;
    /** @var array<string, array> sites counted by another Runlight install, read through its API with the token it gave, read or manage */
    private array $remotes = [];
    /** @var array<string, array> */
    private array $remoteSeen = [];
    /** @var array<string, array{name?: string, timezone?: string}> */
    private array $overrides = [];
    /** @var (callable(string): ?array)|null */
    private $geo;
    private bool|string $trustProxy;
    private ?RateLimit $limit;
    /** @var callable(): int */
    private $clock;
    private bool $ready = false;
    private bool $checking = false;
    /** When planner statistics were last gathered. */
    private int $optimizedAt = 0;
    /** @var array{at: int, domains: array<string, true>}|null */
    private ?array $linkDomainCache = null;
    /** @var array<string, array{day: string, today: string, yesterday: ?string}> each timezone's salts for its current day, so a lookup is a map read until midnight there */
    private array $salts = [];
    private ?array $mailInCode;
    /** @var list<?string> retention work asked for and not yet done: a site's id, or null for every site */
    private array $pruning = [];

    /** @param array<string, mixed> $options */
    public function __construct(array $options)
    {
        if (!(($options['store'] ?? null) instanceof SqlStore)) {
            throw new \InvalidArgumentException("Runlight: pass a store, such as Stores::sqlite('./data/runlight.db')");
        }
        $this->store = $options['store'];
        $this->managedSites = (bool) ($options['managedSites'] ?? false);
        $configured = $this->managedSites ? [] : (!empty($options['sites']) ? array_values($options['sites']) : [$options['site'] ?? []]);
        $this->configured = array_map(self::siteRow(...), $configured, array_keys($configured));
        if (count($this->configured) > 1) {
            foreach ($this->configured as $site) {
                if ($site['hostnames'] === []) {
                    throw new \InvalidArgumentException('Runlight: with several sites, give each one its hostnames');
                }
            }
        }
        if (count(array_unique(array_column($this->configured, 'id'))) !== count($this->configured)) {
            throw new \InvalidArgumentException('Runlight: two sites share an id');
        }
        $this->geo = $options['geo'] ?? null;
        $this->trustProxy = $options['trustProxy'] ?? true;
        $perMinute = $options['rateLimit'] ?? 120;
        // false, 0, or anything that is not a positive number means no limit, never a limit of nothing.
        $number = $perMinute === false ? NAN : Js::number($perMinute);
        $this->limit = !($number > 0) ? null : new RateLimit((int) min(PHP_INT_MAX, floor($number)), fn (): int => $this->now());
        $this->clock = $options['now'] ?? static fn (): int => (int) floor(microtime(true) * 1000);
        $this->fetcher = $options['fetcher'] ?? new CurlFetcher();
        $this->links = new Links($this);
        $this->linkPath = '/' . preg_replace('#^/+|/+$#', '', (string) ($options['linkPath'] ?? '/go'));
        $this->mailInCode = $options['mail'] ?? null;
        $this->secret = array_key_exists('secret', $options) && $options['secret'] !== null ? (string) $options['secret'] : (Env::get('RUNLIGHT_SECRET') ?? Env::get('RUNLIGHT_TOKEN'));
    }

    /** @param array{id?: string, name?: string, hostnames?: list<string>, timezone?: string} $options */
    private static function siteRow(array $options, int $index): array
    {
        $timezone = $options['timezone'] ?? 'UTC';
        if (!Time::isTimezone($timezone)) {
            throw new \InvalidArgumentException("Runlight: unknown timezone \"$timezone\"");
        }
        $id = $options['id'] ?? ($index === 0 ? 'default' : '');
        if ($id === '' || !preg_match('/^[a-z0-9][a-z0-9._-]{0,63}$/iD', $id)) {
            throw new \InvalidArgumentException("Runlight: site id \"$id\" must be letters, digits, dots, dashes, or underscores");
        }
        $hostnames = $options['hostnames'] ?? [];
        return [
            'id' => $id,
            'name' => $options['name'] ?? ($hostnames[0] ?? 'My site'),
            'hostnames' => array_map(static fn ($h): string => Sources::stripWww((string) $h), array_values($hostnames)),
            'timezone' => $timezone,
        ];
    }

    /** The clock, in milliseconds. */
    public function now(): int
    {
        return (int) ($this->clock)();
    }

    /** The mail service: from code, or as saved in the dashboard. Null when there is none. */
    public function mailSettings(): ?array
    {
        if ($this->mailInCode !== null) {
            return [...$this->mailInCode, 'source' => 'code'];
        }
        $this->init();
        $sealed = $this->store->setting('mail');
        if ($sealed === null || $sealed === '') {
            return null;
        }
        $opened = Secret::unseal($sealed, $this->secret);
        if ($opened === null || $opened === '') {
            return null;
        }
        return [...Json::decode($opened, true), 'source' => 'dashboard'];
    }

    /**
     * Saves the mail service from the dashboard. A secret field left blank
     * keeps the saved value, so the browser never needs to see it.
     *
     * @param array<string, mixed>|null $input
     */
    public function saveMailSettings(?array $input): void
    {
        if ($this->mailInCode !== null) {
            throw new MailError('The mail service is set in code', 'mail_in_code', []);
        }
        if ($input === null) {
            $this->store->setSetting('mail', null);
            return;
        }
        $before = $this->mailSettings();
        $service = null;
        foreach (Transports::SERVICES as $s) {
            if ($s['id'] === ($input['service'] ?? null)) {
                $service = $s;
                break;
            }
        }
        if ($service === null) {
            throw new MailError('Pick a mail service', 'mail_service', []);
        }
        $settings = ['service' => $service['id']];
        foreach ($service['fields'] as $f) {
            if (empty($f['secret'])) {
                $settings[$f['name']] = Js::trim(Js::string($input[$f['name']] ?? ''));
            }
        }
        // A blank secret keeps the saved one only while the connection is the same,
        // so changing the host cannot send a saved password somewhere new.
        $sameConnection = ($before['service'] ?? null) === $service['id'];
        if ($sameConnection) {
            foreach ($service['fields'] as $f) {
                if (empty($f['secret']) && Js::string($before[$f['name']] ?? '') !== $settings[$f['name']]) {
                    $sameConnection = false;
                    break;
                }
            }
        }
        foreach ($service['fields'] as $f) {
            if (empty($f['secret'])) {
                continue;
            }
            $given = Js::trim(Js::string($input[$f['name']] ?? ''));
            $settings[$f['name']] = $given === '' && $sameConnection ? Js::string($before[$f['name']] ?? '') : $given;
        }
        $from = Js::trim(Js::string($input['from'] ?? ''));
        if (!preg_match(self::EMAIL, $from)) {
            throw new MailError('Enter the address reports come from, like reports@example.com', 'mail_from', []);
        }
        $fromName = Js::slice(Js::trim(Js::string($input['fromName'] ?? '')), 0, 80);
        $config = [...$settings, 'from' => $from, ...($fromName !== '' ? ['fromName' => $fromName] : [])];
        Transports::checkConfig($config);
        $this->store->setSetting('mail', Secret::seal(Json::encode($config), $this->secret));
    }

    /**
     * Sends one email through the mail service.
     *
     * @param array{to: string, subject: string, html: string, text: string, headers?: array<string, string>} $message
     */
    public function sendMail(array $message): void
    {
        $settings = $this->mailSettings();
        if ($settings === null) {
            throw new MailError('Set up a mail service first', 'mail_unset', []);
        }
        $full = [...$message, 'from' => $settings['from']];
        if (isset($settings['fromName'])) {
            $full['fromName'] = $settings['fromName'];
        }
        Transports::send($settings, $full, $this->fetcher, $this->now());
    }

    /**
     * Sends every report that is due: last week's on Monday from 8am, last
     * month's on the 1st, in each site's timezone. Safe to run often; each
     * period goes out once. Called by check().
     *
     * @return array{sent: int, failed: int}
     */
    public function sendReports(): array
    {
        $this->init();
        $result = ['sent' => 0, 'failed' => 0];
        $reports = $this->store->reports();
        if ($reports === [] || $this->mailSettings() === null) {
            return $result;
        }
        $now = $this->now();
        foreach ($reports as $r) {
            $site = $this->site($r['site']);
            if ($site === null) {
                continue;
            }
            $period = Reports::lastPeriod($r['frequency'], $now, $site['timezone']);
            if ($now < $period['dueAt'] || $r['lastPeriod'] === $period['key']) {
                continue;
            }
            if (!$this->store->claimReport($r['id'], $period['key'], $now)) {
                continue;
            }
            try {
                $this->deliverReport($r, $site, $period);
                $result['sent']++;
            } catch (\Throwable $error) {
                $this->store->releaseReport($r['id'], $period['key'], $r['lastPeriod']);
                error_log("Runlight: could not send the {$r['frequency']} report for {$site['name']} to {$r['email']}: " . $error->getMessage());
                $result['failed']++;
            }
        }
        return $result;
    }

    /** Builds and sends one report. Also used by "Send a sample now". */
    public function deliverReport(array $r, array $site, ?array $period = null): void
    {
        $period ??= Reports::lastPeriod($r['frequency'], $this->now(), $site['timezone']);
        $unsubscribe = "{$r['origin']}/unsubscribe/{$r['token']}";
        $report = Reports::buildReport($this, $site, $r['frequency'], $period, $r['lang'], [
            'dashboard' => "{$r['origin']}/?site=" . Js::encodeURIComponent($site['id']),
            'unsubscribe' => $unsubscribe,
        ]);
        $this->sendMail([
            'to' => $r['email'],
            'subject' => $report['subject'],
            'html' => $report['html'],
            'text' => $report['text'],
            'headers' => ['List-Unsubscribe' => "<$unsubscribe>", 'List-Unsubscribe-Post' => 'List-Unsubscribe=One-Click'],
        ]);
    }

    /** Creates tables and records the configured sites. Runs once. */
    public function init(): void
    {
        if ($this->ready) {
            return;
        }
        $this->store->migrate();
        // A database that never had its statistics gathered gets them now, before any report is read, rather
        // than at the first scheduled check, which an app may never run.
        $this->store->optimize(true);
        if ($this->managedSites) {
            $this->configured = $this->store->sites();
            $this->loadRemotes();
        }
        foreach ($this->configured as $site) {
            $this->store->upsertSite($site, $this->now());
        }
        $this->overrides = $this->store->siteOverrides();
        // A process starting with a timezone set in code is the newest word on it: if the code changed it,
        // the days built in the old one are cleared here, once, and never by a process still running.
        foreach ($this->sites() as $site) {
            if (isset($this->remotes[$site['id']])) {
                continue;
            }
            $stored = $this->store->setting("rollup-zone:{$site['id']}");
            $zone = $stored !== null && $stored !== '' ? Json::decode($stored, true)['zone'] : null;
            if ($zone === null) {
                $this->store->setSetting("rollup-zone:{$site['id']}", Json::encode(['zone' => $site['timezone'], 'since' => 0]));
            } elseif ($zone !== $site['timezone']) {
                $this->zoneChanged($site['id'], $site['timezone']);
            }
        }
        $this->ready = true;
    }

    /** The dashboard and API. Routes is the port of routes.ts. */
    public function routes(array $options = []): Routes
    {
        return new Routes($this, $options);
    }

    /**
     * The sites, with any settings changed in the dashboard applied.
     *
     * @return list<array{id: string, name: string, hostnames: list<string>, timezone: string}>
     */
    public function sites(): array
    {
        return array_map(fn (array $site): array => array_merge($site, $this->overrides[$site['id']] ?? []), $this->configured);
    }

    /** `$runlight->sites`, as TS reads its getter. */
    public function __get(string $name): mixed
    {
        if ($name === 'sites') {
            return $this->sites();
        }
        throw new \Error('Undefined property: ' . self::class . "::\$$name");
    }

    /**
     * Checks a list of hostnames for a managed site: at least one, each a domain, none taken.
     *
     * @return list<string>
     */
    private function hostnamesFor(mixed $input, ?string $except = null): array
    {
        $items = is_array($input) ? array_values($input) : preg_split('/[' . Js::SPACE . ',]+/u', Js::string($input ?? ''));
        $hostnames = [];
        foreach ($items as $h) {
            $host = Js::trim(Js::string($h));
            $host = (string) preg_replace('#^https?://#', '', $host);
            $host = (string) preg_replace('#[/:][^\n\r\x{2028}\x{2029}]*$#uD', '', $host);
            $host = Sources::stripWww($host);
            if ($host !== '' && !in_array($host, $hostnames, true)) {
                $hostnames[] = $host;
            }
        }
        if ($hostnames === []) {
            throw new SettingsError("Add the site's domain, like example.com", 'site_domain_needed');
        }
        foreach ($hostnames as $host) {
            if (!preg_match('/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/D', $host) && $host !== 'localhost') {
                throw new SettingsError("\"$host\" is not a domain name", 'site_domain_invalid', ['host' => $host]);
            }
            foreach ($this->configured as $site) {
                if ($site['id'] !== $except && in_array($host, $site['hostnames'], true)) {
                    throw new SettingsError("$host already belongs to {$site['name']}", 'site_domain_taken', ['host' => $host, 'site' => $site['name']]);
                }
            }
        }
        return $hostnames;
    }

    private function loadRemotes(): void
    {
        $this->remotes = [];
        foreach ($this->store->settingsStartingWith('remote:') as ['key' => $key, 'value' => $value]) {
            $opened = Secret::unseal($value, $this->secret);
            if ($opened !== null && $opened !== '') {
                $this->remotes[substr($key, strlen('remote:'))] = Json::decode($opened, true);
            }
        }
    }

    /**
     * The install a site is read from, when it is counted elsewhere.
     *
     * @return array{url: string, token: string, site: string, hostnames: list<string>, scope?: string}|null
     */
    public function remote(string $id): ?array
    {
        return $this->remotes[$id] ?? null;
    }

    /** When a connected install's site last had a visit, asked at most once a minute. */
    public function remoteLastSeen(string $id): int|float|null
    {
        return $this->remoteInfo($id)['lastSeen'] ?? null;
    }

    /**
     * What a connected install says about its site: its last visit and how long it keeps visits, asked
     * at most once a minute. Retention is Undefined while the install cannot be reached, and `connection`
     * says whether it answered ("ok"), refused this server's token ("refused"), or could not be reached
     * ("unreachable").
     *
     * @return array{lastSeen: int|float|null, retentionMonths: int|float|null|Undefined, connection: string}|null
     */
    public function remoteInfo(string $id): ?array
    {
        $remote = $this->remotes[$id] ?? null;
        if ($remote === null) {
            return null;
        }
        $cached = $this->remoteSeen[$id] ?? null;
        if ($cached !== null && $this->now() - $cached['at'] < 60_000) {
            unset($cached['at']);
            return $cached;
        }
        $info = ['lastSeen' => $cached['lastSeen'] ?? null, 'retentionMonths' => Undefined::value(), 'connection' => 'unreachable'];
        try {
            $answer = $this->fetcher->fetch("{$remote['url']}/api/sites", ['headers' => ['authorization' => "Bearer {$remote['token']}"], 'timeoutMs' => 8000, 'maxBytes' => self::REMOTE_MAX_BYTES]);
            if ($answer->status === 401 || $answer->status === 403) {
                $info['connection'] = 'refused';
            }
            $body = self::jsonOrNull($answer);
            foreach (is_array($body['sites'] ?? null) ? $body['sites'] : [] as $s) {
                if (!is_array($s)) {
                    // TS reads `s.id` of each and stops at a null, as a throw would.
                    if ($s === null) {
                        break;
                    }
                    continue;
                }
                if (($s['id'] ?? null) === $remote['site']) {
                    $info = ['lastSeen' => $s['lastSeen'] ?? null, 'retentionMonths' => $s['retentionMonths'] ?? null, 'connection' => 'ok'];
                    break;
                }
            }
        } catch (\Throwable) {
        }
        $this->remoteSeen[$id] = ['at' => $this->now(), ...$info];
        return $info;
    }

    /** Forgets what a connected install said, after a change made through it. */
    public function forgetRemoteInfo(string $id): void
    {
        unset($this->remoteSeen[$id]);
    }

    /** A capped JSON body as arrays, or null where TS's readJsonCapped(...).catch(() => null) gives null. */
    private static function jsonOrNull(Response $answer): mixed
    {
        try {
            return Body::readJsonCapped($answer, self::REMOTE_MAX_BYTES, true);
        } catch (\Throwable) {
            return null;
        }
    }

    /** Asks a connected install to delete the token this server holds for it. A failure leaves it listed there. */
    private function revokeRemoteToken(array $remote): void
    {
        try {
            $this->fetcher->fetch("{$remote['url']}/api/token", ['method' => 'DELETE', 'headers' => ['authorization' => "Bearer {$remote['token']}"], 'timeoutMs' => 5_000]);
        } catch (\Throwable) {
        }
    }

    /**
     * Connects a site counted by another Runlight (an app's own install) so this
     * server shows it too. Takes the install's address, as its dashboard is
     * (https://example.com/runlight), and an API token made there.
     */
    private function addRemoteSite(array $input): array
    {
        $url = (string) preg_replace('#/+$#', '', Js::trim(Js::string($input['url'] ?? '')));
        if (!preg_match('#^https://[^/]+|^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)#D', $url)) {
            throw new SettingsError("Enter the install's address, like https://example.com/runlight", 'connect_url');
        }
        $token = Js::trim(Js::string($input['token'] ?? ''));
        if ($token === '') {
            throw new SettingsError('Enter an API token from that install', 'install_token');
        }
        $body = null;
        try {
            $answer = $this->fetcher->fetch("$url/api/sites", ['headers' => ['authorization' => "Bearer $token"], 'timeoutMs' => 10_000, 'maxBytes' => self::REMOTE_MAX_BYTES]);
        } catch (BodyTooLong) {
            // An answer too long to read is no Runlight's.
            throw new SettingsError("$url did not answer like a Runlight install", 'connect_not_runlight', ['url' => $url]);
        } catch (\Throwable) {
            throw new SettingsError("Could not reach $url", 'unreachable', ['host' => (new Url($url))->host()]);
        }
        if ($answer->status === 401 || $answer->status === 403) {
            throw new SettingsError('That install refused the token', 'install_refused');
        }
        $body = self::jsonOrNull($answer);
        $sites = is_array($body) && is_array($body['sites'] ?? null) && array_is_list($body['sites']) ? $body['sites'] : [];
        if (!$answer->ok() || $sites === []) {
            throw new SettingsError("$url did not answer like a Runlight install", 'connect_not_runlight', ['url' => $url]);
        }
        // What the token may do there; an install from before manage tokens has no /api/token and reads only.
        $scope = 'read';
        $tokenSite = '';
        try {
            $about = $this->fetcher->fetch("$url/api/token", ['headers' => ['authorization' => "Bearer $token"], 'timeoutMs' => 10_000, 'maxBytes' => self::REMOTE_MAX_BYTES]);
            $info = $about->ok() ? self::jsonOrNull($about) : null;
            if (is_array($info) && ($info['scope'] ?? null) === 'manage') {
                $scope = 'manage';
            }
            $tokenSite = Js::string(is_array($info) ? ($info['site'] ?? '') : '');
        } catch (\Throwable) {
        }
        $want = $tokenSite !== '' ? $tokenSite : (array_key_exists('site', $input) ? $input['site'] : Undefined::value());
        $there = null;
        foreach ($sites as $s) {
            if (is_array($s) && (array_key_exists('id', $s) ? $s['id'] : Undefined::value()) === $want) {
                $there = $s;
                break;
            }
        }
        $there ??= $sites[0];
        $thereHostnames = is_array($there['hostnames'] ?? null) ? array_values($there['hostnames']) : [];
        // Connecting the same site again (to allow changes, or with a new token) updates it in place.
        foreach ($this->remotes as $existing => $known) {
            if ($known['url'] === $url && $known['site'] === ($there['id'] ?? null)) {
                $updated = array_merge($known, ['token' => $token, 'scope' => $scope, 'hostnames' => $thereHostnames]);
                if ($known['token'] !== $token) {
                    $this->revokeRemoteToken($known);
                }
                $this->store->setSetting("remote:$existing", Secret::seal(Json::encode($updated), $this->secret));
                $this->remotes[(string) $existing] = $updated;
                unset($this->remoteSeen[$existing]);
                return $this->site((string) $existing);
            }
        }
        $host = Js::lower((string) preg_replace('/[^a-z0-9._-]/iu', '-', (string) ($thereHostnames[0] ?? (new Url($url))->host())));
        $id = Js::slice($host, 0, 56);
        for ($n = 2; $this->hasSite($id); $n++) {
            $id = Js::slice($host, 0, 56) . "-$n";
        }
        $name = Js::slice(Js::trim(Js::string($input['name'] ?? '')), 0, 80);
        $name = $name !== '' ? $name : Js::string($there['name'] ?? Undefined::value());
        // No hostnames: tracker hits never land on a site that is counted elsewhere.
        $timezone = $there['timezone'] ?? null;
        $site = ['id' => $id, 'name' => $name, 'hostnames' => [], 'timezone' => is_string($timezone) && Time::isTimezone($timezone) ? $timezone : 'UTC'];
        $remote = ['url' => $url, 'token' => $token, 'site' => $there['id'] ?? null, 'hostnames' => $thereHostnames, 'scope' => $scope];
        $this->store->upsertSite($site, $this->now());
        $this->store->setSetting("remote:$id", Secret::seal(Json::encode($remote), $this->secret));
        $this->remotes[$id] = $remote;
        $this->configured = self::byName([...$this->configured, $site]);
        return $site;
    }

    private function hasSite(string $id): bool
    {
        foreach ($this->configured as $site) {
            if ($site['id'] === $id) {
                return true;
            }
        }
        return false;
    }

    /**
     * Sites in name order, as TS sorts them with localeCompare.
     *
     * @param list<array> $sites
     * @return list<array>
     */
    private static function byName(array $sites): array
    {
        static $collator = false;
        if ($collator === false) {
            $collator = class_exists(\Collator::class) ? new \Collator('en') : null;
        }
        usort($sites, static function (array $a, array $b) use ($collator): int {
            if ($collator !== null) {
                return (int) $collator->compare($a['name'], $b['name']);
            }
            // Without ext-intl, letters before case, as a collator puts them.
            return strcmp(Js::lower($a['name']), Js::lower($b['name'])) ?: Js::compare($b['name'], $a['name']);
        });
        return $sites;
    }

    /**
     * Adds a site, when sites are managed in the dashboard: one counted here, or one connected from another install.
     *
     * @param array{name?: mixed, hostnames?: mixed, timezone?: mixed, remote?: mixed} $input
     */
    public function addSite(array $input): array
    {
        $this->init();
        if (!$this->managedSites) {
            throw new SettingsError('Sites are set in code', 'sites_in_code');
        }
        $remote = $input['remote'] ?? null;
        if ($remote instanceof \stdClass) {
            $remote = (array) $remote;
        }
        if (is_array($remote)) {
            unset($remote['name']);
            if (array_key_exists('name', $input)) {
                $remote['name'] = $input['name'];
            }
            return $this->addRemoteSite($remote);
        }
        $hostnames = $this->hostnamesFor($input['hostnames'] ?? null);
        $name = Js::trim(Js::string($input['name'] ?? ''));
        $name = $name !== '' ? $name : $hostnames[0];
        if (Js::length($name) > 80) {
            throw new SettingsError('A site name is 1 to 80 characters', 'site_name');
        }
        $timezone = Js::string($input['timezone'] ?? 'UTC');
        if (!Time::isTimezone($timezone)) {
            throw new SettingsError("Unknown timezone \"$timezone\"", 'unknown_timezone', ['timezone' => $timezone]);
        }
        $stem = substr((string) preg_replace('/[^a-z0-9._-]/', '-', $hostnames[0]), 0, 56);
        $id = $stem;
        for ($n = 2; $this->hasSite($id); $n++) {
            $id = "$stem-$n";
        }
        $site = ['id' => $id, 'name' => $name, 'hostnames' => $hostnames, 'timezone' => $timezone];
        $this->store->upsertSite($site, $this->now());
        $this->configured = self::byName([...$this->configured, $site]);
        return $site;
    }

    /** Deletes a site and everything recorded for it, when sites are managed in the dashboard. */
    public function deleteSite(string $id): void
    {
        $this->init();
        if (!$this->managedSites) {
            throw new SettingsError('Sites are set in code', 'sites_in_code');
        }
        if (!$this->hasSite($id)) {
            throw new SettingsError('Unknown site', 'unknown_site');
        }
        $this->store->deleteSite($id);
        $this->store->setSetting("retention:$id", null);
        $this->store->setSetting("observe-key:$id", null);
        $this->store->setSetting("rollup-zone:$id", null);
        $this->store->setSetting("orphans-swept:$id", null);
        // A site made again with the same id starts its Umami import from the beginning.
        foreach ($this->store->settingsStartingWith("import:umami-visits:$id:") as ['key' => $key]) {
            $this->store->setSetting($key, null);
        }
        // A connected install keeps its own data; only the connection goes, and its token there with it.
        $remote = $this->remotes[$id] ?? null;
        if ($remote !== null) {
            $this->revokeRemoteToken($remote);
            unset($this->remotes[$id]);
            $this->store->setSetting("remote:$id", null);
        }
        $this->configured = array_values(array_filter($this->configured, static fn (array $site): bool => $site['id'] !== $id));
        unset($this->overrides[$id]);
    }

    /**
     * Changes a site's name or timezone from the dashboard. Stored apart from
     * the settings in code, which keep being written on every start. A managed
     * site has no settings in code, so its changes, hostnames too, go to its row.
     * A key left out of `$patch` is left alone, as TS's undefined is.
     *
     * @param array{name?: mixed, timezone?: mixed, hostnames?: mixed} $patch
     */
    public function updateSite(string $id, array $patch): array
    {
        $this->init();
        $current = null;
        foreach ($this->configured as $site) {
            if ($site['id'] === $id) {
                $current = $site;
            }
        }
        if ($current === null) {
            throw new SettingsError('Unknown site', 'unknown_site');
        }
        $next = $this->managedSites ? $current : ($this->overrides[$id] ?? []);
        if (array_key_exists('name', $patch)) {
            $name = Js::trim(Js::string($patch['name']));
            if ($name === '' || Js::length($name) > 80) {
                throw new SettingsError('A site name is 1 to 80 characters', 'site_name');
            }
            $next['name'] = $name;
        }
        if (array_key_exists('timezone', $patch)) {
            $timezone = Js::string($patch['timezone']);
            if (!Time::isTimezone($timezone)) {
                throw new SettingsError("Unknown timezone \"$timezone\"", 'unknown_timezone', ['timezone' => $timezone]);
            }
            $next['timezone'] = $timezone;
            if ($timezone !== ($this->site($id)['timezone'] ?? null)) {
                $this->zoneChanged($id, $timezone);
            }
        }
        if ($this->managedSites) {
            if (array_key_exists('hostnames', $patch) && !isset($this->remotes[$id])) {
                $next['hostnames'] = $this->hostnamesFor($patch['hostnames'], $id);
            }
            $this->store->upsertSite($next, $this->now());
            $this->configured = array_map(static fn (array $site): array => $site['id'] === $id ? $next : $site, $this->configured);
            return $this->site($id);
        }
        $this->store->setSiteOverrides($id, $next);
        $this->overrides[$id] = $next;
        return $this->site($id);
    }

    /** How many months of visits a site keeps, or null to keep everything (the default). */
    public function retention(string $site): ?int
    {
        $value = Js::number($this->store->setting("retention:$site"));
        return in_array($value, self::RETENTION_MONTHS, true) ? $value : null;
    }

    /**
     * Sets how many months of visits a site keeps. Deleting a long history takes a while, so it runs in
     * pieces in idle(), after the answer, with tracking going on between them, as TS runs it after answering.
     */
    public function setRetention(string $site, int|float|null $months): void
    {
        if ($this->site($site) === null || isset($this->remotes[$site])) {
            throw new SettingsError('Unknown site', 'unknown_site');
        }
        if ($months !== null && !in_array($months, self::RETENTION_MONTHS, false)) {
            $list = implode(', ', self::RETENTION_MONTHS);
            throw new SettingsError("Keep visits for $list months, or forever", 'retention_bad', ['months' => $list]);
        }
        $this->store->setSetting("retention:$site", $months === null ? null : Json::number($months));
        $this->pruning[] = $site;
    }

    /** Runs the work still waiting from earlier calls (a retention change's deletions); the scheduled check and tests wait for it. */
    public function idle(): void
    {
        while ($this->pruning !== []) {
            $only = array_shift($this->pruning);
            try {
                $this->applyRetention($only);
            } catch (\Throwable $error) {
                error_log('Runlight: could not apply retention ' . $error->getMessage());
            }
        }
    }

    /**
     * Days are the site's local days, so a new timezone clears the built ones. Visitor ids recorded before
     * the change were made per day of the old timezone, and could count one person twice in a new day, so
     * only days that start after the change are built; earlier ones are always counted visit by visit.
     */
    private function zoneChanged(string $id, string $timezone): int
    {
        $since = $this->now();
        $this->store->clearRollups($id);
        $this->store->setSetting("rollup-zone:$id", Json::encode(['zone' => $timezone, 'since' => $since]));
        return $since;
    }

    /**
     * Since when a site's days may be built: 0 for always, or when its timezone last changed. Null when
     * this process holds a different timezone than the one on record, such as an older copy still running
     * during a deploy, or one that has not yet seen a change made in the dashboard. It builds nothing for
     * that site, and reports read the visits themselves for any day not built, so nothing is wrong meanwhile.
     */
    private function rollupSince(array $site): int|float|null
    {
        $stored = $this->store->setting("rollup-zone:{$site['id']}");
        if ($stored === null || $stored === '') {
            $this->store->setSetting("rollup-zone:{$site['id']}", Json::encode(['zone' => $site['timezone'], 'since' => 0]));
            return 0;
        }
        $zone = Json::decode($stored, true);
        return $zone['zone'] === $site['timezone'] ? $zone['since'] : null;
    }

    /**
     * Adds up each site's finished days, so long ranges read a row a day instead
     * of every visit. A day is built two hours after it ends in the site's
     * timezone, once late engagement has landed, and at most ROLLUP_BATCH days
     * a run, so a long history fills in over a few runs. Reports read the raw
     * visits for any day not built yet, so the numbers are the same either way.
     * Only a visit still going two hours past midnight, with no 30 minute gap,
     * could add to a day after it is built.
     */
    public function buildRollups(): int
    {
        // Days rolled up by an earlier way of counting are cleared once, and built again below.
        if ($this->store->setting('rollup-version') !== (string) self::ROLLUP_VERSION) {
            foreach ($this->sites() as $site) {
                $this->store->clearRollups($site['id']);
            }
            $this->store->setSetting('rollup-version', (string) self::ROLLUP_VERSION);
        }
        $built = 0;
        $now = $this->now();
        $db = $this->store->db;
        $batch = method_exists($db, 'metered') && $db->metered() ? self::METERED_ROLLUP_BATCH : self::ROLLUP_BATCH;
        foreach ($this->sites() as $site) {
            if (isset($this->remotes[$site['id']])) {
                continue;
            }
            $first = $this->store->firstSeen($site['id']);
            if ($first === null) {
                continue;
            }
            $cutoff = $this->retentionCutoff($site['id']) ?? 0;
            $since = $this->rollupSince($site);
            if ($since === null) {
                continue;
            }
            $done = array_flip($this->store->rollupDays($site['id']));
            $today = Time::localDate($now, $site['timezone']);
            $oldest = Time::localDate((int) max($first, $cutoff), $site['timezone']);
            $made = 0;
            // Newest first, so recent ranges speed up before a long history is done.
            for ($day = Time::addDays($today, -1); $day >= $oldest && $made < $batch; $day = Time::addDays($day, -1)) {
                if (isset($done[$day])) {
                    continue;
                }
                $start = Time::startOf($day, $site['timezone']);
                $end = Time::startOf(Time::addDays($day, 1), $site['timezone']);
                if ($start < $since) {
                    break;
                }
                if ($now < $end + self::ROLLUP_DELAY_MS || $start < $cutoff) {
                    continue;
                }
                try {
                    $this->store->buildRollupDay($site['id'], $day, $start, $end);
                    $made++;
                } catch (\Throwable $error) {
                    // Another process building the same day at once loses nothing: the day is there either way.
                    if (!in_array($day, $this->store->rollupDays($site['id']), true)) {
                        error_log("Runlight: could not add up $day for {$site['id']} " . $error->getMessage());
                    }
                }
            }
            $built += $made;
        }
        return $built;
    }

    /** The dashboard assistant's provider, model, and key, kept sealed like the mail keys. Null until an owner sets it up. */
    public function assistantSettings(): ?array
    {
        $stored = $this->store->setting('assistant');
        $opened = $stored !== null && $stored !== '' ? Secret::unseal($stored, $this->secret) : null;
        return $opened !== null && $opened !== '' ? Json::decode($opened, true) : null;
    }

    /**
     * Saves the assistant's settings; an empty key keeps the one saved for the same provider. Null removes them.
     *
     * @param array<string, mixed>|null $input
     */
    public function saveAssistantSettings(?array $input): void
    {
        if (!$input) {
            $this->store->setSetting('assistant', null);
            return;
        }
        $provider = null;
        foreach (Assistant::PROVIDERS as $p) {
            if ($p['id'] === ($input['provider'] ?? null)) {
                $provider = $p;
                break;
            }
        }
        if ($provider === null) {
            throw new SettingsError('Choose a provider', 'assistant_provider');
        }
        $baseUrl = (string) preg_replace('#/+$#', '', Js::trim(Js::string($input['baseUrl'] ?? '')));
        if ($baseUrl !== '') {
            $parsed = Url::parse($baseUrl);
            if ($parsed === null || ($parsed->protocol !== 'https:' && $parsed->protocol !== 'http:')) {
                throw new SettingsError("Enter the service's address, starting with https://", 'assistant_address_bad');
            }
        }
        if ($baseUrl === '' && $provider['baseUrl'] === '') {
            throw new SettingsError("Enter the service's address", 'assistant_address');
        }
        $model = Js::slice(Js::trim(Js::string($input['model'] ?? '')), 0, 200);
        if ($model === '' && $provider['model'] === '') {
            throw new SettingsError('Enter the model to use', 'assistant_model');
        }
        $before = $this->assistantSettings();
        $key = Js::trim(Js::string($input['key'] ?? ''));
        // A saved key is kept only for the same service at the same address, so it is never sent somewhere new.
        $beforeBase = (string) ($before['baseUrl'] ?? '');
        if ($key === '' && ($before['provider'] ?? null) === $provider['id'] && ($beforeBase !== '' ? $beforeBase : $provider['baseUrl']) === ($baseUrl !== '' ? $baseUrl : $provider['baseUrl'])) {
            $key = (string) ($before['key'] ?? '');
        }
        if ($key === '' && $provider['key'] === 'yes') {
            throw new SettingsError("Enter your {$provider['name']} key", 'assistant_key', ['provider' => $provider['name']]);
        }
        $settings = ['provider' => $provider['id'], 'model' => $model, 'baseUrl' => $baseUrl, 'key' => $key];
        $this->store->setSetting('assistant', Secret::seal(Json::encode($settings), $this->secret));
    }

    /** The oldest moment a site keeps visits from, or null when it keeps everything. */
    public function retentionCutoff(string $site): ?int
    {
        $months = $this->retention($site);
        if ($months === null) {
            return null;
        }
        // setUTCMonth: the same day and time that many months back, a day past the month's end running on.
        $now = $this->now();
        $ms = (($now % 1000) + 1000) % 1000;
        $at = (new \DateTimeImmutable('@' . intdiv($now - $ms, 1000)))->setTimezone(new \DateTimeZone('UTC'));
        $back = $at->setDate((int) $at->format('Y'), (int) $at->format('n') - $months, (int) $at->format('j'));
        return (int) $back->format('U') * 1000 + $ms;
    }

    /** Deletes visits older than each site's retention allows. Cheap when there is nothing to delete. */
    private function applyRetention(?string $only = null): void
    {
        foreach ($this->sites() as $site) {
            if (($only !== null && $only !== '' && $site['id'] !== $only) || isset($this->remotes[$site['id']])) {
                continue;
            }
            $cutoff = $this->retentionCutoff($site['id']);
            if ($cutoff === null) {
                continue;
            }
            $this->store->dropBefore($site['id'], $cutoff);
            // Earlier versions let an event join its visit days late, so retention could leave such an event behind
            // once its visit was gone. They are swept once; events can no longer join a visit that late.
            if (!Js::truthy($this->store->setting("orphans-swept:{$site['id']}"))) {
                $this->store->dropOrphans($site['id'], $cutoff, $this->now());
                $this->store->setSetting("orphans-swept:{$site['id']}", '1');
            }
        }
    }

    public function site(?string $id): ?array
    {
        $sites = $this->sites();
        if ($id === null || $id === '') {
            return $sites[0] ?? null;
        }
        foreach ($sites as $site) {
            if ($site['id'] === $id) {
                return $site;
            }
        }
        return null;
    }

    /** The site a page belongs to, or null if it belongs to none. */
    public function siteFor(string $hostname, ?string $id = null): ?array
    {
        $host = Sources::stripWww($hostname);
        // A site counted by another install never takes hits here.
        if ($this->remotes !== []) {
            $local = array_values(array_filter($this->sites(), fn (array $site): bool => !isset($this->remotes[$site['id']])));
            if ($id !== null && $id !== '') {
                return isset($this->remotes[$id]) ? null : self::siteForAmong($local, $host, $id);
            }
            return self::siteForAmong($local, $host);
        }
        return self::siteForAmong($this->sites(), $host, $id);
    }

    private static function siteForAmong(array $sites, string $host, ?string $id = null): ?array
    {
        if ($id !== null && $id !== '') {
            foreach ($sites as $site) {
                if ($site['id'] === $id) {
                    return $site['hostnames'] === [] || in_array($host, $site['hostnames'], true) ? $site : null;
                }
            }
            return null;
        }
        if (count($sites) === 1) {
            $only = $sites[0];
            return $only['hostnames'] === [] || in_array($host, $only['hostnames'], true) ? $only : null;
        }
        foreach ($sites as $site) {
            if (in_array($host, $site['hostnames'], true)) {
                return $site;
            }
        }
        return null;
    }

    /**
     * A test from a developer's own machine while a site is being set up. A site
     * with no visits yet accepts hits from localhost and .local or .test names,
     * so the install screen confirms it works; after its first visit they are
     * ignored again, so local browsing never mixes with real traffic.
     */
    private function setupSite(string $hostname, ?string $id = null): ?array
    {
        $host = (string) preg_replace('/^\[|\]$/D', '', Js::lower($hostname));
        if (!($host === 'localhost' || $host === '127.0.0.1' || $host === '::1' || preg_match('/\.(localhost|local|test)$/D', $host))) {
            return null;
        }
        $sites = $this->sites();
        $site = $id !== null && $id !== '' ? $this->site($id) : (count($sites) === 1 ? $sites[0] : null);
        if ($site === null || isset($this->remotes[$site['id']])) {
            return null;
        }
        return $this->store->lastSeen($site['id']) === null ? $site : null;
    }

    /**
     * The visitor's address, for the daily visitor hash and the rate limit. Behind a proxy it comes
     * from a header. By default that is the last X-Forwarded-For entry, which the nearest proxy wrote
     * and a client cannot choose (Vercel, Netlify, Cloudflare, Caddy, and nginx all append there),
     * then X-Real-IP and CF-Connecting-IP. Naming one header (after another proxy in front, such as
     * Cloudflare before nginx) reads only that one. Otherwise it is the connection's address: the
     * context's `ip`, or else the request's own remoteAddress.
     *
     * @param array{ip?: string} $context
     */
    public function clientIp(Request $request, array $context = []): string
    {
        if ($this->trustProxy !== false) {
            $h = $request->headers;
            $last = static function (string $name) use ($h): ?string {
                $value = $h->get($name);
                if ($value === null) {
                    return null;
                }
                $parts = array_values(array_filter(array_map(Js::trim(...), explode(',', $value)), static fn (string $x): bool => $x !== ''));
                return $parts === [] ? null : $parts[count($parts) - 1];
            };
            $forwarded = $this->trustProxy === true
                ? ($last('x-forwarded-for') ?? $h->get('x-real-ip') ?? $h->get('cf-connecting-ip'))
                : ($this->trustProxy === 'x-forwarded-for' ? $last('x-forwarded-for') : $h->get((string) $this->trustProxy));
            if ($forwarded !== null && Js::trim($forwarded) !== '') {
                return Js::trim($forwarded);
            }
        }
        return (string) ($context['ip'] ?? $request->remoteAddress);
    }

    /**
     * Today's salt in a site's timezone and, if it still exists, yesterday's.
     * Salts follow the site's own days, as its reports do, so a visitor is one
     * visitor for the whole of that site's day. Old salts go on the way.
     *
     * @return array{day: string, today: string, yesterday: ?string}
     */
    private function currentSalts(int $now, string $timezone): array
    {
        $day = Time::localDate($now, $timezone);
        $cached = $this->salts[$timezone] ?? null;
        if ($cached !== null && $cached['day'] === $day) {
            return $cached;
        }
        $today = $this->store->salt($day, Hash::randomSalt());
        $yesterday = $this->store->saltIfExists(Time::addDays($day, -1));
        $this->dropOldSalts($now);
        return $this->salts[$timezone] = ['day' => $day, 'today' => $today, 'yesterday' => $yesterday];
    }

    /**
     * Deletes salts whose day has ended everywhere. The earliest timezone is a
     * day behind UTC and still needs its yesterday, so a salt goes two UTC days
     * after its date.
     */
    private function dropOldSalts(int $now): void
    {
        $this->store->dropSaltsBefore(gmdate('Y-m-d', intdiv($now - 2 * 86_400_000, 1000)));
    }

    /**
     * Handles one tracker request. Bad input is dropped quietly; only a database that keeps failing throws.
     *
     * @param array{ip?: string} $context
     */
    public function collect(Request $request, array $context = []): void
    {
        $length = Js::number($request->headers->get('content-length') ?? 0);
        if ($length > Payload::MAX_BODY) {
            return;
        }
        // Read no more than a tracker hit can be, whatever the length header says (or when there is none).
        $bytes = $request->text();
        if (strlen($bytes) > Payload::MAX_BODY) {
            return;
        }
        $payload = Payload::parsePayload(Body::utf8($bytes));
        if ($payload === null) {
            return;
        }

        $ua = $request->headers->get('user-agent') ?? '';
        if (Ua::aiAgent($ua) !== null || Ua::isBot($ua)) {
            return;
        }
        if ($this->limit !== null && !$this->limit->allow($this->clientIp($request, $context))) {
            return;
        }

        // A database too busy to take the hit right now (every pooled connection held by long reports, or
        // another process writing the SQLite file) gets it a little later, at the time it arrived.
        $now = $this->now();
        for ($attempt = 1; ; $attempt++) {
            try {
                $this->record($payload, $request, $context, $now);
                return;
            } catch (\Throwable $error) {
                if ($attempt >= 3 || !self::busy($error)) {
                    throw $error;
                }
                usleep(500_000 * $attempt);
            }
        }
    }

    private function record(array $payload, Request $request, array $context, int $now): void
    {
        // Managed sites load from the database in init(), so it must come first.
        $this->init();
        $url = $payload['url'];
        $site = $this->siteFor($url->hostname, $payload['site']) ?? $this->setupSite($url->hostname, $payload['site']);
        if ($site === null) {
            return;
        }

        if ($payload['kind'] === 'engagement') {
            $this->engagement($site, $payload, $now);
            return;
        }

        $page = Sources::parsePage($url);
        $session = null;
        $reopen = true;
        if ($payload['kind'] === 'event' && $payload['pageviewId'] !== '') {
            $pageview = $this->store->pageview($site['id'], $payload['pageviewId']);
            // An event joins its page's visit unless that visit began longer ago than reports look for its rows
            // (a tab left open for days); it then starts a visit of its own, as any later activity would.
            if ($pageview !== null && $now - $pageview['startedAt'] < SqlStore::EVENT_TAIL_MS) {
                $session = ['id' => $pageview['session'], 'visitor' => $pageview['visitor']];
                // A visit idle past the 30 minutes stays ended: the event counts in it without reopening it.
                $reopen = $now - $pageview['lastAt'] <= self::SESSION_IDLE_MS;
                if ($now - $pageview['startedAt'] > 3_600_000) {
                    $this->store->touchedOldVisit($site['id'], (int) $pageview['startedAt'], $now - self::ROLLUP_DELAY_MS + 3_600_000);
                }
            }
        }
        $session ??= $this->sessionFor($site, $request, $context, $page, $payload['referrer'], $now, [
            'screenWidth' => $payload['screenWidth'],
            'screen' => Js::truthy($payload['screenWidth']) && Js::truthy($payload['screenHeight']) ? "{$payload['screenWidth']}x{$payload['screenHeight']}" : '',
            'language' => $payload['language'],
        ]);

        $this->store->touchSession($session['id'], $now, $payload['kind'], $page['path'], $reopen);
        $this->store->insertEvent([
            'site' => $site['id'],
            'ts' => $now,
            'kind' => $payload['kind'],
            'visitor' => $session['visitor'],
            'session' => $session['id'],
            'pageview' => $payload['pageviewId'],
            'path' => $page['path'],
            'hostname' => $page['hostname'],
            'title' => $payload['kind'] === 'pageview' ? $payload['title'] : '',
            'name' => $payload['kind'] === 'event' ? $payload['name'] : '',
            'props' => $payload['props'],
            'engagedMs' => 0,
            'scroll' => null,
            'link' => '',
        ]);
    }

    /**
     * The visitor's open session on a site, or a new one attributed to this
     * request. Shared by tracker hits and short link clicks.
     *
     * TS takes turns per visitor here, so one process's pageview and the event right after it find one
     * session; a PHP process serves one request at a time, so its requests are already in turn.
     *
     * @param array{screenWidth?: ?int, screen: string, language: string} $client
     * @return array{id: string, visitor: string}
     */
    private function sessionFor(array $site, Request $request, array $context, array $page, string $referrer, int $now, array $client): array
    {
        $ua = $request->headers->get('user-agent') ?? '';
        $ip = $this->clientIp($request, $context);
        $salts = $this->currentSalts($now, $site['timezone']);
        $today = Hash::visitorHash($salts['today'], $site['id'], $ip, $ua);
        $candidates = [$today];
        if ($salts['yesterday'] !== null && $salts['yesterday'] !== '') {
            $candidates[] = Hash::visitorHash($salts['yesterday'], $site['id'], $ip, $ua);
        }
        $open = $this->store->openSession($site['id'], $candidates, $now - self::SESSION_IDLE_MS);
        if ($open !== null) {
            return $open;
        }

        $session = ['id' => Hash::randomId(), 'visitor' => $today];
        $attribution = Sources::attribute($page, $referrer, $site['hostnames']);
        $parsed = Ua::parseClient(
            $ua,
            [
                'brands' => $request->headers->get('sec-ch-ua'),
                'mobile' => $request->headers->get('sec-ch-ua-mobile'),
                'platform' => $request->headers->get('sec-ch-ua-platform'),
            ],
            $client['screenWidth'] ?? null,
        );
        $location = Geo::locate($request->headers, $ip, $this->geo);
        $this->store->insertSession([
            'id' => $session['id'],
            'site' => $site['id'],
            'visitor' => $session['visitor'],
            'startedAt' => $now,
            'hostname' => $page['hostname'],
            ...$attribution,
            'utmSource' => $page['utm']['source'],
            'utmMedium' => $page['utm']['medium'],
            'utmCampaign' => $page['utm']['campaign'],
            'utmTerm' => $page['utm']['term'],
            'utmContent' => $page['utm']['content'],
            ...$location,
            ...$parsed,
            'screen' => $client['screen'],
            'language' => $client['language'],
        ]);
        return $session;
    }

    /**
     * The link domains, read at most every 30 seconds. Every request to a
     * standalone server asks, so this saves a query on each tracker hit; a
     * change made here clears it at once, one made by another process within
     * half a minute.
     *
     * @return array<string, true>
     */
    private function linkDomainSet(): array
    {
        $now = $this->now();
        if ($this->linkDomainCache !== null && $now - $this->linkDomainCache['at'] < 30_000) {
            return $this->linkDomainCache['domains'];
        }
        $this->init();
        $domains = [];
        foreach ($this->store->linkDomains() as $d) {
            $domains[$d['domain']] = true;
        }
        $this->linkDomainCache = ['at' => $now, 'domains' => $domains];
        return $domains;
    }

    /** Clears the cached link domains after one is added or removed. */
    public function forgetLinkDomains(): void
    {
        $this->linkDomainCache = null;
    }

    /**
     * Handles `{linkPath}/{slug}` on the app's own domain: in a front controller,
     * `if (str_starts_with($path, '/go/')) ($rl->linkHandler())($request)->emit();`
     *
     * @return \Closure(Request, array=): Response
     */
    public function linkHandler(): \Closure
    {
        return function (Request $request, array $context = []): Response {
            $path = (new Url($request->url))->pathname;
            $slug = str_starts_with($path, "{$this->linkPath}/") ? self::decode(substr($path, strlen($this->linkPath) + 1)) : '';
            $found = $slug !== '' && !str_contains($slug, '/') ? $this->redirect($request, $slug, '', $context) : null;
            return $found ?? self::notFound();
        };
    }

    /**
     * For middleware: when a request arrives on a link domain added in
     * Settings (such as t.example.com), answers `/{slug}` there with the
     * redirect, and anything else with a 404. Null for every other host, so
     * the app carries on as normal, and for the dashboard's own paths, so
     * its owner can always reach it to remove the domain.
     *
     * @param array{ip?: string} $context
     */
    public function linkDomainResponse(Request $request, array $context = []): ?Response
    {
        $url = new Url($request->url);
        // A forwarded host only counts behind a proxy that sets it; otherwise any client could pick one.
        $given = ($this->trustProxy !== false ? $request->headers->get('x-forwarded-host') : null) ?? $request->headers->get('host') ?? $url->host();
        $host = Sources::stripWww(explode(':', Js::trim(explode(',', $given)[0]))[0]);
        if (!isset($this->linkDomainSet()[$host])) {
            return null;
        }
        // Lets the dashboard confirm that requests to this domain reach Runlight.
        if ($url->pathname === self::LINK_DOMAIN_CHECK) {
            return new Response(Json::encode(['runlight' => true, 'domain' => $host]), 200, ['content-type' => 'application/json', 'cache-control' => 'no-store']);
        }
        foreach ($this->routeBases !== [] ? $this->routeBases : ['/runlight'] as $base) {
            if ($base !== '/' && ($url->pathname === $base || str_starts_with($url->pathname, "$base/"))) {
                return null;
            }
        }
        $slug = self::decode(substr($url->pathname, 1));
        $found = $slug !== '' && !str_contains($slug, '/') ? $this->redirect($request, $slug, $host, $context) : null;
        return $found ?? self::notFound();
    }

    private static function notFound(): Response
    {
        return new Response('Not found', 404, ['content-type' => 'text/plain; charset=utf-8']);
    }

    /** decodeURIComponent, throwing where it throws a URIError. */
    private static function decode(string $text): string
    {
        return Js::decodeURIComponent($text) ?? throw new \UnexpectedValueException('URI malformed');
    }

    /**
     * Answers a request for a short link: a redirect to its destination, with
     * the click recorded like a visit (source, place, device, and any campaign
     * tags on the short URL) but kept out of visitor and pageview counts.
     * Bots are redirected and not counted. `domain` is the link domain the
     * request came in on, or "" for the app's own link path, which answers for
     * every link. Null when no link fits.
     *
     * @param array{ip?: string} $context
     */
    public function redirect(Request $request, string $slug, string $domain, array $context = []): ?Response
    {
        $this->init();
        $url = new Url($request->url);
        $host = Sources::stripWww(explode(':', $request->headers->get('x-forwarded-host') ?? $request->headers->get('host') ?? $url->host())[0]);
        $link = $this->store->linkBySlug($slug);
        // The app's own link path answers for every link, so a link whose domain
        // was removed keeps working; a link domain answers only for its own links.
        if ($link === null || ($domain !== '' && $link['domain'] !== $domain)) {
            return null;
        }
        $site = $this->site($link['site']) ?? ($this->sites()[0] ?? null);
        $ua = $request->headers->get('user-agent') ?? '';
        if ($site !== null && Ua::aiAgent($ua) === null && !Ua::isBot($ua) && $request->method === 'GET') {
            try {
                $now = $this->now();
                $first = explode(';', explode(',', $request->headers->get('accept-language') ?? '')[0])[0];
                $language = Js::slice(Js::trim($first), 0, 35);
                $session = $this->sessionFor($site, $request, $context, Sources::parsePage($url), $request->headers->get('referer') ?? '', $now, ['screen' => '', 'language' => $language]);
                $this->store->touchSession($session['id'], $now, 'click', $url->pathname);
                $this->store->insertEvent([
                    'site' => $site['id'],
                    'ts' => $now,
                    'kind' => 'click',
                    'visitor' => $session['visitor'],
                    'session' => $session['id'],
                    'pageview' => '',
                    'path' => Js::slice($url->pathname, 0, 1000),
                    'hostname' => $host,
                    'title' => '',
                    'name' => $link['slug'],
                    'props' => null,
                    'engagedMs' => 0,
                    'scroll' => null,
                    'link' => $link['id'],
                ]);
            } catch (\Throwable $error) {
                // A failed count must never break the redirect.
                error_log('Runlight: could not record a link click ' . $error->getMessage());
            }
        }
        return new Response('', 302, ['location' => $link['url'], 'cache-control' => 'no-store', 'referrer-policy' => 'no-referrer-when-downgrade']);
    }

    private function engagement(array $site, array $payload, int $now): void
    {
        if ($payload['engagedMs'] <= 0) {
            return;
        }
        $pageview = $this->store->pageview($site['id'], $payload['pageviewId']);
        // Reports look for a visit's rows only so long after it began, so later time on it is let go.
        if ($pageview === null || $now - $pageview['startedAt'] >= SqlStore::EVENT_TAIL_MS) {
            return;
        }
        $this->store->addEngagement($pageview['session'], $payload['engagedMs']);
        // Only a visit that began more than an hour ago can belong to a day that is already added up.
        if ($now - $pageview['startedAt'] > 3_600_000) {
            $this->store->touchedOldVisit($site['id'], (int) $pageview['startedAt'], $now - self::ROLLUP_DELAY_MS + 3_600_000);
        }
        $this->store->insertEvent([
            'site' => $site['id'],
            'ts' => $now,
            'kind' => 'engagement',
            'visitor' => $pageview['visitor'],
            'session' => $pageview['session'],
            'pageview' => $payload['pageviewId'],
            'path' => $pageview['path'],
            'hostname' => $pageview['hostname'],
            'title' => '',
            'name' => '',
            'props' => null,
            'engagedMs' => $payload['engagedMs'],
            'scroll' => $payload['scroll'] ?? null,
            'link' => '',
        ]);
    }

    /**
     * Records a request from a known AI agent. Call it from middleware for
     * every page request; it ignores everything else and never throws.
     * Agents do not run JavaScript, so the tracker cannot see them.
     */
    public function observe(Request $request, int|float|null $at = null): bool
    {
        try {
            if ($request->method !== 'GET') {
                return false;
            }
            $agent = Ua::aiAgent($request->headers->get('user-agent') ?? '');
            if ($agent === null) {
                return false;
            }
            $url = new Url($request->url);
            // Pages, not their assets.
            if (preg_match('/\.([a-z0-9]+)$/iD', $url->pathname, $m) && !in_array(strtolower($m[1]), ['html', 'htm', 'md', 'txt', 'php'], true)) {
                return false;
            }
            $host = $request->headers->get('x-forwarded-host') ?? $request->headers->get('host') ?? $url->hostname;
            $this->init();
            $site = $this->siteFor(explode(':', $host)[0]);
            if ($site === null) {
                return false;
            }
            // A log reader sends when the page was served. Older than a week is dropped, so a first run over
            // an old log does not land as one spike on today; a time ahead of now counts as now.
            $now = $this->now();
            $finite = $at !== null && is_finite((float) $at);
            if ($finite && $at < $now - 7 * 86_400_000) {
                return false;
            }
            $ts = $finite && $at <= $now ? (int) floor($at) : $now;
            $this->store->insertEvent([
                'site' => $site['id'],
                'ts' => $ts,
                'kind' => 'fetch',
                'visitor' => '',
                'session' => '',
                'pageview' => '',
                'path' => Js::slice($url->pathname, 0, 1000),
                'hostname' => Sources::stripWww($url->hostname),
                'title' => '',
                'name' => $agent['name'],
                'props' => ['company' => $agent['company'], 'kind' => $agent['kind']],
                'engagedMs' => 0,
                'scroll' => null,
                'link' => '',
            ]);
            return true;
        } catch (\Throwable $error) {
            // Analytics must never break the page it watches, but a failure should still be seen.
            error_log('Runlight: could not record an AI agent fetch ' . $error->getMessage());
            return false;
        }
    }

    /**
     * Scheduled upkeep, safe to run every minute. It rotates salts, sends the email
     * reports that are due, deletes visits past each site's retention, and builds
     * daily rollups. It also rereads sites, their dashboard settings, and connected
     * installs, so a change made by another process sharing the database shows up here too.
     * A check called while one is running (from inside it) does nothing more.
     *
     * @return array{ok: true, reports: array{sent: int, failed: int}}
     */
    public function check(): array
    {
        if ($this->checking) {
            return ['ok' => true, 'reports' => ['sent' => 0, 'failed' => 0]];
        }
        $this->checking = true;
        try {
            return $this->runCheck();
        } finally {
            $this->checking = false;
        }
    }

    /** @return array{ok: true, reports: array{sent: int, failed: int}} */
    private function runCheck(): array
    {
        $this->init();
        if ($this->managedSites) {
            $this->configured = $this->store->sites();
            $this->loadRemotes();
        }
        // A name or timezone changed in the dashboard by another process reaches this one too.
        $this->overrides = $this->store->siteOverrides();
        $this->salts = [];
        foreach (array_unique(array_column($this->sites(), 'timezone')) as $timezone) {
            $this->currentSalts($this->now(), $timezone);
        }
        $this->dropOldSalts($this->now());
        // Every site's retention covers any one site's that is still waiting.
        $this->pruning = [];
        try {
            $this->applyRetention();
        } catch (\Throwable $error) {
            error_log('Runlight: could not apply retention ' . $error->getMessage());
        }
        if ($this->now() - $this->optimizedAt >= 86_400_000) {
            $this->optimizedAt = $this->now();
            $this->store->optimize();
        }
        $this->buildRollups();
        return ['ok' => true, 'reports' => $this->sendReports()];
    }

    /** True for a database that could not take a statement just now and may a moment later. */
    private static function busy(\Throwable $error): bool
    {
        return (bool) preg_match('/timeout exceeded when trying to connect|connection timeout|no MySQL connection was free|SQLITE_BUSY|database is locked/i', $error->getMessage());
    }
}
