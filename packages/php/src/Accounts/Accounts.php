<?php

declare(strict_types=1);

namespace Runlight\Accounts;

use Runlight\Js;
use Runlight\Json;
use Runlight\Store\SqlStore;

/**
 * Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
 * signed in. The standalone server always has them, and an app turns them on with routes(['accounts' => true]).
 *
 * The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to an
 * admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and the
 * rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every site's
 * stats and changes nothing.
 *
 * A user is an array with the TypeScript User's keys: id, email, hash, role ("owner", "admin", "member", or
 * "viewer"), createdAt, twoFactor (whether sign-in also asks for a code), and recoveryLeft (recovery codes not
 * yet used). An invite has id, email, role, invitedBy, createdAt, and expiresAt.
 *
 * @phpstan-type User array{id: string, email: string, hash: string, role: string, createdAt: int|float, twoFactor: bool, recoveryLeft: int}
 * @phpstan-type Invite array{id: string, email: string, role: string, invitedBy: string, createdAt: int|float, expiresAt: int|float}
 */
final class Accounts
{
    public const SESSION_COOKIE = 'runlight_session';
    /** Thirty days, renewed on every sign-in. */
    public const SESSION_MS = 30 * 86_400_000;
    public const MIN_PASSWORD = 10;
    /** The most sign-in keys the throttle remembers at once. */
    public const MAX_THROTTLED = 10_000;
    /** How long an invite link works. */
    public const INVITE_MS = 7 * 86_400_000;

    public const ROLES = ['owner', 'admin', 'member', 'viewer'];

    /** What passes for an email address, with JavaScript's \s. */
    private const EMAIL = '/^[^' . Js::SPACE . '@<>"]+@[^' . Js::SPACE . '@<>"]+\.[^' . Js::SPACE . '@<>"]+$/uD';

    /** A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed. */
    private static ?string $decoy = null;

    private bool $ready = false;

    public function __construct(
        private readonly SqlStore $store,
        private readonly string $secret,
    ) {
    }

    /** A stored role read back; anything unknown reads as a viewer, the least it could be. */
    public static function roleFrom(mixed $value): string
    {
        return in_array($value, self::ROLES, true) ? $value : 'viewer';
    }

    /**
     * Changes to who has an account take turns: on Postgres and MySQL across processes, through the database's
     * lock, so two owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
     *
     * @template T
     * @param callable(): T $fn
     * @return T
     */
    private function turn(callable $fn): mixed
    {
        return $this->store->db->exclusive(static fn () => $fn());
    }

