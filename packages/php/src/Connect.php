<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\SearchParams;
use Runlight\Http\Url;

/**
 * Connecting another Runlight to this one (a hub) without copying a token:
 * this server registers itself with the install's OAuth server, sends the
 * owner to that install's consent page, and on the way back swaps the code
 * for a manage token, limited there to the one site the owner picked.
 *
 * A pending attempt is kept in settings as `connect:<state>`: the install's `url`, the `client` id it gave,
 * the PKCE `verifier`, the `redirect` address, its `token` endpoint, and when it `expires`.
 */
final class Connect
{
    private const PENDING_MS = 15 * 60_000;
    /** The most an install's answer while connecting may weigh; a real one is under a kilobyte. */
    private const MAX_BYTES = 64 * 1024;

    /** The install's address as its dashboard is, without a trailing slash. */
    public static function installUrl(mixed $value, bool $local = false): string
    {
        $url = (string) preg_replace('#/+$#', '', Js::trim(Js::string($value ?? '')));
        // The pattern says which addresses are allowed; the parser, that it is an address at all ("https://[" is not).
        if (!Safefetch::installAddress($url, $local) || !Url::canParse($url)) {
            throw new ConnectError("Enter the install's address, like https://example.com/runlight", 'url');
        }
        return $url;
    }

    /** Attempts nobody came back from are removed, so they do not pile up in settings. */
    private static function clearExpired(Runlight $runlight): void
    {
        foreach ($runlight->store->settingsStartingWith('connect:') as ['key' => $key, 'value' => $value]) {
            if (self::pendingFrom($value, $runlight->now()) === null) {
                $runlight->store->setSetting($key, null);
            }
        }
    }

    /**
     * A saved attempt, or null when it cannot be read or has no time it runs out, which counts as expired.
     *
     * @return array<string, mixed>|null
     */
    private static function pendingFrom(?string $value, int|float $now): ?array
    {
        $pending = Json::tryDecode((string) $value, true);
        // A JSON object, not a list or a scalar.
        if (!is_array($pending) || ($pending !== [] && array_is_list($pending))) {
            return null;
        }
        $expires = $pending['expires'] ?? null;
        return (is_int($expires) || is_float($expires)) && $expires >= $now ? $pending : null;
    }

    /** The PKCE challenge for a verifier: SHA-256, base64url without padding (oauth.ts's s256). */
    private static function s256(string $verifier): string
    {
        return rtrim(strtr(base64_encode(hash('sha256', $verifier, true)), '+/', '-_'), '=');
    }

    /** A JSON body as arrays, or null when it is not JSON or is over MAX_BYTES, as TS's readJsonCapped gives. */
    private static function json(Http\Response $answer): mixed
    {
        try {
            $text = Body::readTextCapped($answer, self::MAX_BYTES);
        } catch (\Throwable) {
            return null;
        }
        [$ok, $value] = Js::parseJson($text);
        return $ok ? json_decode(Json::encode($value), true) : null;
    }

