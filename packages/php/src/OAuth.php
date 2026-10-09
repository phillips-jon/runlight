<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;

/**
 * OAuth for the MCP server, so apps that connect only through OAuth (the
 * Claude and ChatGPT web connectors) can reach it. Runlight is both the
 * resource and the authorization server:
 *
 * - /.well-known/oauth-protected-resource names the MCP endpoint and this server.
 * - /.well-known/oauth-authorization-server lists the endpoints below.
 * - POST /oauth/register lets a client register itself (public clients, no secret).
 * - /oauth/authorize asks the signed-in owner to allow the client, every site or one.
 * - POST /oauth/token swaps the one-time code, checked with PKCE, for a token.
 *
 * The token is an ordinary API token, so it appears in Settings, API and AI,
 * beside the others, and deleting it there disconnects the app. It reads
 * stats, or with the "manage" scope (asked for by a Runlight hub) it also
 * changes one site's settings.
 *
 * The context the routes pass is an array: runlight, base, isOwner (callable(Request): bool), and optionally
 * signIn (string), isReader (callable(Request): bool), accountOf (callable(Request): ?string), and tokenMade
 * (callable(array $token, string $by): bool).
 */
final class OAuth
{
    public const CODE_MS = 5 * 60_000;
    /** An app stored before client ids were signed, which never finished connecting within a day, is removed. */
    public const UNUSED_CLIENT_MS = 86_400_000;
    /** Registrations one address may make a minute. */
    public const REGISTRATIONS_PER_MINUTE = 10;
    /** The longest client id, which carries the app's name and redirect addresses. */
    public const MAX_CLIENT_ID = 2048;

    /**
     * Where the per-address count of registrations is kept. TypeScript keeps it in memory per install; PHP
     * forgets memory between requests, so it lives in the install's settings, keyed by a hash of the address.
     */
    private const REGISTRATIONS = 'oauth-registrations';

    private const CORS = [
        'access-control-allow-origin' => '*',
        'access-control-allow-headers' => 'authorization, content-type, mcp-protocol-version',
        'access-control-allow-methods' => 'GET, POST, OPTIONS',
    ];

    private static function base64url(string $text): string
    {
        return rtrim(strtr(base64_encode($text), '+/', '-_'), '=');
    }

    private static function fromBase64url(string $text): string
    {
        return (string) base64_decode(strtr($text, '-_', '+/'), true);
    }

    /** The key client ids are signed with, made on first use and kept in the database for every process. */
    private static function clientKey(object $runlight): string
    {
        $saved = $runlight->store->setting('oauth-key');
        if ($saved !== null && $saved !== '') {
            return $saved;
        }
        $made = Hash::randomId(32);
        $runlight->store->setSetting('oauth-key', $made);
        return $made;
    }

    /**
     * The app a client id names, and where to note that it connected. A new id
     * carries the app's name and addresses, signed, so registering stores
     * nothing and a flood of registrations fills nothing. Ids from before that
     * were stored.
     *
     * @return array{client: array<string, mixed>, usedKey: string}|null
     */
    private static function clientFor(object $runlight, string $id): ?array
    {
        if (preg_match('/^[a-f0-9]{32}\z/', $id)) {
            $stored = $runlight->store->setting("oauth-client:$id");
            return $stored !== null && $stored !== '' ? ['client' => Json::decode($stored, true), 'usedKey' => "oauth-client:$id"] : null;
        }
        if (!preg_match('/^([A-Za-z0-9_-]{1,2000})\.([a-f0-9]{64})\z/', $id, $parts) || strlen($id) > self::MAX_CLIENT_ID) {
            return null;
        }
        if (!self::constantTimeEqual($parts[2], Hash::hmac(self::clientKey($runlight), $parts[1]))) {
            return null;
        }
        $meta = Json::decode(self::fromBase64url($parts[1]), true);
        $usedKey = 'oauth-used:' . Hash::sha256($id);
        $used = $runlight->store->setting($usedKey);
        $client = ['name' => $meta['n'], 'redirects' => $meta['r'], 'createdAt' => $meta['t']];
        if ($used !== null && $used !== '') {
            $client['usedAt'] = Js::number($used);
        }
        return ['client' => $client, 'usedKey' => $usedKey];
    }

