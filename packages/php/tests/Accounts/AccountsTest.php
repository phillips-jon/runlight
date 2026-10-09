<?php

declare(strict_types=1);

namespace Runlight\Tests\Accounts;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Accounts\AccountError;
use Runlight\Accounts\Accounts;
use Runlight\Accounts\Crypto;
use Runlight\Accounts\Throttle;
use Runlight\Store\SqlStore;
use Runlight\Tests\Store\Databases;

/** Accounts and the throttle on their own, on every database at hand. */
final class AccountsTest extends TestCase
{
    private const NOW = 1_791_288_000_000;
    private const SECRET = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    protected function tearDown(): void
    {
        Databases::cleanup();
    }

    private static function store(string $kind): SqlStore
    {
        $store = Databases::fresh($kind);
        $store->migrate();
        return $store;
    }

    private static function codeOf(callable $fn): string
    {
        try {
            $fn();
            return '';
        } catch (AccountError $error) {
            return $error->code;
        }
    }

    #[DataProvider('kinds')]
    public function testTheFirstAccountOwnsAndTheRestAreAdminsUnlessAsked(string $kind): void
    {
        $accounts = new Accounts(self::store($kind), self::SECRET);
        $this->assertSame(0, $accounts->count());
        $owner = $accounts->setPassword(' Jon@Example.com ', 'a long password', self::NOW);
        $this->assertSame(['id', 'email', 'hash', 'role', 'createdAt', 'twoFactor', 'recoveryLeft'], array_keys($owner));
        $this->assertSame('jon@example.com', $owner['email']);
        $this->assertSame('owner', $owner['role']);
        $this->assertMatchesRegularExpression('/^[a-f0-9]{24}$/', $owner['id']);
        $admin = $accounts->setPassword('ada@example.com', 'another long one', self::NOW + 1, 'owner');
        $this->assertSame('admin', $admin['role'], 'a server has one owner');
        $this->assertSame(['jon@example.com', 'ada@example.com'], array_column($accounts->list(), 'email'));
        $this->assertSame($owner, $accounts->byId($owner['id']));
        $this->assertSame($owner['id'], $accounts->signIn('JON@example.com', 'a long password')['id']);
        $this->assertNull($accounts->signIn('jon@example.com', 'a wrong password'));
        $this->assertNull($accounts->signIn('nobody@example.com', 'a long password'));

        $this->assertSame('email_invalid', self::codeOf(fn () => $accounts->setPassword('not an email', 'a long password', self::NOW)));
        try {
            $accounts->setPassword('x@example.com', 'short', self::NOW);
            $this->fail('a short password is refused');
        } catch (AccountError $error) {
            $this->assertSame('password_short', $error->code);
            $this->assertSame(['min' => '10'], $error->params);
            $this->assertSame('Use a password of at least 10 characters', $error->getMessage());
            $this->assertInstanceOf(\RangeException::class, $error, 'a RangeError in TypeScript');
        }
    }

    #[DataProvider('kinds')]
    public function testRolesHandingOverAndRemoving(string $kind): void
    {
        $accounts = new Accounts(self::store($kind), self::SECRET);
        $owner = $accounts->setPassword('jon@example.com', 'a long password', self::NOW);
        $admin = $accounts->setPassword('ada@example.com', 'a long password', self::NOW + 1);
        $this->assertSame('owner_protected', self::codeOf(fn () => $accounts->setRole($owner['id'], 'admin')));
        $this->assertSame('owner_hand_over', self::codeOf(fn () => $accounts->setRole($admin['id'], 'owner')));
        $this->assertSame('unknown_account', self::codeOf(fn () => $accounts->setRole(str_repeat('a', 24), 'viewer')));
        $member = $accounts->setRole($admin['id'], 'member');
        $this->assertSame(array_keys($admin), array_keys($member), 'the role changes in place');
        $this->assertSame('member', $member['role']);
        $this->assertSame('owner_needs_admin', self::codeOf(fn () => $accounts->handOver($owner['id'], $admin['id'])));
        $this->assertSame('owner_hand_over', self::codeOf(fn () => $accounts->handOver($admin['id'], $owner['id'])));
        $accounts->setRole($admin['id'], 'admin');
        $accounts->handOver($owner['id'], $admin['id']);
        $this->assertSame('admin', $accounts->byId($owner['id'])['role']);
        $this->assertSame('owner', $accounts->byId($admin['id'])['role']);
        $this->assertSame('owner_protected', self::codeOf(fn () => $accounts->remove($admin['id'])));
        $accounts->remove($owner['id']);
        $this->assertNull($accounts->byId($owner['id']));
        $this->assertSame('unknown_account', self::codeOf(fn () => $accounts->remove($owner['id'])));
    }

