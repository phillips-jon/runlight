<?php

declare(strict_types=1);

namespace Runlight\Accounts;

use Runlight\Http\Headers;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Js;
use Runlight\Json;
use Runlight\Store\SqlStore;
use Runlight\Undefined;

/**
 * Accounts on the web: sign-in, the code step, invites, first-run setup, and the Account and People APIs, under
 * the base path the routes answer at. The standalone server and an app with routes(['accounts' => true]) share it.
 *
 * Who may create the first account (`firstAccount`): the server's printed one-time code (['code' => ...]), the
 * app's token (['token' => ...]), anyone ("open", for development), or nobody yet ("locked").
 *
 * @phpstan-import-type User from Accounts
 * @phpstan-import-type Invite from Accounts
 */
final class Web
{
    private const HTML = [
        'content-type' => 'text/html; charset=utf-8',
        'cache-control' => 'no-store',
        'content-security-policy' => "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        'x-frame-options' => 'DENY',
        'referrer-policy' => 'same-origin',
    ];

    private const DEVICE_COOKIE = 'runlight_device';
    /** Who made each token, kept beside it as a setting, so removing someone or making them a viewer deletes them. */
    private const MADE_BY = 'token-by:';
    /** When each account was last sent a sign-in link, at most one a minute; a setting, since PHP forgets between requests. */
    private const LINK_SENT = 'login-link-sent:';

    public readonly Accounts $accounts;

    /** @var \Runlight\Runlight */
    private object $rl;
    private SqlStore $store;
    private string $base;
    /** @var callable(): int */
    private $now;
    /** @var 'open'|'locked'|array{code: string}|array{token: string} */
    private string|array $first;
    /** @var (callable(): ?string)|null */
    private $home;
    private string $forgot;
    private string $cookiePath;
    private string $homePath;
    private bool $asksForToken;
    private bool $existing = false;

    // Wrong passwords are counted twice. Per account and address, ten tries;
    // per account from anywhere, fifty, so a caller who invents a new address
    // for every try still cannot guess on and on. Addresses come from
    // forwarding headers a client can write, so they never stand alone.
    // Each try counts before the password is checked, and a right one is taken back.
    private Throttle $perAddress;
    private Throttle $perAccount;
    // Six-digit codes: five wrong tries an account every fifteen minutes, and five to confirm the first one.
    // Password re-checks in Account: ten.
    private Throttle $codeTries;
    private Throttle $confirmTries;
    private Throttle $rechecks;

    /**
     * @param array{runlight: object, secret: string, base: string, now: callable(): int, firstAccount: 'open'|'locked'|array{code: string}|array{token: string}, home?: callable(): ?string, forgot: string} $options
     */
    public function __construct(array $options)
    {
        $this->rl = $options['runlight'];
        $this->store = $this->rl->store;
        $this->base = $options['base'];
        $this->now = $options['now'];
        $this->first = $options['firstAccount'];
        $this->home = $options['home'] ?? null;
        $this->forgot = $options['forgot'];
        $this->accounts = new Accounts($this->store, $options['secret']);
        $this->cookiePath = $this->base !== '' ? $this->base : '/';
        $this->homePath = "$this->base/";
        $this->asksForToken = is_array($this->first) && array_key_exists('token', $this->first);
        $this->perAddress = new Throttle($this->store, 'address', 10);
        $this->perAccount = new Throttle($this->store, 'account', 50);
        $this->codeTries = new Throttle($this->store, 'code', 5);
        $this->confirmTries = new Throttle($this->store, 'confirm', 5);
        $this->rechecks = new Throttle($this->store, 'recheck', 10);
    }

    /** A random one-time code, such as the one a server prints to unlock its first account. */
    public static function setupCode(): string
    {
        return Crypto::base64url(Crypto::randomBytes(9));
    }

    private function now(): int
    {
        return ($this->now)();
    }

    private function homeOrigin(): ?string
    {
        return $this->home === null ? null : ($this->home)();
    }

    public function hasAccount(): bool
    {
        return $this->existing = $this->existing || $this->accounts->count() > 0;
    }

    private static function readCookie(Request $request, string $name): string
    {
        foreach (explode(';', $request->headers->get('cookie') ?? '') as $part) {
            $pieces = explode('=', Js::trim($part));
            $key = array_shift($pieces);
            if ($key === $name) {
                return implode('=', $pieces);
            }
        }
        return '';
    }

    private static function isSecure(Request $request): bool
    {
        return (new Url($request->url))->protocol === 'https:' || $request->headers->get('x-forwarded-proto') === 'https';
    }

