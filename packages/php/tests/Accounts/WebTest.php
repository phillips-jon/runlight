<?php

declare(strict_types=1);

namespace Runlight\Tests\Accounts;

use PHPUnit\Framework\TestCase;
use Runlight\Accounts\Accounts;
use Runlight\Accounts\Crypto;
use Runlight\Accounts\Pages;
use Runlight\Accounts\Web;
use Runlight\Http\Request;
use Runlight\Http\Response;
use Runlight\Http\SearchParams;
use Runlight\Http\Url;
use Runlight\Json;
use Runlight\Mail\MailError;
use Runlight\Store\Stores;

/**
 * Accounts on the web, through Web::handle() as the routes call it, with a stand-in for the Runlight. The
 * cases follow accounts.test.ts and the accounts conformance scenario; the same flows through the real routes
 * are in RoutesAccountsTest, which runs once the core is here.
 */
final class WebTest extends TestCase
{
    private const NOW = 1_791_288_000_000;
    private const BASE = '/runlight';

    private int $now = self::NOW;
    private StandIn $rl;

    /** @param 'open'|'locked'|array{code: string}|array{token: string} $first */
    private function web(string|array $first = ['token' => 'app-token'], ?string $home = null): Web
    {
        $store = Stores::sqlite(':memory:');
        $store->migrate();
        $this->rl = new StandIn($store);
        return new Web([
            'runlight' => $this->rl,
            'secret' => str_repeat('k', 64),
            'base' => self::BASE,
            'now' => fn (): int => $this->now,
            'firstAccount' => $first,
            'forgot' => 'https://runlight.sh/docs/configuration/#accounts',
        ] + ($home === null ? [] : ['home' => static fn (): ?string => $home]));
    }

    /** @param array<string, string> $headers */
    private static function req(string $path, string $method = 'GET', array $headers = [], string $body = ''): Request
    {
        return new Request("https://example.com/runlight$path", $method, $headers, $body);
    }

    /** @param array<string, string> $fields */
    private static function form(string $path, array $fields, string $cookie = ''): Request
    {
        return self::req($path, 'POST', ['content-type' => 'application/x-www-form-urlencoded'] + ($cookie !== '' ? ['cookie' => $cookie] : []), (new SearchParams($fields))->toString());
    }

    private static function json(string $cookie, string $method, string $path, mixed $body = null): Request
    {
        return self::req($path, $method, ['cookie' => $cookie, 'content-type' => 'application/json'], $body === null ? '' : Json::encode($body));
    }

    private static function handle(Web $web, Request $request): ?Response
    {
        return $web->handle($request, substr((new Url($request->url))->pathname, strlen(self::BASE)) ?: '/');
    }

    private static function cookieOf(Response $response): string
    {
        return explode(';', $response->headers->getSetCookie()[0] ?? '')[0];
    }

