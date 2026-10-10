<?php

declare(strict_types=1);

namespace Runlight\Server;

use Runlight\Accounts\Accounts;
use Runlight\Accounts\Crypto;
use Runlight\Accounts\Web;
use Runlight\Hash;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Routes;
use Runlight\Runlight;
use Runlight\Store\SqlStore;

/**
 * The standalone server, for PHP hosting: Runlight's routes at the root of their own domain, behind a sign-in,
 * with sites managed in the dashboard and short links answered on any domain pointed at it. This is the port of
 * packages/server/src/server.ts; Config builds one from the environment or a config.php, and the drop-in
 * standalone/index.php serves it.
 *
 * PHP keeps nothing between requests, so the names the owner and admins signed in from are read from the
 * database on each request that needs them, and the scheduled check runs from cron (`runlight cron`).
 */
final class Standalone
{
    /** The server's own pages, which answer as the server on every name it is reached at, a link domain too. */
    public const SERVER_PATHS = ['/login', '/logout', '/setup', '/invite', '/healthz', '/auth.css', '/auth.js', '/api', '/mcp', '/s.js', '/pick.js', '/e', '/embed'];

    /**
     * The most names remembered as the server's own. The first ones stay and later ones are not learned, so
     * a server reached at more names than this needs RUNLIGHT_URL to keep the rest from becoming link domains.
     */
    public const MAX_OWN_HOSTS = 20;

    public readonly Runlight $runlight;
    public readonly Accounts $accounts;
    public readonly Web $web;
    public readonly Routes $routes;
    private readonly SqlStore $store;
    private readonly ?string $token;
    private readonly bool|string $trustProxy;
    private readonly ?Url $publicUrl;
    private readonly ?string $publicHost;
    /** @var list<string>|null */
    private ?array $ownHosts = null;

    /**
     * @param array{
     *     store: SqlStore,
     *     secret: string,
     *     token?: string|null,
     *     url?: string|null,
     *     trustProxy?: bool|string,
     *     geo?: callable(string): ?array,
     *     geoCredit?: bool,
     *     now?: callable(): int,
     *     fetcher?: \Runlight\Http\Fetcher,
     *     setupCode?: string,
     *     setupWhere?: string,
     *     cronSecret?: string|null,
     *     observeKey?: string|null,
     * } $options
     *
     * - secret: signs sessions and encrypts saved keys. Keep it stable.
     * - token: also accepted as a bearer token on the API, for scripts. When there is no setupCode, the first
     *   account is made with it instead.
     * - url: the dashboard's public address, such as https://stats.example.com. It can never become a link
     *   domain, short links never answer on it, and emails link to it whatever Host header a request carries.
     * - setupCode: the one-time code that unlocks /setup while no account exists; setupWhere says where it is
     *   written down, for the page that asks for it.
     * - cronSecret: a bearer secret for POST /api/check, for a scheduler that calls it over HTTP.
     */
    public function __construct(array $options)
    {
        $this->store = $options['store'];
        $now = $options['now'] ?? static fn (): int => (int) floor(microtime(true) * 1000);
        $this->token = isset($options['token']) && $options['token'] !== '' ? (string) $options['token'] : null;
        $this->trustProxy = $options['trustProxy'] ?? true;
        $this->publicUrl = isset($options['url']) && $options['url'] !== '' ? new Url((string) $options['url']) : null;
        $this->publicHost = $this->publicUrl !== null ? Routes::hostName($this->publicUrl->host()) : null;

        $runlight = [
            'store' => $this->store,
            'managedSites' => true,
            'secret' => $options['secret'],
            'trustProxy' => $this->trustProxy,
            'now' => $now,
        ];
        if (isset($options['geo'])) {
            $runlight['geo'] = $options['geo'];
        }
        if (isset($options['fetcher'])) {
            $runlight['fetcher'] = $options['fetcher'];
        }
        $rl = $this->runlight = new Runlight($runlight);

        // Accounts, shared with apps that turn them on. The first one is made with the one-time code, or with the
        // token when there is no code, and emails link to the public address, or else the first name the owner or
        // an admin signed in from.
        $code = $options['setupCode'] ?? null;
        $web = [
            'runlight' => $rl,
            'secret' => $options['secret'],
            'base' => '',
            'now' => $now,
            'firstAccount' => $code !== null && $code !== '' ? ['code' => $code] : ($this->token !== null ? ['token' => $this->token] : 'locked'),
            'home' => fn (): ?string => $this->publicUrl?->origin() ?? (isset($this->knownHosts()[0]) ? 'https://' . $this->knownHosts()[0] : null),
            'forgot' => 'https://runlight.sh/docs/php/#forgotten-passwords',
        ];
        if (isset($options['setupWhere'])) {
            $web['setupWhere'] = $options['setupWhere'];
        }
        $this->web = new Web($web);
        $this->accounts = $this->web->accounts;

        $routes = [
            'basePath' => '',
            // Without a secret of its own, the cron route is never needed: `runlight cron` runs the check itself.
            'cronSecret' => isset($options['cronSecret']) && $options['cronSecret'] !== '' ? (string) $options['cronSecret'] : Hash::randomId(32),
            'observeKey' => (string) ($options['observeKey'] ?? ''),
            'signOut' => '/logout',
            'signIn' => '/login',
            'geoCredit' => (bool) ($options['geoCredit'] ?? false),
            'accounts' => $this->web,
            'authorize' => function (Request $request): bool|string {
                $auth = $request->headers->get('authorization') ?? '';
                if ($this->token !== null && str_starts_with(strtolower($auth), 'bearer ') && Crypto::sameText(trim(substr($auth, 7)), $this->token)) {
                    return true;
                }
                $access = $this->web->access($request);
                if ($access === true) {
                    $this->learnHost($request);
                }
                return $access;
            },
            'ownHosts' => fn (): array => $this->knownHosts(),
        ];
        if ($this->publicUrl !== null) {
            $routes['origin'] = $this->publicUrl->origin();
        }
        $this->routes = $rl->routes($routes);
    }