    /**
     * An error the dashboard words in its own language, as the routes send them.
     *
     * @param array<string, string>|null $params
     */
    private static function coded(string $error, string $code, int $status, ?array $params = null): Response
    {
        $body = ['error' => $error, 'code' => $code];
        if ($params !== null) {
            $body['params'] = Json::object($params);
        }
        return new Response(Json::encode($body), $status, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store', 'x-content-type-options' => 'nosniff']);
    }

    private static function esc(string $s): string
    {
        return str_replace(['&', '<', '>', '"', "'"], ['&amp;', '&lt;', '&gt;', '&quot;', '&#39;'], $s);
    }

    /**
     * Only a path on this install, so a sign-in can never send someone elsewhere.
     * Browsers drop tabs and newlines from a URL and read a backslash as a slash,
     * so "/\t/evil.example" would leave; anything with those is refused outright,
     * and what is left must resolve to this origin.
     */
    public function safeNext(?string $value): string
    {
        if ($value === null || $value === '' || !str_starts_with($value, '/') || preg_match('/[\x00-\x1f\x7f\\\\]/', $value)) {
            return $this->homePath;
        }
        $url = Url::parse($value, 'http://runlight.invalid');
        return $url !== null && $url->origin() === 'http://runlight.invalid' ? $url->pathname . $url->search . $url->hash : $this->homePath;
    }

    /** @return User|null */
    public function signedIn(Request $request): ?array
    {
        $value = self::readCookie($request, Accounts::SESSION_COOKIE);
        if ($value === '') {
            return null;
        }
        $decoded = Js::decodeURIComponent($value);
        if ($decoded === null) {
            // decodeURIComponent throws a URIError here in TypeScript.
            throw new \InvalidArgumentException('URI malformed');
        }
        return $this->accounts->fromSession($decoded, $this->now());
    }

    private function dropTokensOf(string $id): void
    {
        foreach ($this->store->settingsStartingWith(self::MADE_BY) as ['key' => $key, 'value' => $value]) {
            if ($value !== $id) {
                continue;
            }
            $this->store->deleteToken(substr($key, strlen(self::MADE_BY)));
            $this->store->setSetting($key, null);
        }
    }

    private function sessionCookie(Request $request, string $value, int $maxAge): string
    {
        return Accounts::SESSION_COOKIE . '=' . Js::encodeURIComponent($value) . "; Path=$this->cookiePath; HttpOnly; SameSite=Lax; Max-Age=$maxAge" . (self::isSecure($request) ? '; Secure' : '');
    }

    /**
     * The redirect after signing in: a session, and the mark that this browser has signed in to the account.
     *
     * @param User $user
     */
    private function signedInTo(Request $request, array $user, string $next): Response
    {
        $headers = new Headers(['location' => $next, 'cache-control' => 'no-store']);
        $headers->append('set-cookie', $this->sessionCookie($request, $this->accounts->sessionFor($user, $this->now()), intdiv(Accounts::SESSION_MS, 1000)));
        $headers->append('set-cookie', self::DEVICE_COOKIE . '=' . Js::encodeURIComponent($this->accounts->deviceFor($user)) . "; Path=$this->cookiePath; HttpOnly; SameSite=Lax; Max-Age=" . (365 * 86_400) . (self::isSecure($request) ? '; Secure' : ''));
        return new Response('', 303, $headers);
    }

    /** @param array<string, string> $extra */
    private static function html(string $body, int $status = 200, array $extra = []): Response
    {
        return new Response($body, $status, array_merge(self::HTML, $extra));
    }

    /** @param array<string, string> $extra */
    private static function redirect(string $location, array $extra = []): Response
    {
        return new Response('', 303, array_merge(['location' => $location, 'cache-control' => 'no-store'], $extra));
    }

    /** @param array<string, string> $extra */
    private static function reply(mixed $body, int $status = 200, array $extra = []): Response
    {
        return new Response(Json::encode($body), $status, array_merge(['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'], $extra));
    }

    /** @param User $u */
    private static function person(array $u): array
    {
        return ['id' => $u['id'], 'email' => $u['email'], 'role' => $u['role'], 'createdAt' => $u['createdAt'], 'twoFactor' => $u['twoFactor'], 'recoveryLeft' => $u['recoveryLeft']];
    }

    /** @param Invite $i */
    private static function inviteView(array $i): array
    {
        return ['id' => $i['id'], 'email' => $i['email'], 'role' => $i['role'], 'invitedBy' => $i['invitedBy'], 'createdAt' => $i['createdAt'], 'expiresAt' => $i['expiresAt']];
    }

    /** The media type of a request's body, as a cross-site form cannot send application/json. */
    private static function mediaType(Request $request): string
    {
        return strtolower(Js::trim(explode(';', $request->headers->get('content-type') ?? '')[0]));
    }

    /** A JSON body by its media type, which a cross-site form cannot send. */
    private static function body(Request $request): ?\stdClass
    {
        if (self::mediaType($request) !== 'application/json') {
            return null;
        }
        [$parsed, $value] = Js::parseJson($request->text());
        return $parsed && $value instanceof \stdClass ? $value : null;
    }

    /** `String(input[field] ?? "")`. */
    private static function field(\stdClass $input, string $field): string
    {
        $value = Js::get($input, $field);
        return $value === null || $value instanceof Undefined ? '' : Js::string($value);
    }

    /** The first account's gate: what the setup form must carry. */
    private function setupOk(string $given): bool
    {
        if ($this->first === 'open') {
            return true;
        }
        if ($this->first === 'locked') {
            return false;
        }
        return Crypto::sameText($given, (string) ($this->first['code'] ?? $this->first['token']));
    }

    /** Why there is no setup form. */
    private function setupLocked(): Response
    {
        return self::html($this->first === 'locked' ? Pages::setupNeedsTokenPage($this->base) : Pages::setupLockedPage($this->base), 403);
    }

    /**
     * Emails an invite through the mail service when there is one. The link
     * always comes back too, for the inviter to pass on another way.
     *
     * @param Invite $invite
     * @return array<string, mixed>
     */
    private function sendInvite(Request $request, array $invite, string $code): array
    {
        $origin = $this->homeOrigin() ?? (new Url($request->url))->origin();
        $link = "$origin$this->base/invite?code=$code";
        $host = (new Url($origin))->host();
        $what = Pages::roleText($invite['role']);
        if (!$this->rl->mailSettings()) {
            return ['link' => $link, 'emailed' => false];
        }
        try {
            $this->rl->sendMail([
                'to' => $invite['email'],
                'subject' => "{$invite['invitedBy']} invited you to Runlight",
                'text' => "{$invite['invitedBy']} invited you to the Runlight at $host as $what.\n\nChoose a password to join:\n$link\n\nThe link works for seven days.\n",
                'html' => "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>" . self::esc($invite['invitedBy']) . ' invited you to the Runlight at ' . self::esc($host) . " as $what.</p><p><a href=\"" . self::esc($link) . '" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Choose a password and join</a></p><p style="color:#6b7280;font-size:13px">The link works for seven days. If you were not expecting this, you can ignore it.</p></div>',
            ]);
            return ['link' => $link, 'emailed' => true];
        } catch (\Throwable $error) {
            // The mail service's code and its details too, so the dashboard can say what went wrong in its own language.
            // Only a public string `code` counts, as TypeScript reads `typeof failed.code === "string"`.
            $public = get_object_vars($error);
            $out = ['link' => $link, 'emailed' => false, 'mailError' => $error->getMessage()];
            if (is_string($public['code'] ?? null)) {
                $out['mailCode'] = $public['code'];
                $out['mailParams'] = Json::object(is_array($public['params'] ?? null) ? $public['params'] : []);
            }
            return $out;
        }
    }

    /**
     * Emails a sign-in link to an account held up by others' failed tries, at
     * most once a minute. Only to the install's own address, never the Host of
     * the request, so without one known there is no link.
     *
     * @param User $user
     */
    private function sendLink(array $user, string $next): bool
    {
        $origin = $this->homeOrigin();
        if ($origin === null || $origin === '') {
            return false;
        }
        $key = self::LINK_SENT . $user['id'];
        if ($this->now() - Js::number($this->store->setting($key) ?? 0) < 60_000) {
            return true;
        }
        $this->store->setSetting($key, (string) $this->now());
        $link = "$origin$this->base/login/link?" . (new SearchParams(['ticket' => $this->accounts->linkFor($user, $this->now()), 'next' => $next]))->toString();
        $host = (new Url($origin))->host();
        $this->rl->sendMail([
            'to' => $user['email'],
            'subject' => 'Sign in to Runlight',
            'text' => "Someone, most likely you, signed in to Runlight at $host with your password while your account was held up by too many failed tries.\n\nSign in with this link within fifteen minutes:\n$link\n\nIf this was not you, change your password, since someone knows it.\n",
            'html' => "<div style=\"font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111827;max-width:480px\"><p>Someone, most likely you, signed in to Runlight at " . self::esc($host) . ' with your password while your account was held up by too many failed tries.</p><p><a href="' . self::esc($link) . '" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#111827;color:#ffffff;text-decoration:none;font-weight:600">Sign in</a></p><p style="color:#6b7280;font-size:13px">The link works for fifteen minutes. If this was not you, change your password, since someone knows it.</p></div>',
        ]);
        return true;
    }

    /** @param array{ip?: string} $context */
    private function pages(Request $request, string $path, array $context): ?Response
    {
        $url = new Url($request->url);
        $query = $url->searchParams();
        $method = $request->method;
        $base = $this->base;
        if ($path === '/auth.css') {
            return new Response(Pages::AUTH_CSS, 200, ['content-type' => 'text/css; charset=utf-8', 'cache-control' => 'public, max-age=3600']);
        }
        if ($path === '/auth.js') {
            return new Response(Pages::AUTH_JS, 200, ['content-type' => 'application/javascript; charset=utf-8', 'cache-control' => 'public, max-age=3600']);
        }

        if ($path === '/setup') {
            if ($this->hasAccount()) {
                return self::redirect("$base/login");
            }
            if ($method === 'GET') {
                $code = $query->get('code') ?? '';
                if ($this->first === 'locked') {
                    return $this->setupLocked();
                }
                // The app's token is typed in; the server's code comes in the link it printed.
                if ($this->asksForToken || $this->first === 'open') {
                    return self::html(Pages::setupPage($base, ['code' => '', 'askCode' => $this->asksForToken]));
                }
                return $this->setupOk($code) ? self::html(Pages::setupPage($base, ['code' => $code])) : $this->setupLocked();
            }
            if ($method === 'POST') {
                $form = new SearchParams($request->text());
                $code = $form->get('code') ?? '';
                if (!$this->setupOk($code)) {
                    if ($this->asksForToken) {
                        return self::html(Pages::setupPage($base, ['code' => '', 'askCode' => true, 'error' => "That is not this app's RUNLIGHT_TOKEN.", 'email' => $form->get('email') ?? '']), 403);
                    }
                    return $this->setupLocked();
                }
                $again = fn (string $error): array => ['code' => $this->asksForToken ? '' : $code, 'askCode' => $this->asksForToken, 'error' => $error, 'email' => $form->get('email') ?? ''];
                // Asked twice, since a typo here would lock the first owner out.
                if (($form->get('password') ?? '') !== ($form->get('again') ?? '')) {
                    return self::html(Pages::setupPage($base, $again('The two passwords are not the same.')), 400);
                }
                try {
                    $user = $this->accounts->setPassword($form->get('email') ?? '', $form->get('password') ?? '', $this->now());
                    $this->existing = true;
                    return self::redirect($this->homePath, ['set-cookie' => $this->sessionCookie($request, $this->accounts->sessionFor($user, $this->now()), intdiv(Accounts::SESSION_MS, 1000))]);
                } catch (\RangeException $error) {
                    return self::html(Pages::setupPage($base, $again($error->getMessage())), 400);
                }
            }
        }

        if ($path === '/login') {
            if (!$this->hasAccount()) {
                if ($this->first === 'locked') {
                    return $this->setupLocked();
                }
                return $this->first === 'open' || $this->asksForToken ? self::redirect("$base/setup") : $this->setupLocked();
            }
            if ($method === 'GET') {
                return self::html(Pages::loginPage($base, ['next' => $this->safeNext($query->get('next')), 'forgot' => $this->forgot]));
            }
            if ($method === 'POST') {
                return $this->login($request, $context);
            }
        }

        // The link a locked account's owner is emailed: the code step with two-factor on, else straight in.
        if ($path === '/login/link' && $method === 'GET') {
            $next = $this->safeNext($query->get('next'));
            $user = $this->accounts->fromLink($query->get('ticket') ?? '', $this->now());
            if ($user === null) {
                return self::html(Pages::loginPage($base, ['error' => 'That sign-in link has run out. Sign in again.', 'next' => $next, 'forgot' => $this->forgot]), 410);
            }
            if ($user['twoFactor']) {
                return self::html(Pages::codePage($base, ['pending' => $this->accounts->pendingFor($user, $this->now()), 'next' => $next]));
            }
            return $this->signedInTo($request, $user, $next);
        }

        if ($path === '/login/code' && $method === 'POST') {
            $form = new SearchParams($request->text());
            $next = $this->safeNext($form->get('next'));
            $pending = $this->accounts->fromPending($form->get('pending') ?? '', $this->now());
            if ($pending === null) {
                return self::redirect("$base/login?next=" . Js::encodeURIComponent($next));
            }
            ['user' => $user, 'real' => $real] = $pending;
            // Counted before the check, so a burst cannot get past five.
            if (!$this->codeTries->take($user['id'], $this->now())) {
                return self::html(Pages::codePage($base, ['pending' => $form->get('pending') ?? '', 'next' => $next, 'error' => 'Too many tries. Wait fifteen minutes and try again.']), 429);
            }
            if (!$real || !$this->accounts->checkSecondFactor($user['id'], $form->get('code') ?? '', $this->now())) {
                return self::html(Pages::codePage($base, ['pending' => $form->get('pending') ?? '', 'next' => $next, 'error' => 'That code is not right. Check the time on your phone, or use a recovery code.']), 401);
            }
            $this->codeTries->clear($user['id']);
            return $this->signedInTo($request, $user, $next);
        }

        if ($path === '/logout') {
            return self::redirect("$base/login", ['set-cookie' => $this->sessionCookie($request, '', 0)]);
        }

        if ($path === '/invite') {
            if ($method === 'GET') {
                $code = $query->get('code') ?? '';
                $invite = $this->accounts->inviteByCode($code, $this->now());
                return $invite !== null
                    ? self::html(Pages::invitePage($base, ['code' => $code, 'email' => $invite['email'], 'role' => $invite['role'], 'host' => $url->host()]))
                    : self::html(Pages::inviteGonePage($base), 410);
            }
            if ($method === 'POST') {
                $form = new SearchParams($request->text());
                $code = $form->get('code') ?? '';
                $invite = $this->accounts->inviteByCode($code, $this->now());
                if ($invite === null) {
                    return self::html(Pages::inviteGonePage($base), 410);
                }
                $again = static fn (string $error): Response => self::html(Pages::invitePage($base, ['code' => $code, 'email' => $invite['email'], 'role' => $invite['role'], 'host' => $url->host(), 'error' => $error]), 400);
                if (($form->get('password') ?? '') !== ($form->get('again') ?? '')) {
                    return $again('The two passwords are not the same.');
                }
                try {
                    $user = $this->accounts->acceptInvite($code, $form->get('password') ?? '', $this->now());
                    $this->existing = true;
                    return self::redirect($this->homePath, ['set-cookie' => $this->sessionCookie($request, $this->accounts->sessionFor($user, $this->now()), intdiv(Accounts::SESSION_MS, 1000))]);
                } catch (\RangeException $error) {
                    return $again($error->getMessage());
                }
            }
        }
        return null;
    }

    /** @param array{ip?: string} $context */
    private function login(Request $request, array $context): Response
    {
        $base = $this->base;
        $form = new SearchParams($request->text());
        $email = $form->get('email') ?? '';
        $password = $form->get('password') ?? '';
        $next = $this->safeNext($form->get('next'));
        $account = Js::lower(Js::trim($email));
        $ip = $this->rl->clientIp($request, $context);
        $pair = "$account\n" . ($ip !== '' ? $ip : 'unknown');
        $login = fn (array $opts): string => Pages::loginPage($base, $opts + ['next' => $next, 'forgot' => $this->forgot]);
        $tooMany = static fn (): Response => self::html($login(['error' => 'Too many tries. Wait fifteen minutes and try again.', 'email' => $email]), 429);
        if (!$this->perAddress->take($pair, $this->now())) {
            return $tooMany();
        }
        // A browser that signed in to the account before is never held up by others' failures.
        $known = $this->accounts->byEmail($account);
        $trusted = $known !== null && $this->accounts->trustsDevice(self::readCookie($request, self::DEVICE_COOKIE), $known);
        $over = !$trusted && !$this->perAccount->take($account, $this->now());
        // Past the account's limit, a right password and a wrong one get the same answer, so guessing from many
        // addresses learns nothing, and the owner still gets in. With two-factor on, both reach the code step,
        // where a wrong password's ticket never passes. Without it, a right password emails a sign-in link.
        if ($over && !($known['twoFactor'] ?? false)) {
            $home = $this->homeOrigin();
            if (!$this->rl->mailSettings() || $home === null || $home === '') {
                return $tooMany();
            }
            $user = $this->accounts->signIn($email, $password);
            if ($user !== null) {
                try {
                    $this->sendLink($user, $next);
                } catch (\Throwable $error) {
                    error_log('Runlight: could not send a sign-in link ' . $error->getMessage());
                }
            }
            return self::html($login(['error' => 'Too many tries for this account. If the password was right, a link to sign in is on its way to its email address.', 'email' => $email]), 429);
        }
        $user = $this->accounts->signIn($email, $password);
        if ($user === null) {
            if ($over && $known !== null) {
                return self::html(Pages::codePage($base, ['pending' => $this->accounts->decoyFor($known, $this->now()), 'next' => $next]));
            }
            return self::html($login(['error' => 'That email and password do not match an account.', 'email' => $email]), 401);
        }
        $this->perAddress->clear($pair);
        if (!$over && !$trusted) {
            $this->perAccount->forgive($account);
        }
        // With two-factor on, the password only earns the second step.
        if ($user['twoFactor']) {
            return self::html(Pages::codePage($base, ['pending' => $this->accounts->pendingFor($user, $this->now()), 'next' => $next]));
        }
        return $this->signedInTo($request, $user, $next);
    }

    /** Your own account, and for the owner and admins, everyone else's. */
    private function api(Request $request, string $path): Response
    {
        $user = $this->signedIn($request);
        if ($user === null) {
            return self::coded('Sign in first', 'sign_in', 401);
        }
        $now = $this->now();
        $method = $request->method;
        // Writes must be JSON, which a form on another page cannot send, even those with no body.
        if ($method === 'POST' && self::mediaType($request) !== 'application/json') {
            return self::coded('Send JSON', 'send_json', 415);
        }
        if ($path === '/api/account' && $method === 'GET') {
            return self::reply(['account' => self::person($user)]);
        }
        $recheck = function (\stdClass $input, string $field, array $wrong) use ($user, $now): ?Response {
            if (!$this->rechecks->take($user['id'], $now)) {
                return self::coded('Too many tries. Wait fifteen minutes and try again.', 'too_many_tries', 429);
            }
            if ($this->accounts->signIn($user['email'], self::field($input, $field)) === null) {
                return self::coded($wrong[0], $wrong[1], 400);
            }
            $this->rechecks->forgive($user['id']);
            return null;
        };
        $fresh = fn (array $updated): array => ['set-cookie' => $this->sessionCookie($request, $this->accounts->sessionFor($updated, $now), intdiv(Accounts::SESSION_MS, 1000))];
        if ($path === '/api/account/password' && $method === 'POST') {
            $input = self::body($request);
            if ($input === null) {
                return self::coded('Send JSON', 'send_json', 415);
            }
            $refused = $recheck($input, 'current', ['Your current password is not right', 'password_current_wrong']);
            if ($refused !== null) {
                return $refused;
            }
            try {
                $updated = $this->accounts->setPassword($user['email'], self::field($input, 'next'), $now);
                // The new password ends every other sign-in; this browser gets a fresh one.
                return self::reply(['ok' => true], 200, $fresh($updated));
            } catch (AccountError $error) {
                return self::coded($error->getMessage(), $error->code, 400, $error->params);
            }
        }
        // Two-factor: turning it on, confirming the first code, new recovery codes, and turning it off.
        // Each change asks for the password again, so a browser left signed in cannot quietly change it.
        if (str_starts_with($path, '/api/account/2fa') && $method === 'POST') {
            $input = self::body($request);
            if ($input === null) {
                return self::coded('Send JSON', 'send_json', 415);
            }
            $action = substr($path, strlen('/api/account/2fa'));
            // Confirming asks for no password, so it has its own few tries, after which the set-up starts again.
            if ($action === '/confirm') {
                if (!$this->confirmTries->take($user['id'], $now)) {
                    $this->accounts->cancelTwoFactorSetup($user['id']);
                    return self::coded('Too many wrong codes. Start turning on two-factor sign-in again.', 'twofactor_restart', 429);
                }
                $codes = $this->accounts->confirmTwoFactor($user['id'], (string) preg_replace('/[' . Js::SPACE . ']/u', '', self::field($input, 'code')), $now);
                if ($codes === null) {
                    return self::coded('That code is not right. Check the time on your phone and try the next one.', 'code_wrong', 400);
                }
                $this->confirmTries->clear($user['id']);
                // Turning it on signs out every other browser; this one gets a new session.
                $updated = $this->accounts->byId($user['id']);
                return self::reply(['recovery' => $codes], 200, $fresh($updated));
            }
            $refused = $recheck($input, 'password', ['Your password is not right', 'password_wrong']);
            if ($refused !== null) {
                return $refused;
            }
            if ($action === '/start') {
                $this->confirmTries->clear($user['id']);
                $secret = $this->accounts->startTwoFactor($user['id']);
                return self::reply(['secret' => $secret, 'uri' => Crypto::otpauthUri($secret, $user['email'], (new Url($request->url))->host())]);
            }
            if ($action === '/recovery') {
                if (!$user['twoFactor']) {
                    return self::coded('Turn on two-factor sign-in first', 'twofactor_off', 400);
                }
                return self::reply(['recovery' => $this->accounts->newRecoveryCodes($user['id'])]);
            }
            if ($action === '/disable') {
                $this->accounts->disableTwoFactor($user['id']);
                // Sessions follow two-factor's state, so this browser gets a new one and stays signed in.
                $updated = $this->accounts->byId($user['id']);
                return self::reply(['ok' => true], 200, $fresh($updated));
            }
            return self::coded('Not found', 'not_found', 404);
        }
        if ($user['role'] !== 'owner' && $user['role'] !== 'admin') {
            return self::coded('Only the owner or an admin can manage people', 'people_owner', 403);
        }
        // The owner or an admin can turn off someone else's two-factor, for a coworker who lost both phone and recovery
        // codes, though never the owner's. It asks for their password like every other two-factor change, and their own
        // goes through Account.
        if (preg_match('/^\/api\/people\/([a-f0-9]{24})\/2fa$/D', $path, $reset) && $method === 'DELETE') {
            if ($reset[1] === $user['id']) {
                return self::coded('Turn off your own two-factor sign-in under Account', 'twofactor_self', 400);
            }
            $input = self::body($request);
            if ($input === null) {
                return self::coded('Send JSON', 'send_json', 415);
            }
            $refused = $recheck($input, 'password', ['Your password is not right', 'password_wrong']);
            if ($refused !== null) {
                return $refused;
            }
            $target = $this->accounts->byId($reset[1]);
            if ($target === null) {
                return self::coded('Unknown account', 'unknown_account', 404);
            }
            if ($target['role'] === 'owner') {
                return self::coded("Only the owner can change the owner's account", 'owner_protected', 403);
            }
            $this->accounts->disableTwoFactor($reset[1]);
            return self::reply(['ok' => true]);
        }
        // The owner hands ownership to an admin and becomes an admin, after typing their password again.
        if (preg_match('/^\/api\/people\/([a-f0-9]{24})\/owner$/D', $path, $handOver) && $method === 'POST') {
            if ($user['role'] !== 'owner') {
                return self::coded('Only the owner can hand over ownership', 'owner_hand_over', 403);
            }
            $input = self::body($request);
            if ($input === null) {
                return self::coded('Send JSON', 'send_json', 415);
            }
            $refused = $recheck($input, 'password', ['Your password is not right', 'password_wrong']);
            if ($refused !== null) {
                return $refused;
            }
            try {
                $this->accounts->handOver($user['id'], $handOver[1]);
                return self::reply(['people' => array_map(self::person(...), $this->accounts->list())]);
            } catch (AccountError $error) {
                return self::coded($error->getMessage(), $error->code, $error->code === 'unknown_account' ? 404 : 400, $error->params);
            }
        }
        // Nobody is invited as, or made, the owner: there is one, and they hand it over themselves.
        $roleOf = static fn (mixed $value): ?string => $value === 'admin' || $value === 'member' || $value === 'viewer' ? $value : null;
        if ($path === '/api/people' && $method === 'GET') {
            return self::reply(['people' => array_map(self::person(...), $this->accounts->list()), 'invites' => array_map(self::inviteView(...), $this->accounts->invites($now))]);
        }
        if ($path === '/api/people' && $method === 'POST') {
            $input = self::body($request);
            if ($input === null) {
                return self::coded('Send JSON', 'send_json', 415);
            }
            $role = $roleOf(Js::get($input, 'role'));
            if ($role === null) {
                return self::coded('Pick admin, member, or viewer', 'role_needed', 400);
            }
            $email = Js::lower(Js::trim(self::field($input, 'email')));
            if ($this->accounts->byEmail($email) !== null) {
                return self::coded("$email already has an account", 'account_exists', 409, ['email' => $email]);
            }
            try {
                ['invite' => $invite, 'code' => $code] = $this->accounts->invite($email, $role, $user['email'], $now);
                return self::reply(['invite' => self::inviteView($invite)] + $this->sendInvite($request, $invite, $code), 201);
            } catch (AccountError $error) {
                return self::coded($error->getMessage(), $error->code, 400, $error->params);
            }
        }
        if (preg_match('/^\/api\/invites\/([a-f0-9]{24})(\/resend)?$/D', $path, $inviteMatch)) {
            $resend = ($inviteMatch[2] ?? '') !== '';
            if ($method === 'DELETE' && !$resend) {
                return $this->accounts->cancelInvite($inviteMatch[1]) ? self::reply(['ok' => true]) : self::coded('Unknown invite', 'unknown_invite', 404);
            }
            if ($method === 'POST' && $resend) {
                $old = null;
                foreach ($this->accounts->invites($now) as $one) {
                    if ($one['id'] === $inviteMatch[1]) {
                        $old = $one;
                        break;
                    }
                }
                if ($old === null) {
                    return self::coded('Unknown invite', 'unknown_invite', 404);
                }
                // A new link replaces the old one, which stops working.
                ['invite' => $invite, 'code' => $code] = $this->accounts->invite($old['email'], $old['role'], $user['email'], $now);
                return self::reply(['invite' => self::inviteView($invite)] + $this->sendInvite($request, $invite, $code));
            }
        }
        if (preg_match('/^\/api\/people\/([a-f0-9]{24})$/D', $path, $match) && ($method === 'PATCH' || $method === 'DELETE')) {
            try {
                if ($method === 'DELETE') {
                    if ($match[1] === $user['id']) {
                        return self::coded('You cannot remove yourself', 'remove_self', 400);
                    }
                    $this->accounts->remove($match[1]);
                    // The tokens they made, and the apps they connected, stop working with them.
                    $this->dropTokensOf($match[1]);
                    return self::reply(['ok' => true]);
                }
                $input = self::body($request);
                if ($input === null) {
                    return self::coded('Send JSON', 'send_json', 415);
                }
                $role = $roleOf(Js::get($input, 'role'));
                if ($role === null) {
                    return self::coded('Pick admin, member, or viewer', 'role_needed', 400);
                }
                $changed = $this->accounts->setRole($match[1], $role);
                // A viewer changes nothing, so the tokens they made before go too.
                if ($role === 'viewer') {
                    $this->dropTokensOf($match[1]);
                }
                return self::reply(['person' => self::person($changed)]);
            } catch (AccountError $error) {
                $status = $error->code === 'unknown_account' ? 404 : ($error->code === 'owner_protected' ? 403 : 400);
                return self::coded($error->getMessage(), $error->code, $status, $error->params);
            }
        }
        return self::coded('Not found', 'not_found', 404);
    }

    /** What a signed-in person may do: everything (owner and admin, true), "member", "read" (viewer), or nothing (false). */
    public function access(Request $request): bool|string
    {
        $user = $this->signedIn($request);
        if ($user === null) {
            return false;
        }
        // A member changes everything but the install-wide controls; a viewer reads every site and changes nothing.
        return $user['role'] === 'owner' || $user['role'] === 'admin' ? true : ($user['role'] === 'member' ? 'member' : 'read');
    }

    public function accountOf(Request $request): ?string
    {
        return $this->signedIn($request)['id'] ?? null;
    }

    /**
     * Notes who made a token. A viewer makes no tokens; someone removed or made a viewer since allowing an app
     * gets none for it, and false takes the token back.
     *
     * @param array{id: string} $token
     */
    public function tokenMade(array $token, string $by): bool
    {
        $role = $this->accounts->byId($by)['role'] ?? null;
        if ($role === null || $role === 'viewer') {
            return false;
        }
        $this->store->setSetting(self::MADE_BY . $token['id'], $by);
        return true;
    }

    /**
     * Answers an account page or API request at a path under the base, or null for anything else.
     *
     * @param array{ip?: string} $context
     */
    public function handle(Request $request, string $path, array $context = []): ?Response
    {
        if ($path === '/api/account' || str_starts_with($path, '/api/account/') || $path === '/api/people' || str_starts_with($path, '/api/people/') || str_starts_with($path, '/api/invites/')) {
            return $this->api($request, $path);
        }
        $page = $this->pages($request, $path, $context);
        if ($page !== null) {
            return $page;
        }
        // The dashboard itself: straight to sign-in, or to setting up the first account.
        if (($path === '/' || $path === '') && $request->method === 'GET' && $this->signedIn($request) === null) {
            if (!$this->hasAccount()) {
                return $this->first === 'open' || $this->asksForToken ? self::redirect("$this->base/setup") : $this->setupLocked();
            }
            $search = (new Url($request->url))->search;
            return self::redirect("$this->base/login" . ($search !== '' ? '?next=' . Js::encodeURIComponent("$this->homePath$search") : ''));
        }
        return null;
    }
}