    private static function constantTimeEqual(string $a, string $b): bool
    {
        return strlen($a) === strlen($b) && hash_equals($a, $b);
    }

    private static function esc(string $value): string
    {
        return strtr($value, ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;']);
    }

    private static function json(mixed $body, int $status = 200): Response
    {
        return new Response(Json::encode($body), $status, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'] + self::CORS);
    }

    private static function oauthError(string $error, string $description, int $status = 400): Response
    {
        return self::json(['error' => $error, 'error_description' => $description], $status);
    }

    /** base64url of SHA-256, as PKCE's S256 method compares. */
    public static function s256(string $verifier): string
    {
        return self::base64url(hash('sha256', $verifier, true));
    }

    /** Redirect addresses a client may register: https, or a local app's own loopback address. */
    private static function allowedRedirect(string $value): bool
    {
        return (bool) preg_match('#^https://[^/]+#', $value) || (bool) preg_match('#^http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/#', $value);
    }

    /** The URL that a 401 from the MCP endpoint points clients at, to start OAuth. */
    public static function resourceMetadataUrl(string $origin, string $base): string
    {
        return "$origin$base/.well-known/oauth-protected-resource";
    }

    /**
     * Answers the OAuth paths, or returns null for anything else. `path` is
     * relative to the routes' base; the two well-known documents are also answered
     * at the site's root (`/.well-known/...`) for clients that look there.
     *
     * @param array<string, mixed> $ctx
     * @param array{ip?: string} $context
     */
    public static function oauthResponse(array $ctx, Request $request, string $path, Url $url, array $context = []): ?Response
    {
        $runlight = $ctx['runlight'];
        $base = (string) $ctx['base'];
        $issuer = $url->origin() . $base;
        $known = $path;
        if ($request->method === 'OPTIONS' && (str_starts_with($known, '/.well-known/oauth-') || str_starts_with($known, '/.well-known/openid-configuration') || str_starts_with($path, '/oauth/'))) {
            return new Response('', 204, self::CORS);
        }

        if (str_starts_with($known, '/.well-known/oauth-protected-resource')) {
            return self::json(['resource' => "$issuer/mcp", 'authorization_servers' => [$issuer], 'scopes_supported' => ['read', 'manage'], 'bearer_methods_supported' => ['header']]);
        }
        if (str_starts_with($known, '/.well-known/oauth-authorization-server') || str_starts_with($known, '/.well-known/openid-configuration')) {
            return self::json([
                'issuer' => $issuer,
                'authorization_endpoint' => "$issuer/oauth/authorize",
                'token_endpoint' => "$issuer/oauth/token",
                'registration_endpoint' => "$issuer/oauth/register",
                'response_types_supported' => ['code'],
                'grant_types_supported' => ['authorization_code'],
                'code_challenge_methods_supported' => ['S256'],
                'token_endpoint_auth_methods_supported' => ['none'],
                'scopes_supported' => ['read', 'manage'],
            ]);
        }

        if ($path === '/oauth/register' && $request->method === 'POST') {
            $runlight->init();
            if (!self::allowRegistration($runlight, $runlight->clientIp($request, $context))) {
                return self::oauthError('invalid_client_metadata', 'Too many registrations from this address. Wait a minute and try again.', 429);
            }
            [$parsed, $body] = Js::parseJson($request->text());
            if (!$parsed) {
                $body = null;
            }
            $uris = $body !== null && Js::isObject($body) ? Js::get($body, 'redirect_uris') : null;
            $redirects = [];
            if (is_array($uris) && array_is_list($uris)) {
                $redirects = array_slice(array_values(array_filter(array_map(Js::string(...), $uris), self::allowedRedirect(...))), 0, 10);
            }
            if (!$redirects) {
                return self::oauthError('invalid_redirect_uri', 'Register at least one https redirect address');
            }
            $name = $body !== null && Js::isObject($body) ? Js::get($body, 'client_name') : null;
            return self::register($runlight, Js::string($name === null || $name instanceof Undefined ? 'An app' : $name), $redirects);
        }

        if ($path === '/oauth/authorize' && ($request->method === 'GET' || $request->method === 'POST')) {
            $runlight->init();
            $form = $request->method === 'POST' ? new SearchParams($request->text()) : $url->searchParams();
            $clientId = $form->get('client_id') ?? '';
            $client = self::clientFor($runlight, $clientId)['client'] ?? null;
            $redirect = $form->get('redirect_uri') ?? '';
            // Without a known client and one of its own addresses there is nowhere safe to send an answer.
            if ($client === null || !in_array($redirect, $client['redirects'], true)) {
                return self::page('This app is not registered', '<p>Start connecting again from the app.</p>', 400);
            }
            $back = static function (array $params) use ($redirect, $form): Response {
                $to = new Url($redirect);
                $query = $to->searchParams();
                foreach ($params as $k => $v) {
                    $query->set($k, $v);
                }
                $state = $form->get('state');
                if ($state !== null && $state !== '') {
                    $query->set('state', $state);
                }
                $to->setSearchParams($query);
                return new Response('', 303, ['location' => $to->href(), 'cache-control' => 'no-store']);
            };
            // Anyone can register an app with any address, so until an owner has allowed it once, a request
            // it got wrong ends on a page here rather than sending a visitor who is not signed in on to it.
            $refuse = static fn (array $params): Response => isset($client['usedAt']) && Js::truthy($client['usedAt'])
                ? $back($params)
                : self::page('This app asked in a way Runlight does not support', '<p>' . self::esc((string) $client['name']) . ' sent ' . self::esc($params['error_description'] ?? $params['error']) . '. Start connecting again from the app.</p>', 400);
            if ($form->get('response_type') !== 'code') {
                return $refuse(['error' => 'unsupported_response_type']);
            }
            $challenge = $form->get('code_challenge') ?? '';
            if ($form->get('code_challenge_method') !== 'S256' || !preg_match('/^[A-Za-z0-9_-]{43,128}\z/', $challenge)) {
                return $refuse(['error' => 'invalid_request', 'error_description' => 'PKCE with S256 is required']);
            }
            $manage = in_array('manage', preg_split('/[' . Js::SPACE . ']+/u', $form->get('scope') ?? '') ?: [], true);
            $name = (string) $client['name'];

            if (!($ctx['isOwner'])($request)) {
                // Someone signed in who may only read would be sent to sign in again and again.
                if (isset($ctx['isReader']) && ($ctx['isReader'])($request)) {
                    return self::page('Ask an owner to connect this', '<p>You are signed in as a viewer, and only an owner of this Runlight can connect ' . self::esc($name) . '.</p>', 403);
                }
                // The site stays, since on the way in it only says which one to offer first.
                $kept = new SearchParams();
                foreach (self::pairs($form) as [$k, $v]) {
                    if ($k !== 'decision') {
                        $kept->append($k, $v);
                    }
                }
                $here = $url->pathname . '?' . $kept->toString();
                if (isset($ctx['signIn'])) {
                    return new Response('', 303, ['location' => $ctx['signIn'] . '?next=' . Js::encodeURIComponent($here), 'cache-control' => 'no-store']);
                }
                $home = $base !== '' ? $base : '/';
                return self::page('Sign in first', '<p>Open your Runlight dashboard at <a href="' . self::esc($home) . '">' . self::esc($url->host() . $home) . '</a> and sign in, then connect ' . self::esc($name) . ' again.</p>', 401);
            }

            if ($request->method === 'GET') {
                $hidden = '';
                foreach (['response_type', 'client_id', 'redirect_uri', 'code_challenge', 'code_challenge_method', 'state', 'scope', 'resource'] as $k) {
                    if ($form->get($k) !== null) {
                        $hidden .= '<input type="hidden" name="' . $k . '" value="' . self::esc($form->get($k)) . '">';
                    }
                }
                // The app names itself, so the page also shows where the answer goes, which it cannot fake.
                $sendsTo = '<p class="note">Allowing sends you back to <strong>' . self::esc((new Url($redirect))->host()) . '</strong>. Only allow it if you started connecting there.</p>';
                $sites = $runlight->sites();
                if ($manage) {
                    // Changing settings is for one site at a time, so there is no "every site" here.
                    $wanted = $form->get('site') ?? '';
                    $choices = '';
                    foreach ($sites as $s) {
                        if ($runlight->remote($s['id']) === null) {
                            $choices .= '<option value="' . self::esc($s['id']) . '"' . ($s['id'] === $wanted ? ' selected' : '') . '>' . self::esc($s['name']) . '</option>';
                        }
                    }
                    return self::page(
                        'Connect ' . self::esc($name),
                        '<p><strong>' . self::esc($name) . "</strong> wants to show this site\u{2019}s stats and change its settings, so you can manage it from there.</p>\n"
                        . "<p>It will be able to change goals, funnels, short links, link domains, email reports, and share links for the site you pick, along with its name, timezone, and retention. It cannot read other sites, add people, make tokens, or change how email is sent.</p>\n"
                        . "$sendsTo\n"
                        . '<form method="post" action="' . self::esc($base) . "/oauth/authorize\">$hidden\n"
                        . "<label>Site<select name=\"site\">$choices</select></label>\n"
                        . '<p class="note">Its token appears in Settings, API and AI, where deleting it disconnects ' . self::esc($name) . ".</p>\n"
                        . '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>',
                    );
                }
                $options = '';
                foreach ($sites as $s) {
                    $options .= '<option value="' . self::esc($s['id']) . '">' . self::esc($s['name']) . ' only</option>';
                }
                return self::page(
                    'Connect ' . self::esc($name),
                    '<p><strong>' . self::esc($name) . "</strong> wants to read your Runlight stats so it can answer questions about them. It will be able to read and never to change anything.</p>\n"
                    . "$sendsTo\n"
                    . '<form method="post" action="' . self::esc($base) . "/oauth/authorize\">$hidden\n"
                    . '<label>Which sites it can read<select name="site"><option value="">Every site</option>' . (count($sites) > 1 ? $options : '') . "</select></label>\n"
                    . "<p class=\"note\">Its token appears in Settings, API and AI, where deleting it disconnects the app.</p>\n"
                    . '<div class="buttons"><button type="submit" name="decision" value="deny" class="ghost">Deny</button><button type="submit" name="decision" value="allow">Allow</button></div></form>',
                );
            }
            // The consent form posts here from this page only; a form from another site is refused.
            $origin = $request->headers->get('origin');
            if ($origin !== null && $origin !== '' && $origin !== $url->origin()) {
                return self::page('This request came from another site', '<p>Start connecting again from the app.</p>', 403);
            }
            if ($form->get('decision') !== 'allow') {
                return $back(['error' => 'access_denied']);
            }
            $site = $form->get('site') ?? '';
            if ($site !== '' && $runlight->site($site) === null) {
                return $back(['error' => 'invalid_request', 'error_description' => 'Unknown site']);
            }
            if ($manage && ($site === '' || $runlight->remote($site) !== null)) {
                return $back(['error' => 'invalid_request', 'error_description' => 'Pick the site to manage']);
            }
            $code = Hash::randomId(32);
            $by = isset($ctx['accountOf']) ? ($ctx['accountOf'])($request) : null;
            $grant = ['client' => $clientId, 'redirect' => $redirect, 'challenge' => $challenge, 'site' => $site, 'scope' => $manage ? 'manage' : 'read', 'expires' => $runlight->now() + self::CODE_MS];
            if ($by !== null && $by !== '') {
                $grant['by'] = $by;
            }
            $runlight->store->setSetting('oauth-code:' . Hash::sha256($code), Json::encode($grant));
            return $back(['code' => $code]);
        }

        if ($path === '/oauth/token' && $request->method === 'POST') {
            $runlight->init();
            $type = trim(explode(';', $request->headers->get('content-type') ?? '')[0]);
            $form = $type === 'application/json' ? self::jsonForm($request->text()) : new SearchParams($request->text());
            if ($form->get('grant_type') !== 'authorization_code') {
                return self::oauthError('unsupported_grant_type', 'Only authorization_code is supported');
            }
            $key = 'oauth-code:' . Hash::sha256($form->get('code') ?? '');
            $stored = $runlight->store->setting($key);
            // A code works once: it is gone before anything else is checked.
            if ($stored !== null && $stored !== '') {
                $runlight->store->setSetting($key, null);
            }
            $grant = $stored !== null && $stored !== '' ? Json::decode($stored, true) : null;
            if ($grant === null || $grant['expires'] < $runlight->now()) {
                return self::oauthError('invalid_grant', 'The code has expired or was already used');
            }
            if ($grant['client'] !== $form->get('client_id') || $grant['redirect'] !== $form->get('redirect_uri')) {
                return self::oauthError('invalid_grant', 'The code was issued to another app');
            }
            if (self::s256($form->get('code_verifier') ?? '') !== $grant['challenge']) {
                return self::oauthError('invalid_grant', 'The code verifier does not match');
            }
            // The first row an app gets here: it has connected, so a request it gets wrong may go back to it.
            $found = self::clientFor($runlight, (string) $grant['client']);
            $client = $found['client'] ?? [];
            if ($found !== null && !Js::truthy($found['client']['usedAt'] ?? null)) {
                $storedClient = str_starts_with($found['usedKey'], 'oauth-client:');
                $used = $found['client'];
                $used['usedAt'] = $runlight->now();
                $runlight->store->setSetting($found['usedKey'], $storedClient ? Json::encode($used) : (string) $runlight->now());
            }
            $secret = 'rl_' . Hash::randomId(20);
            $scope = ($grant['scope'] ?? '') === 'manage' ? 'manage' : 'read';
            $row = [
                'id' => Hash::randomId(),
                'name' => Js::slice(Js::string($client['name'] ?? 'An app') . ' (OAuth)', 0, 100),
                'site' => (string) $grant['site'],
                'scope' => $scope,
                'hash' => Hash::sha256($secret),
                'hint' => substr($secret, -4),
                'createdAt' => $runlight->now(),
                'lastUsedAt' => null,
            ];
            $runlight->store->insertToken($row);
            // Someone removed, or no longer an owner, between allowing the app and its swapping the code gets nothing.
            if (isset($grant['by']) && $grant['by'] !== '' && isset($ctx['tokenMade']) && !($ctx['tokenMade'])($row, (string) $grant['by'])) {
                $runlight->store->deleteToken($row['id']);
                return self::oauthError('invalid_grant', 'Whoever allowed this app can no longer connect it');
            }
            // A hub's own address, from where it asked to be sent back, so the picker only ever sends choices there.
            if ($scope === 'manage') {
                $runlight->store->setSetting('token-origin:' . $row['id'], (new Url((string) $grant['redirect']))->origin());
            }
            // site is not part of OAuth, but a hub needs to know which site it was given.
            $answer = ['access_token' => $secret, 'token_type' => 'Bearer', 'scope' => $scope];
            if ($grant['site'] !== '') {
                $answer['site'] = $grant['site'];
            }
            return self::json($answer);
        }

        return null;
    }

    /** @return list<array{0: string, 1: string}> */
    private static function pairs(SearchParams $params): array
    {
        $out = [];
        foreach ($params as $k => $v) {
            $out[] = [(string) $k, $v];
        }
        return $out;
    }

    /** `new URLSearchParams(Object.entries(await request.json() ?? {}))`, each value as String() writes it. */
    private static function jsonForm(string $text): SearchParams
    {
        [$parsed, $body] = Js::parseJson($text);
        $form = new SearchParams();
        if (!$parsed || $body === null) {
            return $form;
        }
        if ($body instanceof \stdClass) {
            foreach (get_object_vars($body) as $k => $v) {
                $form->append((string) $k, Js::string($v));
            }
        } elseif (is_array($body)) {
            foreach ($body as $i => $v) {
                $form->append((string) $i, Js::string($v));
            }
        } elseif (is_string($body)) {
            foreach (mb_str_split($body) as $i => $c) {
                $form->append((string) $i, $c);
            }
        }
        return $form;
    }

    /**
     * Counts a registration from an address and says whether it is under the limit for this minute. The count
     * is kept in the install's settings, keyed by an HMAC of the address, so no address is ever stored.
     */
    private static function allowRegistration(object $runlight, string $ip): bool
    {
        // No address cannot be told apart, so it is not limited.
        if ($ip === '') {
            return true;
        }
        $window = intdiv($runlight->now(), 60_000);
        $id = substr(Hash::hmac(self::clientKey($runlight), "register:$ip"), 0, 16);
        $saved = Json::tryDecode((string) $runlight->store->setting(self::REGISTRATIONS), true);
        $counts = is_array($saved) && ($saved['window'] ?? null) === $window && is_array($saved['counts'] ?? null) ? $saved['counts'] : [];
        $counts[$id] = (int) ($counts[$id] ?? 0) + 1;
        $runlight->store->setSetting(self::REGISTRATIONS, Json::encode(['window' => $window, 'counts' => (object) $counts]));
        return $counts[$id] <= self::REGISTRATIONS_PER_MINUTE;
    }

    /**
     * Registers a client by signing its name and addresses into its id, so
     * nothing is stored until an owner allows it and the app swaps its code.
     *
     * @param list<string> $redirects
     */
    private static function register(object $runlight, string $name, array $redirects): Response
    {
        $now = $runlight->now();
        // Apps stored before ids were signed, which never connected, and codes nobody exchanged are cleared away.
        foreach ($runlight->store->settingsStartingWith('oauth-client:') as $entry) {
            $client = Json::decode($entry['value'], true);
            if (!Js::truthy($client['usedAt'] ?? null) && $now - $client['createdAt'] >= self::UNUSED_CLIENT_MS) {
                $runlight->store->setSetting($entry['key'], null);
            }
        }
        foreach ($runlight->store->settingsStartingWith('oauth-code:') as $entry) {
            $code = Json::tryDecode($entry['value'], true);
            if (Js::number(is_array($code) ? ($code['expires'] ?? 0) : 0) < $now) {
                $runlight->store->setSetting($entry['key'], null);
            }
        }
        $trimmed = Js::slice(Js::trim($name), 0, 80);
        $clientName = $trimmed !== '' ? $trimmed : 'An app';
        $payload = self::base64url(Json::encode(['n' => $clientName, 'r' => $redirects, 't' => $now]));
        $id = "$payload." . Hash::hmac(self::clientKey($runlight), $payload);
        if (strlen($id) > self::MAX_CLIENT_ID) {
            return self::oauthError('invalid_client_metadata', 'Register fewer or shorter redirect addresses');
        }
        return self::json(['client_id' => $id, 'client_name' => $clientName, 'redirect_uris' => $redirects, 'token_endpoint_auth_method' => 'none', 'grant_types' => ['authorization_code'], 'response_types' => ['code']], 201);
    }

    private static function page(string $title, string $body, int $status = 200): Response
    {
        return new Response(
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>$title | Runlight</title>\n"
            . '<style>:root{color-scheme:light dark;--page:#f4f4f5;--card:#fff;--ink:#111827;--muted:#4b5563;--line:#e5e7eb}@media (prefers-color-scheme:dark){:root{--page:#09090b;--card:#141417;--ink:#fafafa;--muted:#a1a1aa;--line:#27272a}}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--page);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}main{width:min(440px,calc(100% - 32px));padding:28px;background:var(--card);border:1px solid var(--line);border-radius:14px}h1{font-size:20px;margin:0 0 12px}p{margin:0 0 16px;color:var(--muted)}p strong{color:var(--ink)}a{color:inherit}label{display:block;margin:0 0 14px;font-size:13px;font-weight:600}select{display:block;width:100%;height:40px;margin-top:6px;padding:0 36px 0 12px;border:1px solid var(--line);border-radius:8px;background:var(--card) url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 16 16\'%3E%3Cpath d=\'M4 6l4 4 4-4\' fill=\'none\' stroke=\'%238a8a93\' stroke-width=\'1.6\' stroke-linecap=\'round\' stroke-linejoin=\'round\'/%3E%3C/svg%3E") right 12px center/14px no-repeat;color:var(--ink);font:inherit;font-weight:400;appearance:none;cursor:pointer}.note{font-size:13px}.buttons{display:flex;justify-content:flex-end;gap:8px}button{height:40px;padding:0 18px;border:0;border-radius:8px;background:var(--ink);color:var(--card);font:inherit;font-weight:600;cursor:pointer}button.ghost{background:none;color:var(--ink);border:1px solid var(--line)}</style></head><body><main><h1>'
            . "$title</h1>$body</main></body></html>",
            $status,
            [
                'content-type' => 'text/html; charset=utf-8',
                'cache-control' => 'no-store',
                // No form-action rule: browsers apply it to the redirect back to the app after Allow.
                'content-security-policy' => "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
                'x-frame-options' => 'DENY',
                // same-origin, not no-referrer: under no-referrer a form post carries Origin: null, which the consent check refuses.
                'referrer-policy' => 'same-origin',
            ],
        );
    }
}