    #[DataProvider('kinds')]
    public function testInvitesWorkOnceAndTheNewestLinkWins(string $kind): void
    {
        $accounts = new Accounts(self::store($kind), self::SECRET);
        $accounts->setPassword('jon@example.com', 'a long password', self::NOW);
        ['invite' => $first, 'code' => $old] = $accounts->invite(' Mo@Example.com', 'member', 'jon@example.com', self::NOW);
        $this->assertSame(['id', 'email', 'role', 'invitedBy', 'createdAt', 'expiresAt'], array_keys($first));
        $this->assertSame('mo@example.com', $first['email']);
        $this->assertSame(self::NOW + Accounts::INVITE_MS, $first['expiresAt']);
        $this->assertMatchesRegularExpression('/^[A-Za-z0-9_-]{32}$/', $old);
        ['invite' => $second, 'code' => $code] = $accounts->invite('mo@example.com', 'viewer', 'jon@example.com', self::NOW + 5);
        $this->assertNull($accounts->inviteByCode($old, self::NOW + 10), 'asking again replaces the earlier invite');
        $this->assertSame($second, $accounts->inviteByCode($code, self::NOW + 10));
        $this->assertSame([$second], $accounts->invites(self::NOW + 10));
        $this->assertNull($accounts->inviteByCode('short', self::NOW));
        $this->assertNull($accounts->inviteByCode($code, self::NOW + 5 + Accounts::INVITE_MS), 'an invite runs out');
        try {
            $accounts->invite('jon@example.com', 'admin', 'jon@example.com', self::NOW);
            $this->fail('someone with an account is not invited');
        } catch (AccountError $error) {
            $this->assertSame('account_exists', $error->code);
            $this->assertSame(['email' => 'jon@example.com'], $error->params);
        }
        $user = $accounts->acceptInvite($code, 'another long one', self::NOW + 20);
        $this->assertSame('viewer', $user['role']);
        $this->assertSame([], $accounts->invites(self::NOW + 20));
        $this->assertSame('invite_gone', self::codeOf(fn () => $accounts->acceptInvite($code, 'another long one', self::NOW + 30)), 'an invite works once');
        ['invite' => $third] = $accounts->invite('zed@example.com', 'admin', 'jon@example.com', self::NOW);
        $this->assertTrue($accounts->cancelInvite($third['id']));
        $this->assertFalse($accounts->cancelInvite($third['id']));
        $accounts->invite('old@example.com', 'admin', 'jon@example.com', self::NOW);
        $this->assertSame([], $accounts->invites(self::NOW + Accounts::INVITE_MS), 'expired invites are cleared on the way');
    }