    private function init(): void
    {
        if ($this->ready) {
            return;
        }
        // Several processes starting at once create the tables one at a time.
        $this->store->db->exclusive(function (): void {
            $db = $this->store->db;
            // MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's tables use.
            $my = $db->dialect() === 'mysql';
            $str = static fn (int $n): string => $my ? "VARCHAR($n)" : 'TEXT';
            $table = $my ? ' DEFAULT CHARSET=utf8mb4 COLLATE=' . SqlStore::MYSQL_COLLATION : '';
            $db->run('CREATE TABLE IF NOT EXISTS rl_users (id ' . $str(100) . ' PRIMARY KEY, email ' . $str(320) . " NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)$table");
            // Roles came later; a table from before them gains the column, and its accounts stay owners.
            $columns = $db->dialect() === 'sqlite'
                ? $db->all('PRAGMA table_info(rl_users)')
                : $db->all("SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = " . ($my ? 'DATABASE()' : 'current_schema()'));
            $names = array_map(static fn (array $c): string => (string) ($c['name'] ?? $c['NAME'] ?? ''), $columns);
            if (!in_array('role', $names, true)) {
                $db->run('ALTER TABLE rl_users ADD COLUMN role ' . $str(20) . " NOT NULL DEFAULT 'owner'");
            }
            // Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
            foreach ([['totp_secret', 'TEXT'], ['totp_pending', 'TEXT'], ['totp_recovery', 'TEXT'], ['totp_step', 'BIGINT']] as [$name, $type]) {
                if (!in_array($name, $names, true)) {
                    $db->run("ALTER TABLE rl_users ADD COLUMN $name $type");
                }
            }
            $db->run(
                'CREATE TABLE IF NOT EXISTS rl_invites (id ' . $str(100) . ' PRIMARY KEY, email ' . $str(320) . ' NOT NULL UNIQUE, role ' . $str(20) . ' NOT NULL, code_hash ' . $str(128) . ' NOT NULL UNIQUE, invited_by ' . $str(100) . " NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)$table",
            );
            // A server has one owner. One from before, with several, keeps the first and the rest become admins,
            // who can still do everything but remove the owner. Invites to join as an owner become invites as an admin.
            $owners = $db->all("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id");
            foreach (array_slice($owners, 1) as $extra) {
                $db->run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [(string) $extra['id']]);
            }
            $db->run("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'");
        });
        $this->ready = true;
    }

    /** @return User */
    private function row(array $r): array
    {
        $recovery = Js::truthy($r['totp_recovery'] ?? null) ? Json::decode((string) $r['totp_recovery'], true) : [];
        return [
            'id' => (string) $r['id'],
            'email' => (string) $r['email'],
            'hash' => (string) $r['hash'],
            'role' => self::roleFrom($r['role'] ?? null),
            'createdAt' => Js::number($r['created_at']),
            'twoFactor' => Js::truthy($r['totp_secret'] ?? null),
            'recoveryLeft' => count($recovery),
        ];
    }

    /** Seals a two-factor secret with the install's secret, so the database alone cannot make codes. */
    private function seal(string $text): string
    {
        return Crypto::sealText($text, $this->secret);
    }

    private function unseal(string $sealed): ?string
    {
        return Crypto::unsealText($sealed, $this->secret);
    }

    /** Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed. */
    public function startTwoFactor(string $id): string
    {
        $this->init();
        $secret = Crypto::base32(Crypto::randomBytes(20));
        $this->store->db->run('UPDATE rl_users SET totp_pending = ? WHERE id = ?', [$this->seal($secret), $id]);
        return $secret;
    }

    /**
     * Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once.
     *
     * @return list<string>|null
     */
    public function confirmTwoFactor(string $id, string $code, int $now): ?array
    {
        $this->init();
        $row = $this->store->db->all('SELECT totp_pending FROM rl_users WHERE id = ?', [$id])[0] ?? null;
        $secret = $row !== null && Js::truthy($row['totp_pending'] ?? null) ? $this->unseal((string) $row['totp_pending']) : null;
        $step = $secret !== null && $secret !== '' ? Crypto::matchStep($secret, $code, $now, -1) : null;
        if ($step === null) {
            return null;
        }
        $recovery = Crypto::recoveryCodes();
        // The code that turned it on is not marked used, so signing in again at once with it works.
        $this->store->db->run('UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?', [
            $this->seal($secret),
            Json::encode(array_map(Crypto::recoveryHash(...), $recovery)),
            $id,
        ]);
        return $recovery;
    }

    /**
     * New recovery codes in place of the old ones.
     *
     * @return list<string>
     */
    public function newRecoveryCodes(string $id): array
    {
        $this->init();
        $recovery = Crypto::recoveryCodes();
        $this->store->db->run('UPDATE rl_users SET totp_recovery = ? WHERE id = ?', [Json::encode(array_map(Crypto::recoveryHash(...), $recovery)), $id]);
        return $recovery;
    }

    /** Drops a set-up left half done, after too many wrong codes, so it must start again with the password. */
    public function cancelTwoFactorSetup(string $id): void
    {
        $this->init();
        $this->store->db->run('UPDATE rl_users SET totp_pending = NULL WHERE id = ?', [$id]);
    }

    public function disableTwoFactor(string $id): void
    {
        $this->init();
        $this->store->db->run('UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?', [$id]);
    }

    /**
     * Checks a six-digit code, or a recovery code, for an account with two-factor on.
     * A code works once: one already used, or older, is refused, and a recovery code is crossed off.
     * One check at a time, so two sign-ins at once cannot both use the same code: TypeScript queues them per
     * account in its process, and PHP, which serves each request in its own process, takes the database's lock.
     */
    public function checkSecondFactor(string $id, string $code, int $now): bool
    {
        $this->init();
        return $this->turn(fn (): bool => $this->checkSecondFactorNow($id, $code, $now));
    }

    private function checkSecondFactorNow(string $id, string $code, int $now): bool
    {
        $row = $this->store->db->all('SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?', [$id])[0] ?? null;
        if ($row === null || !Js::truthy($row['totp_secret'] ?? null)) {
            return false;
        }
        $given = Js::trim($code);
        $digits = (string) preg_replace('/[' . Js::SPACE . ']/u', '', $given);
        if (preg_match('/^\d{6}$/D', $digits)) {
            $secret = $this->unseal((string) $row['totp_secret']);
            $after = ($row['totp_step'] ?? null) === null ? -1 : (int) Js::number($row['totp_step']);
            $step = $secret !== null && $secret !== '' ? Crypto::matchStep($secret, $digits, $now, $after) : null;
            if ($step === null) {
                return false;
            }
            $this->store->db->run('UPDATE rl_users SET totp_step = ? WHERE id = ?', [$step, $id]);
            return true;
        }
        $hashes = Js::truthy($row['totp_recovery'] ?? null) ? Json::decode((string) $row['totp_recovery'], true) : [];
        $at = array_search(Crypto::recoveryHash($given), $hashes, true);
        if ($at === false) {
            return false;
        }
        array_splice($hashes, (int) $at, 1);
        $this->store->db->run('UPDATE rl_users SET totp_recovery = ? WHERE id = ?', [Json::encode($hashes), $id]);
        return true;
    }

    /**
     * A short-lived ticket naming an account whose password checked out and
     * which still owes a code. Signed like a session, so it cannot be made up.
     *
     * @param User $user
     */
    public function pendingFor(array $user, int $now): string
    {
        return $this->ticket('pending', $user, $now + 5 * 60_000);
    }

    /**
     * A ticket that looks and acts like pendingFor's, except that no code ever
     * passes with it. A wrong password gets one once an account with
     * two-factor has had too many, so the answer never tells a right password.
     *
     * @param User $user
     */
    public function decoyFor(array $user, int $now): string
    {
        return $this->ticket('decoy', $user, $now + 5 * 60_000);
    }

    /**
     * The account a code-step ticket names, and whether a right code may sign in with it.
     *
     * @return array{user: User, real: bool}|null
     */
    public function fromPending(string $value, int $now): ?array
    {
        $user = $this->fromTicket('pending', $value, $now);
        if ($user !== null) {
            return ['user' => $user, 'real' => true];
        }
        $decoy = $this->fromTicket('decoy', $value, $now);
        return $decoy !== null ? ['user' => $decoy, 'real' => false] : null;
    }

    /**
     * A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.
     *
     * @param User $user
     */
    public function linkFor(array $user, int $now): string
    {
        return $this->ticket('link', $user, $now + 15 * 60_000);
    }

    /**
     * The account a sign-in link is for. A link works once: using it withdraws it, and every link sent
     * before it. Uses take turns, so a link opened twice at once lets one in.
     *
     * @return User|null
     */
    public function fromLink(string $value, int $now): ?array
    {
        $user = $this->fromTicket('link', $value, $now);
        if ($user === null) {
            return null;
        }
        $expires = Js::number(explode('.', $value)[1] ?? '');
        return $this->turn(function () use ($user, $expires): ?array {
            $key = "login-link-used:{$user['id']}";
            if ($expires <= Js::number($this->store->setting($key) ?? 0)) {
                return null;
            }
            $this->store->setSetting($key, Js::string($expires));
            return $user;
        });
    }

    /** @param User $user */
    private function ticket(string $kind, array $user, int $expires): string
    {
        $body = "{$user['id']}.$expires";
        return "$body." . $this->sign("$kind.$body", $user['hash']);
    }

    /** @return User|null */
    private function fromTicket(string $kind, string $value, int $now): ?array
    {
        $parts = explode('.', $value);
        $id = $parts[0];
        $expires = $parts[1] ?? '';
        $signature = $parts[2] ?? '';
        if ($id === '' || $expires === '' || $signature === '' || !(Js::number($expires) > $now)) {
            return null;
        }
        $user = $this->byId($id);
        if ($user === null) {
            return null;
        }
        return Crypto::sameText($this->sign("$kind.$id.$expires", $user['hash']), $signature) ? $user : null;
    }

    public function count(): int
    {
        $this->init();
        $row = $this->store->db->all('SELECT COUNT(*) AS n FROM rl_users')[0] ?? null;
        return (int) ($row['n'] ?? 0);
    }

    /** @return User|null */
    public function byEmail(string $email): ?array
    {
        $this->init();
        $row = $this->store->db->all('SELECT * FROM rl_users WHERE email = ?', [Js::lower(Js::trim($email))])[0] ?? null;
        return $row !== null ? $this->row($row) : null;
    }

    /** @return User|null */
    public function byId(string $id): ?array
    {
        $this->init();
        $row = $this->store->db->all('SELECT * FROM rl_users WHERE id = ?', [$id])[0] ?? null;
        return $row !== null ? $this->row($row) : null;
    }

    /** @return list<User> */
    public function list(): array
    {
        $this->init();
        return array_map(fn (array $r): array => $this->row($r), $this->store->db->all('SELECT * FROM rl_users ORDER BY created_at, id'));
    }

    /**
     * Changes a role. The owner's never changes here, and nobody becomes the owner here: see handOver().
     *
     * @return User
     */
    public function setRole(string $id, string $role): array
    {
        // The tables first: making them takes the same lock as a turn.
        $this->init();
        return $this->turn(function () use ($id, $role): array {
            $user = $this->find($id);
            if ($user === null) {
                throw new AccountError('Unknown account', 'unknown_account');
            }
            if ($user['role'] === 'owner') {
                throw new AccountError('Only the owner can change their own role, by handing ownership to an admin', 'owner_protected');
            }
            if ($role === 'owner') {
                throw new AccountError('Ownership is handed over by the owner', 'owner_hand_over');
            }
            $this->store->db->run('UPDATE rl_users SET role = ? WHERE id = ?', [$role, $id]);
            $user['role'] = $role;
            return $user;
        });
    }

    /** @return User|null */
    private function find(string $id): ?array
    {
        foreach ($this->list() as $user) {
            if ($user['id'] === $id) {
                return $user;
            }
        }
        return null;
    }

    /** Makes an admin the owner, and the owner an admin. */
    public function handOver(string $from, string $to): void
    {
        $this->init();
        $this->turn(function () use ($from, $to): void {
            $owner = $this->find($from);
            $next = $this->find($to);
            if ($owner === null || $owner['role'] !== 'owner') {
                throw new AccountError('Only the owner can hand over ownership', 'owner_hand_over');
            }
            if ($next === null) {
                throw new AccountError('Unknown account', 'unknown_account');
            }
            if ($next['role'] !== 'admin') {
                throw new AccountError('Make them an admin first', 'owner_needs_admin');
            }
            $this->store->db->run("UPDATE rl_users SET role = 'owner' WHERE id = ?", [$to]);
            $this->store->db->run("UPDATE rl_users SET role = 'admin' WHERE id = ?", [$from]);
        });
    }

    /** Removes an account. The owner cannot be removed. */
    public function remove(string $id): void
    {
        // The tables first: making them takes the same lock as a turn.
        $this->init();
        $this->turn(function () use ($id): void {
            $user = $this->find($id);
            if ($user === null) {
                throw new AccountError('Unknown account', 'unknown_account');
            }
            if ($user['role'] === 'owner') {
                throw new AccountError('The owner cannot be removed', 'owner_protected');
            }
            $this->store->db->run('DELETE FROM rl_users WHERE id = ?', [$id]);
            $this->store->setSetting("login-link-used:$id", null);
        });
    }

    /**
     * Makes an account, or sets a new password on an existing one. A new account is the owner when it is the first,
     * and otherwise an admin unless a role is given, since a server has one owner.
     *
     * @return User
     */
    public function setPassword(string $email, string $password, int $now, ?string $role = null): array
    {
        $this->init();
        $address = Js::lower(Js::trim($email));
        if (!preg_match(self::EMAIL, $address)) {
            throw new AccountError('Enter an email address', 'email_invalid');
        }
        if (Js::length($password) < self::MIN_PASSWORD) {
            throw new AccountError('Use a password of at least ' . self::MIN_PASSWORD . ' characters', 'password_short', ['min' => (string) self::MIN_PASSWORD]);
        }
        $hash = Crypto::hashPassword($password);
        $existing = $this->byEmail($address);
        if ($existing !== null) {
            $this->store->db->run('UPDATE rl_users SET hash = ? WHERE id = ?', [$hash, $existing['id']]);
            $existing['hash'] = $hash;
            return $existing;
        }
        $first = $this->count() === 0;
        $given = $role ?? ($first ? 'owner' : 'admin');
        $user = [
            'id' => Crypto::hex(Crypto::randomBytes(12)),
            'email' => $address,
            'hash' => $hash,
            'role' => $given === 'owner' && !$first ? 'admin' : $given,
            'createdAt' => $now,
            'twoFactor' => false,
            'recoveryLeft' => 0,
        ];
        $this->store->db->run('INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)', [$user['id'], $user['email'], $user['hash'], $user['role'], $user['createdAt']]);
        return $user;
    }

    /** @return Invite */
    private function inviteRow(array $r): array
    {
        return [
            'id' => (string) $r['id'],
            'email' => (string) $r['email'],
            'role' => self::roleFrom($r['role'] ?? null),
            'invitedBy' => (string) $r['invited_by'],
            'createdAt' => Js::number($r['created_at']),
            'expiresAt' => Js::number($r['expires_at']),
        ];
    }

    /**
     * Invites that still work, newest first. Expired ones are cleared on the way.
     *
     * @return list<Invite>
     */
    public function invites(int $now): array
    {
        $this->init();
        $this->store->db->run('DELETE FROM rl_invites WHERE expires_at <= ?', [$now]);
        return array_map(fn (array $r): array => $this->inviteRow($r), $this->store->db->all('SELECT * FROM rl_invites ORDER BY created_at DESC, id'));
    }

    /**
     * Invites someone to join with a role, and returns the code for their link.
     * Asking again replaces the earlier invite, so only the newest link works.
     *
     * @return array{invite: Invite, code: string}
     */
    public function invite(string $email, string $role, string $invitedBy, int $now): array
    {
        $this->init();
        return $this->turn(fn (): array => $this->inviteNow($email, $role, $invitedBy, $now));
    }

    /** @return array{invite: Invite, code: string} */
    private function inviteNow(string $email, string $role, string $invitedBy, int $now): array
    {
        $address = Js::lower(Js::trim($email));
        if (!preg_match(self::EMAIL, $address)) {
            throw new AccountError('Enter an email address', 'email_invalid');
        }
        if ($this->byEmail($address) !== null) {
            throw new AccountError("$address already has an account", 'account_exists', ['email' => $address]);
        }
        $code = Crypto::base64url(Crypto::randomBytes(24));
        $invite = ['id' => Crypto::hex(Crypto::randomBytes(12)), 'email' => $address, 'role' => $role, 'invitedBy' => $invitedBy, 'createdAt' => $now, 'expiresAt' => $now + self::INVITE_MS];
        $this->store->db->run('DELETE FROM rl_invites WHERE email = ?', [$address]);
        $this->store->db->run('INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)', [
            $invite['id'],
            $invite['email'],
            $invite['role'],
            self::codeHash($code),
            $invite['invitedBy'],
            $invite['createdAt'],
            $invite['expiresAt'],
        ]);
        return ['invite' => $invite, 'code' => $code];
    }

    private static function codeHash(string $code): string
    {
        return Crypto::hex(Crypto::sha256($code));
    }

    /**
     * The invite a link's code belongs to, while it still works.
     *
     * @return Invite|null
     */
    public function inviteByCode(string $code, int $now): ?array
    {
        $this->init();
        if (!preg_match('/^[A-Za-z0-9_-]{20,64}$/D', $code)) {
            return null;
        }
        $row = $this->store->db->all('SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?', [self::codeHash($code), $now])[0] ?? null;
        return $row !== null ? $this->inviteRow($row) : null;
    }

    public function cancelInvite(string $id): bool
    {
        $this->init();
        $before = count($this->store->db->all('SELECT id FROM rl_invites WHERE id = ?', [$id]));
        $this->store->db->run('DELETE FROM rl_invites WHERE id = ?', [$id]);
        return $before > 0;
    }

    /**
     * Turns an invite into an account with the password its person chose. The link then stops working.
     *
     * @return User
     */
    public function acceptInvite(string $code, string $password, int $now): array
    {
        $invite = $this->inviteByCode($code, $now);
        if ($invite === null) {
            throw new AccountError('This invite has expired or was already used. Ask for a new one.', 'invite_gone');
        }
        if ($this->byEmail($invite['email']) !== null) {
            throw new AccountError("{$invite['email']} already has an account", 'account_exists', ['email' => $invite['email']]);
        }
        $user = $this->setPassword($invite['email'], $password, $now, $invite['role']);
        $this->store->db->run('DELETE FROM rl_invites WHERE id = ?', [$invite['id']]);
        return $user;
    }

    /**
     * The account for an email and password, or null. Takes the same time either way.
     *
     * @return User|null
     */
    public function signIn(string $email, string $password): ?array
    {
        $user = $this->byEmail($email);
        if ($user === null) {
            Crypto::checkPassword($password, self::$decoy ??= Crypto::hashPassword(Crypto::hex(Crypto::randomBytes(16))));
            return null;
        }
        return Crypto::checkPassword($password, $user['hash']) ? $user : null;
    }

    /**
     * A cookie value naming the user and when it expires, signed with the
     * server's secret and the user's password hash, so changing a password
     * signs out every other browser.
     *
     * @param User $user
     */
    public function sessionFor(array $user, int $now): string
    {
        $expires = $now + self::SESSION_MS;
        $body = "{$user['id']}.$expires";
        return "$body." . $this->sign($body, $this->sessionKey($user));
    }

    /**
     * The signed-in user for a cookie value, or null.
     *
     * @return User|null
     */
    public function fromSession(string $value, int $now): ?array
    {
        $parts = explode('.', $value);
        $id = $parts[0];
        $expires = $parts[1] ?? '';
        $signature = $parts[2] ?? '';
        if ($id === '' || $expires === '' || $signature === '' || !(Js::number($expires) > $now)) {
            return null;
        }
        $user = $this->byId($id);
        if ($user === null) {
            return null;
        }
        return Crypto::sameText($this->sign("$id.$expires", $this->sessionKey($user)), $signature) ? $user : null;
    }

    /**
     * What a session is signed with: the password hash, and whether two-factor is on, so changing either ends other sessions.
     *
     * @param User $user
     */
    private function sessionKey(array $user): string
    {
        return $user['hash'] . ($user['twoFactor'] ? '.2fa' : '');
    }

    /**
     * A long-lived mark for a browser that signed in to an account. With it, failed tries by others
     * against that account cannot lock this browser out; the per-address limit still applies.
     * A new password withdraws it.
     *
     * @param User $user
     */
    public function deviceFor(array $user): string
    {
        return "{$user['id']}." . $this->sign("device.{$user['id']}", $user['hash']);
    }

    /** @param User $user */
    public function trustsDevice(string $value, array $user): bool
    {
        $parts = explode('.', $value);
        $id = $parts[0];
        $signature = $parts[1] ?? '';
        if ($id !== $user['id'] || $signature === '') {
            return false;
        }
        return Crypto::sameText($this->sign("device.{$user['id']}", $user['hash']), $signature);
    }

    private function sign(string $body, string $hash): string
    {
        return Crypto::signature($this->secret, $body, $hash);
    }
}