    /** Starts connecting: returns the address of the install's consent page. */
    public static function startConnect(Runlight $runlight, mixed $input, string $back, string $site = ''): string
    {
        $local = $runlight->localInstalls;
        $url = self::installUrl($input, $local);
        $host = (new Url($url))->host();
        try {
            $answer = Safefetch::installFetch("$url/.well-known/oauth-authorization-server", ['timeoutMs' => 10_000, 'maxBytes' => self::MAX_BYTES, 'truncate' => true, 'local' => $local], $runlight->fetcher);
        } catch (\Throwable) {
            throw new ConnectError("Could not reach $url", 'unreachable', ['host' => $host]);
        }
        $meta = $answer->ok() ? self::json($answer) : null;
        $meta = is_array($meta) ? $meta : null;
        $endpoint = static fn (string $name): string => is_string($meta[$name] ?? null) ? $meta[$name] : '';
        if ($meta === null || !Js::truthy($meta['authorization_endpoint'] ?? null) || !Js::truthy($meta['token_endpoint'] ?? null) || !Js::truthy($meta['registration_endpoint'] ?? null)) {
            throw new ConnectError("$url did not answer like a Runlight install", 'not_runlight', ['url' => $url]);
        }
        // Its endpoints must be its own, so an address cannot steer this server into requests elsewhere.
        $origin = (new Url($url))->origin();
        foreach (['authorization_endpoint', 'token_endpoint', 'registration_endpoint'] as $name) {
            $parsed = Url::parse($endpoint($name));
            if ($parsed === null || $parsed->origin() !== $origin) {
                throw new ConnectError("$url named endpoints on another address", 'endpoints', ['url' => $url]);
            }
        }
        if (!is_array($meta['scopes_supported'] ?? null) || !in_array('manage', $meta['scopes_supported'], true)) {
            throw new ConnectError("$url runs an older Runlight. Update it, or connect it with an API token from its Settings.", 'old', ['url' => $url]);
        }

        try {
            $registered = Safefetch::installFetch($meta['registration_endpoint'], [
                'method' => 'POST',
                'headers' => ['content-type' => 'application/json'],
                'body' => Json::encode(['client_name' => 'Runlight at ' . (new Url($back))->host(), 'redirect_uris' => [$back]]),
                'timeoutMs' => 10_000,
                'maxBytes' => self::MAX_BYTES,
                'truncate' => true,
                'local' => $local,
            ], $runlight->fetcher);
        } catch (\Throwable) {
            throw new ConnectError("Could not reach $url", 'unreachable', ['host' => $host]);
        }
        $client = self::json($registered);
        $clientId = is_array($client) ? ($client['client_id'] ?? null) : null;
        if (!$registered->ok() || !Js::truthy($clientId)) {
            // Say why, in the install's own words when it gives them.
            $description = is_array($client) ? ($client['error_description'] ?? null) : null;
            $reason = Js::truthy($description) ? Js::slice(Js::string($description), 0, 200) . '.' : ($registered->status === 400 ? "This server's address must use https." : "It answered {$registered->status}.");
            throw new ConnectError("$url would not let this server connect. $reason", 'register', ['url' => $url, 'reason' => $reason]);
        }
        $clientId = Js::string($clientId);
        self::clearExpired($runlight);

        $state = Hash::randomId(16);
        $verifier = Hash::randomId(32) . Hash::randomId(32);
        $pending = ['url' => $url, 'client' => $clientId, 'verifier' => $verifier, 'redirect' => $back, 'token' => $meta['token_endpoint'], 'expires' => $runlight->now() + self::PENDING_MS];
        $runlight->store->setSetting("connect:$state", Json::encode($pending));
        $to = new Url($meta['authorization_endpoint']);
        $to->setSearchParams(new SearchParams([
            'response_type' => 'code',
            'client_id' => $clientId,
            'redirect_uri' => $back,
            'code_challenge' => self::s256($verifier),
            'code_challenge_method' => 'S256',
            'scope' => 'manage',
            'state' => $state,
            // Which of its sites to offer first, when connecting again for a site already here.
            ...($site !== '' ? ['site' => $site] : []),
        ]));
        return $to->href();
    }

    /** Finishes connecting when the owner comes back from the consent page. Returns the site's id here. */
    public static function finishConnect(Runlight $runlight, SearchParams $params): string
    {
        $state = $params->get('state') ?? '';
        $key = "connect:$state";
        $stored = preg_match('/^[a-f0-9]{32}$/D', $state) ? $runlight->store->setting($key) : null;
        // Each attempt works once.
        if ($stored !== null && $stored !== '') {
            $runlight->store->setSetting($key, null);
        }
        $pending = $stored !== null && $stored !== '' ? self::pendingFrom($stored, $runlight->now()) : null;
        if ($pending === null) {
            throw new ConnectError('That connection took too long or was already used. Start again.', 'expired');
        }
        if ($params->get('error') === 'access_denied') {
            throw new ConnectError('The connection was not allowed.', 'denied');
        }
        if (Js::truthy($params->get('error'))) {
            throw new ConnectError((string) ($params->get('error_description') ?? $params->get('error')), 'refused');
        }

        $answer = null;
        try {
            $answer = Safefetch::installFetch($pending['token'], [
                'method' => 'POST',
                'headers' => ['content-type' => 'application/x-www-form-urlencoded'],
                'body' => (new SearchParams([
                    'grant_type' => 'authorization_code',
                    'code' => $params->get('code') ?? '',
                    'client_id' => $pending['client'],
                    'redirect_uri' => $pending['redirect'],
                    'code_verifier' => $pending['verifier'],
                ]))->toString(),
                'timeoutMs' => 10_000,
                'maxBytes' => self::MAX_BYTES,
                'truncate' => true,
                'local' => $runlight->localInstalls,
            ], $runlight->fetcher);
        } catch (\Throwable) {
        }
        $granted = $answer !== null && $answer->ok() ? self::json($answer) : null;
        $token = is_array($granted) ? ($granted['access_token'] ?? null) : null;
        if (!Js::truthy($token)) {
            throw new ConnectError((new Url($pending['url']))->host() . ' did not give this server a token. Start again.', 'token');
        }
        $remote = ['url' => $pending['url'], 'token' => $token];
        $remote['site'] = array_key_exists('site', $granted) ? $granted['site'] : Undefined::value();
        $site = $runlight->addSite(['remote' => $remote]);
        return $site['id'];
    }
}