    #[DataProvider('kinds')]
    public function testSessionsTicketsAndDevicesAreSignedAndEndWithTheirPassword(string $kind): void
    {
        $accounts = new Accounts(self::store($kind), self::SECRET);
        $user = $accounts->setPassword('jon@example.com', 'a long password', self::NOW);
        $session = $accounts->sessionFor($user, self::NOW);
        [$id, $expires, $signature] = explode('.', $session);
        $this->assertSame($user['id'], $id);
        $this->assertSame((string) (self::NOW + Accounts::SESSION_MS), $expires);
        $this->assertSame(Crypto::signature(self::SECRET, "$id.$expires", $user['hash']), $signature, 'signed as TypeScript signs it');
        $this->assertSame($user, $accounts->fromSession($session, self::NOW + 1));
        $this->assertNull($accounts->fromSession($session, self::NOW + Accounts::SESSION_MS), 'a session runs out');
        $this->assertNull($accounts->fromSession("$id.$expires.x", self::NOW));
        $this->assertNull($accounts->fromSession('', self::NOW));
        $this->assertNull($accounts->fromSession("$id.later.$signature", self::NOW));

        $pending = $accounts->pendingFor($user, self::NOW);
        $this->assertSame(['user' => $user, 'real' => true], $accounts->fromPending($pending, self::NOW));
        $this->assertSame(['user' => $user, 'real' => false], $accounts->fromPending($accounts->decoyFor($user, self::NOW), self::NOW));
        $this->assertNull($accounts->fromPending($session, self::NOW), 'a session is not a code-step ticket');
        $this->assertNull($accounts->fromPending($pending, self::NOW + 5 * 60_000));

        $device = $accounts->deviceFor($user);
        $this->assertTrue($accounts->trustsDevice($device, $user));
        $this->assertFalse($accounts->trustsDevice('', $user));

        $link = $accounts->linkFor($user, self::NOW);
        $earlier = $accounts->linkFor($user, self::NOW - 1000);
        $this->assertSame($user, $accounts->fromLink($link, self::NOW + 1));
        $this->assertNull($accounts->fromLink($link, self::NOW + 2), 'a link works once');
        $this->assertNull($accounts->fromLink($earlier, self::NOW + 2), 'and withdraws every link sent before it');

        $changed = $accounts->setPassword('jon@example.com', 'a new long password', self::NOW);
        $this->assertNull($accounts->fromSession($session, self::NOW + 1), 'a new password signs out every other browser');
        $this->assertFalse($accounts->trustsDevice($device, $changed));
        $this->assertNotNull($accounts->fromSession($accounts->sessionFor($changed, self::NOW), self::NOW + 1));
    }

    #[DataProvider('kinds')]
    public function testTwoFactorCodesWorkOnceAndRecoveryCodesAreCrossedOff(string $kind): void
    {
        $accounts = new Accounts(self::store($kind), self::SECRET);
        $user = $accounts->setPassword('jon@example.com', 'a long password', self::NOW);
        $secret = $accounts->startTwoFactor($user['id']);
        $this->assertMatchesRegularExpression('/^[A-Z2-7]{32}$/', $secret);
        $step = intdiv(self::NOW, 30_000);
        $wrong = Crypto::totp($secret, $step) === '000000' ? '111111' : '000000';
        $this->assertNull($accounts->confirmTwoFactor($user['id'], $wrong, self::NOW));
        $recovery = $accounts->confirmTwoFactor($user['id'], Crypto::totp($secret, $step), self::NOW);
        $this->assertCount(10, $recovery);
        $this->assertMatchesRegularExpression('/^[a-z2-7]{4}-[a-z2-7]{4}$/', $recovery[0]);
        $on = $accounts->byId($user['id']);
        $this->assertTrue($on['twoFactor']);
        $this->assertSame(10, $on['recoveryLeft']);
        $this->assertNull($accounts->fromSession($accounts->sessionFor($user, self::NOW), self::NOW), 'turning two-factor on ends other sessions');

        // The code that turned it on still signs in, once.
        $this->assertTrue($accounts->checkSecondFactor($user['id'], ' ' . Crypto::totp($secret, $step) . ' ', self::NOW));
        $this->assertFalse($accounts->checkSecondFactor($user['id'], Crypto::totp($secret, $step), self::NOW), 'a code works once');
        $this->assertFalse($accounts->checkSecondFactor($user['id'], Crypto::totp($secret, $step - 1), self::NOW), 'and an older one never');
        $this->assertTrue($accounts->checkSecondFactor($user['id'], Crypto::totp($secret, $step + 1), self::NOW), 'one step ahead, for a clock that drifts');
        $this->assertTrue($accounts->checkSecondFactor($user['id'], strtoupper(str_replace('-', '', $recovery[3])), self::NOW));
        $this->assertFalse($accounts->checkSecondFactor($user['id'], $recovery[3], self::NOW), 'a recovery code is crossed off');
        $this->assertSame(9, $accounts->byId($user['id'])['recoveryLeft']);
        $fresh = $accounts->newRecoveryCodes($user['id']);
        $this->assertFalse($accounts->checkSecondFactor($user['id'], $recovery[0], self::NOW));
        $this->assertTrue($accounts->checkSecondFactor($user['id'], $fresh[0], self::NOW));
        $accounts->disableTwoFactor($user['id']);
        $this->assertFalse($accounts->byId($user['id'])['twoFactor']);
        $this->assertFalse($accounts->checkSecondFactor($user['id'], $fresh[1], self::NOW));

        $accounts->startTwoFactor($user['id']);
        $accounts->cancelTwoFactorSetup($user['id']);
        $this->assertNull($accounts->confirmTwoFactor($user['id'], Crypto::totp($secret, $step), self::NOW), 'a cancelled set-up confirms nothing');
    }