    /** The name a request came in on, read as link domains read it. */
    private function hostOf(Request $request): string
    {
        $forwarded = $this->trustProxy !== false ? $request->headers->get('x-forwarded-host') : null;
        return Routes::hostName($forwarded ?? $request->headers->get('host') ?? (new Url($request->url))->host());
    }

    /** @return list<string> */
    private function savedHosts(): array
    {
        $this->runlight->init();
        try {
            $saved = Json::decode($this->store->setting('server-hosts') ?? '[]', true);
        } catch (\Throwable) {
            return [];
        }
        return is_array($saved) ? array_values(array_filter($saved, 'is_string')) : [];
    }

    /**
     * The names the owner and admins signed in from, kept in the database, so a link domain can never be one of
     * them even when whoever adds it picks another Host header.
     *
     * @return list<string>
     */
    private function knownHosts(): array
    {
        return $this->ownHosts ??= $this->savedHosts();
    }

    /**
     * Only the owner and admins teach the server its names, since anyone else could fill the list with made-up
     * ones, and only real domain names. Names that are already link domains are left out.
     */
    private function learnHost(Request $request): void
    {
        $host = $this->hostOf($request);
        $known = $this->knownHosts();
        if (!preg_match(Routes::DOMAIN_NAME, $host) || in_array($host, $known, true) || count($known) >= self::MAX_OWN_HOSTS) {
            return;
        }
        foreach ($this->store->linkDomains() as $domain) {
            if ($domain['domain'] === $host) {
                return;
            }
        }
        // Another request may have saved names since this one read them.
        foreach ($this->savedHosts() as $saved) {
            if (!in_array($saved, $known, true)) {
                $known[] = $saved;
            }
        }
        $known[] = $host;
        $this->ownHosts = array_slice($known, 0, self::MAX_OWN_HOSTS);
        $this->store->setSetting('server-hosts', Json::encode($this->ownHosts));
    }

    /**
     * The answer to one request.
     *
     * @param array{ip?: string} $context
     */
    public function handle(Request $request, array $context = []): Response
    {
        $path = (new Url($request->url))->pathname;
        try {
            // A domain pointed at this server for short links answers at its root, with links one segment deep. The
            // server's own pages and its public address never answer as links, and "/" stays the dashboard for someone
            // signed in, so a link domain added on the dashboard's own name can always be removed again.
            $linkable = $path === Runlight::LINK_DOMAIN_CHECK
                || (preg_match('#^/[^/]*$#D', $path) && !in_array($path, self::SERVER_PATHS, true) && !($path === '/' && $this->web->signedIn($request) !== null));
            if ($linkable && !($this->publicHost !== null && $this->hostOf($request) === $this->publicHost)) {
                $linked = $this->runlight->linkDomainResponse($request, $context);
                if ($linked !== null) {
                    return $linked;
                }
            }
            if ($path === '/healthz') {
                return new Response('ok', 200, ['content-type' => 'text/plain', 'cache-control' => 'no-store']);
            }
            if ($request->method === 'GET' && preg_match('#^/go/[^/]+/?$#D', $path)) {
                return ($this->runlight->linkHandler())($request, $context);
            }
            // Everything else, the sign-in pages and People included, is the routes'.
            return $this->routes->handle($request, $context);
        } catch (\Throwable $error) {
            error_log('Runlight: ' . $error->getMessage());
            return Routes::coded('Internal error', 'internal', 500);
        }
    }

    /**
     * Answers the request PHP is serving now, then does the work left after answering (a retention change's
     * deletions) once the visitor has the answer, where the server can hand it over early.
     */
    public function serve(): void
    {
        $request = Request::fromGlobals();
        $response = $this->handle($request, ['ip' => $request->remoteAddress]);
        $response->emit($request->method !== 'HEAD');
        if (function_exists('fastcgi_finish_request')) {
            fastcgi_finish_request();
        } elseif (function_exists('litespeed_finish_request')) {
            litespeed_finish_request();
        }
        $this->runlight->idle();
    }

    /**
     * The scheduled work: salts, email reports that are due, retention, and rollups.
     *
     * @return array{ok: true, reports: array{sent: int, failed: int}}
     */
    public function check(): array
    {
        $result = $this->runlight->check();
        $this->runlight->idle();
        return $result;
    }
}