    private function owner(Web $web): string
    {
        $made = self::handle($web, self::form('/setup', ['code' => 'app-token', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
        return self::cookieOf($made);
    }

    public function testAnAppMakesItsFirstAccountWithItsToken(): void
    {
        $web = $this->web();
        $start = self::handle($web, self::req('/'));
        $this->assertSame(303, $start->status);
        $this->assertSame('/runlight/setup', $start->headers->get('location'));
        $this->assertSame('no-store', $start->headers->get('cache-control'));
        $page = self::handle($web, self::req('/setup'));
        $this->assertSame(Pages::setupPage(self::BASE, ['code' => '', 'askCode' => true]), $page->text());
        $this->assertSame("default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'", $page->headers->get('content-security-policy'));
        $this->assertMatchesRegularExpression('/href="\/runlight\/auth\.css"/', $page->text());

        $wrong = self::handle($web, self::form('/setup', ['code' => 'guess', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(403, $wrong->status);
        $this->assertSame(Pages::setupPage(self::BASE, ['code' => '', 'askCode' => true, 'error' => "That is not this app's RUNLIGHT_TOKEN.", 'email' => 'jon@example.com']), $wrong->text());
        $typo = self::handle($web, self::form('/setup', ['code' => 'app-token', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long passwore']));
        $this->assertSame(400, $typo->status);
        $this->assertStringContainsString('The two passwords are not the same.', $typo->text());
        $short = self::handle($web, self::form('/setup', ['code' => 'app-token', 'email' => 'jon@example.com', 'password' => 'short', 'again' => 'short']));
        $this->assertSame(400, $short->status);
        $this->assertStringContainsString('Use a password of at least 10 characters', $short->text());

        $made = self::handle($web, self::form('/setup', ['code' => 'app-token', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']));
        $this->assertSame(303, $made->status);
        $this->assertSame('/runlight/', $made->headers->get('location'));
        $cookie = $made->headers->getSetCookie();
        $this->assertCount(1, $cookie);
        $this->assertMatchesRegularExpression('/^runlight_session=[a-f0-9]{24}\.\d+\.[A-Za-z0-9_-]{43}; Path=\/runlight; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure$/', $cookie[0]);
        $this->assertSame('/runlight/login', self::handle($web, self::req('/setup'))->headers->get('location'), 'setup closes once there is an account');

        $owner = self::cookieOf($made);
        $this->assertNull(self::handle($web, self::req('/', 'GET', ['cookie' => $owner])), 'signed in, the dashboard is the routes\' to answer');
        $this->assertTrue($web->access(self::req('/', 'GET', ['cookie' => $owner])));
        $this->assertFalse($web->access(self::req('/')));
        $answer = self::handle($web, self::json($owner, 'GET', '/api/account'));
        $user = $web->accounts->byEmail('jon@example.com');
        $this->assertSame(Json::encode(['account' => ['id' => $user['id'], 'email' => 'jon@example.com', 'role' => 'owner', 'createdAt' => self::NOW, 'twoFactor' => false, 'recoveryLeft' => 0]]), $answer->text());
        $this->assertSame('application/json; charset=utf-8', $answer->headers->get('content-type'));
        $this->assertSame($user['id'], $web->accountOf(self::req('/', 'GET', ['cookie' => $owner])));

        // Signed out, the dashboard sends you to sign in, and keeps where you were going.
        $this->assertSame('/runlight/login?next=%2Frunlight%2F%3Fperiod%3D7d', self::handle($web, self::req('/?period=7d'))->headers->get('location'));
        $this->assertSame('/runlight/login', self::handle($web, self::req('/'))->headers->get('location'));
    }

    public function testAServerCodeOpenAndLockedSetups(): void
    {
        $code = Web::setupCode();
        $this->assertMatchesRegularExpression('/^[A-Za-z0-9_-]{12}$/', $code);
        $web = $this->web(['code' => $code]);
        $this->assertSame(403, self::handle($web, self::req('/'))->status, 'a server with no account and no code in the link stays shut');
        $this->assertSame(Pages::setupLockedPage(self::BASE), self::handle($web, self::req('/setup?code=nope'))->text());
        $this->assertSame(Pages::setupPage(self::BASE, ['code' => $code]), self::handle($web, self::req("/setup?code=$code"))->text());
        $this->assertSame(403, self::handle($web, self::req('/login'))->status);
        $this->assertSame(403, self::handle($web, self::form('/setup', ['code' => 'nope', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']))->status);

        $open = $this->web('open');
        $this->assertSame('/runlight/setup', self::handle($open, self::req('/'))->headers->get('location'));
        $this->assertSame('/runlight/setup', self::handle($open, self::req('/login'))->headers->get('location'));
        $this->assertStringNotContainsString('RUNLIGHT_TOKEN', self::handle($open, self::req('/setup'))->text());
        $this->assertSame(303, self::handle($open, self::form('/setup', ['code' => '', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']))->status);

        $locked = $this->web('locked');
        $shut = self::handle($locked, self::req('/setup'));
        $this->assertSame(403, $shut->status);
        $this->assertStringContainsString('Set RUNLIGHT_TOKEN', $shut->text());
        $this->assertSame(403, self::handle($locked, self::form('/setup', ['code' => '', 'email' => 'jon@example.com', 'password' => 'a long password', 'again' => 'a long password']))->status);

        $css = self::handle($locked, self::req('/auth.css'));
        $this->assertSame(Pages::AUTH_CSS, $css->text());
        $this->assertSame('text/css; charset=utf-8', $css->headers->get('content-type'));
        $this->assertSame('public, max-age=3600', $css->headers->get('cache-control'));
        $this->assertSame('application/javascript; charset=utf-8', self::handle($locked, self::req('/auth.js'))->headers->get('content-type'));
        $this->assertNull(self::handle($locked, self::req('/somewhere')));
    }

    public function testSigningInAndOutNeverLeavesTheApp(): void
    {
        $web = $this->web();
        $this->owner($web);
        $login = self::handle($web, self::req('/login?next=%2Frunlight%2F%3Fsite%3Dx'));
        $this->assertSame(Pages::loginPage(self::BASE, ['next' => '/runlight/?site=x', 'forgot' => 'https://runlight.sh/docs/configuration/#accounts']), $login->text());

        $wrong = self::handle($web, self::form('/login', ['email' => 'jon@example.com', 'password' => 'a wrong password']));
        $this->assertSame(401, $wrong->status);
        $this->assertSame(Pages::loginPage(self::BASE, ['error' => 'That email and password do not match an account.', 'email' => 'jon@example.com', 'next' => '/runlight/', 'forgot' => 'https://runlight.sh/docs/configuration/#accounts']), $wrong->text());

        $back = self::handle($web, self::form('/login', ['email' => 'JON@example.com', 'password' => 'a long password', 'next' => '/runlight/?period=7d']));
        $this->assertSame(303, $back->status);
        $this->assertSame('/runlight/?period=7d', $back->headers->get('location'));
        $cookies = $back->headers->getSetCookie();
        $this->assertCount(2, $cookies, 'a session, and the mark that this browser signed in to the account');
        $this->assertMatchesRegularExpression('/^runlight_device=[a-f0-9]{24}\.[A-Za-z0-9_-]{43}; Path=\/runlight; HttpOnly; SameSite=Lax; Max-Age=31536000; Secure$/', $cookies[1]);

        $out = self::handle($web, self::req('/logout'));
        $this->assertSame('/runlight/login', $out->headers->get('location'));
        $this->assertSame(['runlight_session=; Path=/runlight; HttpOnly; SameSite=Lax; Max-Age=0; Secure'], $out->headers->getSetCookie());

        foreach (['//evil.example/', '/\\evil.example', "/\t/evil.example", 'https://evil.example/', '', 'runlight'] as $next) {
            $this->assertSame('/runlight/', $web->safeNext($next), "never sent off the app: $next");
        }
        $this->assertSame('/runlight/', $web->safeNext(null));
        $this->assertSame('/runlight/x?y=1#z', $web->safeNext('/runlight/a/../x?y=1#z'));
        $this->assertSame('/%20a', $web->safeNext('/ a'));
    }

    public function testInvitesPeopleAndRoles(): void
    {
        $web = $this->web();
        $owner = $this->owner($web);
        $sent = self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'Mo@Example.com', 'role' => 'member']));
        $this->assertSame(201, $sent->status);
        $body = Json::decode($sent->text(), true);
        $this->assertSame(['invite', 'link', 'emailed'], array_keys($body));
        $this->assertFalse($body['emailed'], 'no mail service here, so the link is for passing on');
        $link = new Url($body['link']);
        $this->assertSame('https://example.com', $link->origin());
        $this->assertSame('/runlight/invite', $link->pathname);
        $code = (string) $link->searchParams()->get('code');
        $this->assertStringContainsString('as a member', self::handle($web, self::req("/invite?code=$code"))->text());
        $this->assertSame(410, self::handle($web, self::req('/invite?code=nope'))->status);

        $this->assertSame(409, self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'jon@example.com', 'role' => 'admin']))->status);
        $noRole = self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'x@example.com', 'role' => 'owner']));
        $this->assertSame('{"error":"Pick admin, member, or viewer","code":"role_needed"}', $noRole->text());
        $this->assertSame('nosniff', $noRole->headers->get('x-content-type-options'));
        $badEmail = self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'nobody', 'role' => 'admin']));
        $this->assertSame('{"error":"Enter an email address","code":"email_invalid","params":{}}', $badEmail->text());
        $form = self::handle($web, self::req('/api/people', 'POST', ['cookie' => $owner, 'content-type' => 'text/plain'], '{}'));
        $this->assertSame(415, $form->status, 'a write must be JSON');
        $this->assertSame('{"error":"Sign in first","code":"sign_in"}', self::handle($web, self::req('/api/people'))->text());

        $typo = self::handle($web, self::form('/invite', ['code' => $code, 'password' => 'another long one', 'again' => 'another long two']));
        $this->assertSame(400, $typo->status);
        $joined = self::handle($web, self::form('/invite', ['code' => $code, 'password' => 'another long one', 'again' => 'another long one']));
        $this->assertSame(303, $joined->status);
        $this->assertSame('/runlight/', $joined->headers->get('location'));
        $member = self::cookieOf($joined);
        $this->assertSame('member', $web->access(self::req('/', 'GET', ['cookie' => $member])));
        $this->assertSame(403, self::handle($web, self::json($member, 'GET', '/api/people'))->status);
        $this->assertSame(410, self::handle($web, self::form('/invite', ['code' => $code, 'password' => 'another long one', 'again' => 'another long one']))->status, 'an invite works once');

        // A member's tokens go when they become a viewer.
        $mo = $web->accounts->byEmail('mo@example.com');
        $token = ['id' => str_repeat('b', 24), 'name' => 'Script', 'site' => '', 'scope' => 'read', 'hash' => str_repeat('c', 64), 'hint' => 'abcd', 'createdAt' => self::NOW, 'lastUsedAt' => null];
        $this->rl->store->insertToken($token);
        $this->assertTrue($web->tokenMade($token, $mo['id']));
        $this->assertFalse($web->tokenMade($token, str_repeat('d', 24)), 'nobody by that id makes tokens');
        $changed = self::handle($web, self::json($owner, 'PATCH', "/api/people/{$mo['id']}", ['role' => 'viewer']));
        $this->assertSame(Json::encode(['person' => ['id' => $mo['id'], 'email' => 'mo@example.com', 'role' => 'viewer', 'createdAt' => self::NOW, 'twoFactor' => false, 'recoveryLeft' => 0]]), $changed->text());
        $this->assertSame([], $this->rl->store->tokens());
        $this->assertSame('read', $web->access(self::req('/', 'GET', ['cookie' => $member])));
        $this->assertFalse($web->tokenMade($token, $mo['id']), 'a viewer makes no tokens');

        $jon = $web->accounts->byEmail('jon@example.com');
        $this->assertSame('{"error":"Only the owner can change their own role, by handing ownership to an admin","code":"owner_protected","params":{}}', self::handle($web, self::json($owner, 'PATCH', "/api/people/{$jon['id']}", ['role' => 'admin']))->text());
        $this->assertSame(403, self::handle($web, self::json($owner, 'PATCH', "/api/people/{$jon['id']}", ['role' => 'admin']))->status);
        $this->assertSame(404, self::handle($web, self::json($owner, 'PATCH', '/api/people/' . str_repeat('a', 24), ['role' => 'admin']))->status);
        $this->assertSame('remove_self', Json::decode(self::handle($web, self::json($owner, 'DELETE', "/api/people/{$jon['id']}"))->text(), true)['code']);

        // Invites listed, resent, and cancelled.
        self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'zed@example.com', 'role' => 'viewer']));
        $people = Json::decode(self::handle($web, self::json($owner, 'GET', '/api/people'))->text(), true);
        $this->assertEqualsCanonicalizing(['jon@example.com', 'mo@example.com'], array_column($people['people'], 'email'));
        $this->assertSame(['zed@example.com'], array_column($people['invites'], 'email'));
        $id = $people['invites'][0]['id'];
        $resent = self::handle($web, self::json($owner, 'POST', "/api/invites/$id/resend"));
        $this->assertSame(200, $resent->status);
        $newId = Json::decode($resent->text(), true)['invite']['id'];
        $this->assertNotSame($id, $newId);
        $this->assertSame(404, self::handle($web, self::json($owner, 'DELETE', "/api/invites/$id"))->status);
        $this->assertSame('{"ok":true}', self::handle($web, self::json($owner, 'DELETE', "/api/invites/$newId"))->text());

        $this->assertSame('{"ok":true}', self::handle($web, self::json($owner, 'DELETE', "/api/people/{$mo['id']}"))->text());
        $this->assertNull($web->signedIn(self::req('/', 'GET', ['cookie' => $member])), 'someone removed is signed out');
    }

    public function testInvitesAreEmailedWhenThereIsAMailService(): void
    {
        $web = $this->web(['token' => 'app-token'], 'https://stats.example.com');
        $owner = $this->owner($web);
        $this->rl->mail = ['service' => 'smtp', 'from' => 'runlight@example.com'];
        $body = Json::decode(self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'mo@example.com', 'role' => 'viewer']))->text(), true);
        $this->assertTrue($body['emailed']);
        $this->assertStringStartsWith('https://stats.example.com/runlight/invite?code=', $body['link'], 'the install\'s own address, never the request\'s Host');
        $this->assertSame('jon@example.com invited you to Runlight', $this->rl->sent[0]['subject']);
        $this->assertSame("jon@example.com invited you to the Runlight at stats.example.com as a viewer, who can read every site's stats.\n\nChoose a password to join:\n{$body['link']}\n\nThe link works for seven days.\n", $this->rl->sent[0]['text']);

        $this->rl->mailFails = new MailError('The server refused the password', 'mail_auth', ['host' => 'smtp.example.com']);
        $failed = self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'ada@example.com', 'role' => 'admin']));
        $body = Json::decode($failed->text());
        $this->assertSame(['invite', 'link', 'emailed', 'mailError', 'mailCode', 'mailParams'], array_keys(get_object_vars($body)));
        $this->assertSame('mail_auth', $body->mailCode);
        $this->assertSame(['host' => 'smtp.example.com'], (array) $body->mailParams);
        $this->rl->mailFails = new \RuntimeException('Something else');
        $other = Json::decode(self::handle($web, self::json($owner, 'POST', '/api/people', ['email' => 'zed@example.com', 'role' => 'admin']))->text(), true);
        $this->assertSame(['invite', 'link', 'emailed', 'mailError'], array_keys($other), 'an error without a code of its own has none here');
    }

    public function testTwoFactorThroughTheAccountApiAndTheCodeStep(): void
    {
        $web = $this->web();
        $owner = $this->owner($web);
        $wrong = self::handle($web, self::json($owner, 'POST', '/api/account/2fa/start', ['password' => 'a wrong password']));
        $this->assertSame('{"error":"Your password is not right","code":"password_wrong"}', $wrong->text());
        $start = Json::decode(self::handle($web, self::json($owner, 'POST', '/api/account/2fa/start', ['password' => 'a long password']))->text(), true);
        $this->assertSame(Crypto::otpauthUri($start['secret'], 'jon@example.com', 'example.com'), $start['uri']);
        $this->assertSame('{"error":"Turn on two-factor sign-in first","code":"twofactor_off"}', self::handle($web, self::json($owner, 'POST', '/api/account/2fa/recovery', ['password' => 'a long password']))->text());

        $code = Crypto::totp($start['secret'], intdiv($this->now, 30_000));
        $confirmed = self::handle($web, self::json($owner, 'POST', '/api/account/2fa/confirm', ['code' => substr($code, 0, 3) . ' ' . substr($code, 3)]));
        $this->assertSame(200, $confirmed->status);
        $this->assertCount(10, Json::decode($confirmed->text(), true)['recovery']);
        $this->assertNull($web->signedIn(self::req('/', 'GET', ['cookie' => $owner])), 'turning it on signs out every other browser');
        $owner = self::cookieOf($confirmed);
        $this->assertTrue($web->signedIn(self::req('/', 'GET', ['cookie' => $owner]))['twoFactor']);

        // Signing in now earns only the code step.
        $this->now += 60_000;
        $step = self::handle($web, self::form('/login', ['email' => 'jon@example.com', 'password' => 'a long password', 'next' => '/runlight/?x=1']));
        $this->assertSame(200, $step->status);
        $this->assertSame([], $step->headers->getSetCookie());
        $this->assertSame(1, preg_match('/name="pending" value="([^"]+)"/', $step->text(), $m));
        $pending = html_entity_decode($m[1]);
        $bad = self::handle($web, self::form('/login/code', ['pending' => $pending, 'code' => '12345x', 'next' => '/runlight/?x=1']));
        $this->assertSame(401, $bad->status);
        $this->assertSame(Pages::codePage(self::BASE, ['pending' => $pending, 'next' => '/runlight/?x=1', 'error' => 'That code is not right. Check the time on your phone, or use a recovery code.']), $bad->text());
        $in = self::handle($web, self::form('/login/code', ['pending' => $pending, 'code' => Crypto::totp($start['secret'], intdiv($this->now, 30_000)), 'next' => '/runlight/?x=1']));
        $this->assertSame(303, $in->status);
        $this->assertSame('/runlight/?x=1', $in->headers->get('location'));
        $this->assertSame('/runlight/login?next=%2Frunlight%2F', self::handle($web, self::form('/login/code', ['pending' => 'made.up.ticket', 'code' => '123456']))->headers->get('location'));

        // Turning it off keeps this browser signed in.
        $off = self::handle($web, self::json(self::cookieOf($in), 'POST', '/api/account/2fa/disable', ['password' => 'a long password']));
        $this->assertSame('{"ok":true}', $off->text());
        $this->assertFalse($web->signedIn(self::req('/', 'GET', ['cookie' => self::cookieOf($off)]))['twoFactor']);
        $this->assertSame(404, self::handle($web, self::json(self::cookieOf($off), 'POST', '/api/account/2fa/other', ['password' => 'a long password']))->status);
    }

    public function testConfirmingHasFiveTriesAndThenStartsAgain(): void
    {
        $web = $this->web();
        $owner = $this->owner($web);
        $start = Json::decode(self::handle($web, self::json($owner, 'POST', '/api/account/2fa/start', ['password' => 'a long password']))->text(), true);
        $right = Crypto::totp($start['secret'], intdiv($this->now, 30_000));
        $wrong = $right === '000000' ? '111111' : '000000';
        for ($i = 0; $i < 5; $i++) {
            $this->assertSame('code_wrong', Json::decode(self::handle($web, self::json($owner, 'POST', '/api/account/2fa/confirm', ['code' => $wrong]))->text(), true)['code']);
        }
        $restart = self::handle($web, self::json($owner, 'POST', '/api/account/2fa/confirm', ['code' => $right]));
        $this->assertSame(429, $restart->status);
        $this->assertSame('twofactor_restart', Json::decode($restart->text(), true)['code']);
        $this->assertNull($web->accounts->confirmTwoFactor($web->accounts->byEmail('jon@example.com')['id'], $right, $this->now), 'the set-up was dropped');
        // Starting again with the password opens five more tries.
        $again = Json::decode(self::handle($web, self::json($owner, 'POST', '/api/account/2fa/start', ['password' => 'a long password']))->text(), true);
        $code = Crypto::totp($again['secret'], intdiv($this->now, 30_000));
        $this->assertSame(200, self::handle($web, self::json($owner, 'POST', '/api/account/2fa/confirm', ['code' => $code]))->status);
    }

    public function testPasswordChangesEndOtherSessions(): void
    {
        $web = $this->web();
        $owner = $this->owner($web);
        $this->assertSame('{"error":"Your current password is not right","code":"password_current_wrong"}', self::handle($web, self::json($owner, 'POST', '/api/account/password', ['current' => 'nope', 'next' => 'a newer long one']))->text());
        $short = self::handle($web, self::json($owner, 'POST', '/api/account/password', ['current' => 'a long password', 'next' => 'short']));
        $this->assertSame('{"error":"Use a password of at least 10 characters","code":"password_short","params":{"min":"10"}}', $short->text());
        $changed = self::handle($web, self::json($owner, 'POST', '/api/account/password', ['current' => 'a long password', 'next' => 'a newer long one']));
        $this->assertSame('{"ok":true}', $changed->text());
        $this->assertNull($web->signedIn(self::req('/', 'GET', ['cookie' => $owner])));
        $this->assertNotNull($web->signedIn(self::req('/', 'GET', ['cookie' => self::cookieOf($changed)])));
    }

    public function testTenWrongPasswordsFromOneAddressWait(): void
    {
        $web = $this->web();
        $this->owner($web);
        $headers = ['content-type' => 'application/x-www-form-urlencoded', 'x-forwarded-for' => '203.0.113.9'];
        $body = (new SearchParams(['email' => 'jon@example.com', 'password' => 'a wrong password']))->toString();
        for ($i = 0; $i < 10; $i++) {
            $this->assertSame(401, self::handle($web, self::req('/login', 'POST', $headers, $body))->status);
        }
        $held = self::handle($web, self::req('/login', 'POST', $headers, $body));
        $this->assertSame(429, $held->status);
        $this->assertStringContainsString('Too many tries. Wait fifteen minutes and try again.', $held->text());
        $right = (new SearchParams(['email' => 'jon@example.com', 'password' => 'a long password']))->toString();
        $this->assertSame(429, self::handle($web, self::req('/login', 'POST', $headers, $right))->status, 'even the right password waits');
        $this->assertSame(303, self::handle($web, self::req('/login', 'POST', ['x-forwarded-for' => '203.0.113.10'] + $headers, $right))->status, 'another address is not held up');
        $this->now += 15 * 60_000;
        $this->assertSame(303, self::handle($web, self::req('/login', 'POST', $headers, $right))->status, 'fifteen minutes later');
    }

    public function testAnAccountHeldUpByOthersGetsASignInLink(): void
    {
        $web = $this->web(['token' => 'app-token'], 'https://stats.example.com');
        $this->owner($web);
        $this->rl->mail = ['service' => 'smtp', 'from' => 'runlight@example.com'];
        $accounts = $web->accounts;
        // Fifty failures against the account from fifty addresses, counted as the throttle counts them.
        $throttle = new \Runlight\Accounts\Throttle($this->rl->store, 'account', 50);
        for ($i = 0; $i < 50; $i++) {
            $throttle->fail('jon@example.com', $this->now);
        }
        $held = self::handle($web, self::form('/login', ['email' => 'jon@example.com', 'password' => 'a long password', 'next' => '/runlight/?a=1']));
        $this->assertSame(429, $held->status);
        $this->assertStringContainsString('a link to sign in is on its way', $held->text());
        $this->assertCount(1, $this->rl->sent);
        $this->assertSame('Sign in to Runlight', $this->rl->sent[0]['subject']);
        $this->assertSame(1, preg_match('/(https:\/\/stats\.example\.com\/runlight\/login\/link\?\S+)/', $this->rl->sent[0]['text'], $m));
        $link = new Url($m[1]);
        $this->assertSame('/runlight/?a=1', $link->searchParams()->get('next'));
        self::handle($web, self::form('/login', ['email' => 'jon@example.com', 'password' => 'a long password']));
        $this->assertCount(1, $this->rl->sent, 'at most one link a minute');
        $wrongToo = self::handle($web, self::form('/login', ['email' => 'jon@example.com', 'password' => 'a wrong password']));
        $this->assertSame(429, $wrongToo->status, 'a wrong password gets the same answer');

        $in = self::handle($web, self::req('/login/link' . $link->search));
        $this->assertSame(303, $in->status);
        $this->assertSame('/runlight/?a=1', $in->headers->get('location'));
        $this->assertSame(410, self::handle($web, self::req('/login/link' . $link->search))->status, 'a link works once');
        $this->assertNotNull($accounts->byEmail('jon@example.com'));
    }

    public function testABrokenSessionCookieThrowsAsDecodeURIComponentDoes(): void
    {
        $web = $this->web();
        $this->expectException(\InvalidArgumentException::class);
        $web->signedIn(self::req('/', 'GET', ['cookie' => 'runlight_session=%E0%A4%A']));
    }

    public function testTheSessionCookieIsReadAmongOthers(): void
    {
        $web = $this->web();
        $owner = $this->owner($web);
        $this->assertNotNull($web->signedIn(self::req('/', 'GET', ['cookie' => "a=b; $owner ; c=d=e"])));
        $this->assertSame(Accounts::SESSION_COOKIE, explode('=', $owner)[0]);
        $plain = new Request('http://example.com/runlight/login', 'POST', ['content-type' => 'application/x-www-form-urlencoded'], (new SearchParams(['email' => 'jon@example.com', 'password' => 'a long password']))->toString());
        $this->assertStringNotContainsString('Secure', self::handle($web, $plain)->headers->getSetCookie()[0], 'Secure only over https');
        $proxied = new Request('http://example.com/runlight/logout', 'GET', ['x-forwarded-proto' => 'https']);
        $this->assertStringEndsWith('; Secure', self::handle($web, $proxied)->headers->getSetCookie()[0]);
    }
}