    public function testAnOldTableGainsRolesAndKeepsOneOwner(): void
    {
        $store = self::store('sqlite');
        $store->db->run('CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)');
        $store->db->run("INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)");
        $accounts = new Accounts($store, self::SECRET);
        $this->assertSame([['a', 'owner'], ['b', 'admin']], array_map(static fn (array $u): array => [$u['id'], $u['role']], $accounts->list()));
    }

    public function testTheThrottleCountsBeforeTheCheckAndForgivesARightTry(): void
    {
        $store = self::store('sqlite');
        $throttle = new Throttle($store, 'test', 3, 1000);
        for ($i = 0; $i < 3; $i++) {
            $this->assertTrue($throttle->take('jon@example.com', self::NOW));
        }
        $this->assertTrue($throttle->blocked('jon@example.com', self::NOW));
        $this->assertFalse($throttle->take('jon@example.com', self::NOW), 'at its limit, nothing more is counted');
        $this->assertFalse($throttle->blocked('ada@example.com', self::NOW));
        $throttle->forgive('jon@example.com');
        $this->assertFalse($throttle->blocked('jon@example.com', self::NOW));
        $throttle->fail('jon@example.com', self::NOW);
        $this->assertTrue($throttle->blocked('jon@example.com', self::NOW));
        $this->assertFalse($throttle->blocked('jon@example.com', self::NOW + 1000), 'a window ends');
        $throttle->clear('jon@example.com');
        $this->assertFalse($throttle->blocked('jon@example.com', self::NOW));
        foreach ($store->settingsStartingWith('throttle:') as ['key' => $key]) {
            $this->assertStringNotContainsString('jon', $key, 'keys are hashed, never kept as given');
        }
        $this->assertFalse((new Throttle($store, 'other', 3, 1000))->blocked('jon@example.com', self::NOW), 'each throttle counts on its own');
        // Another request, with a throttle of its own, sees the same counts.
        $throttle->fail('ada@example.com', self::NOW);
        $throttle->fail('ada@example.com', self::NOW);
        $throttle->fail('ada@example.com', self::NOW);
        $this->assertTrue((new Throttle($store, 'test', 3, 1000))->blocked('ada@example.com', self::NOW));
        // A new entry clears expired ones.
        $throttle->fail('zed@example.com', self::NOW + 2000);
        $this->assertCount(1, $store->settingsStartingWith('throttle:test:'));
    }
}
