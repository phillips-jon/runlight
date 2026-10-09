<?php

declare(strict_types=1);

namespace Runlight\Accounts;

use Runlight\Js;

/**
 * The cryptography accounts need. Passwords use scrypt, as the standalone server always has, in a plain PHP
 * scrypt that gives the same bytes as Node's; a PBKDF2 hash made on an edge runtime checks out too.
 *
 * Bytes are PHP strings throughout. The two-factor pieces that live in auth.ts in TypeScript (base32, TOTP,
 * the otpauth address, recovery codes, and the signature on session cookies) are here too, as functions of
 * their inputs alone, so the accounts class can call them.
 */
final class Crypto
{
    private const SCRYPT_N = 16384;
    private const SCRYPT_R = 8;
    private const SCRYPT_P = 1;

    /** As many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on. */
    public const PBKDF2_ROUNDS = 100_000;

    // Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.
    public const STEP_MS = 30_000;
    private const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

    public static function randomBytes(int $length): string
    {
        return random_bytes($length);
    }

    public static function base64url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    /**
     * Bytes from base64url (or plain base64), read as atob() reads them: white space is skipped, padding is
     * optional, and anything else that is not base64 throws.
     *
     * @throws \InvalidArgumentException for text atob() refuses
     */
    public static function fromBase64url(string $text): string
    {
        $plain = str_replace(["\t", "\n", "\f", "\r", ' '], '', strtr($text, '-_', '+/'));
        if (strlen($plain) % 4 === 0) {
            $plain = (string) preg_replace('/={1,2}\z/', '', $plain);
        }
        if (strlen($plain) % 4 === 1 || !preg_match('/^[A-Za-z0-9+\/]*$/', $plain)) {
            throw new \InvalidArgumentException('The string to be decoded is not correctly encoded.');
        }
        return (string) base64_decode($plain, false);
    }

    public static function hex(string $bytes): string
    {
        return bin2hex($bytes);
    }

    public static function sha256(string $value): string
    {
        return hash('sha256', $value, true);
    }

    /** @param 'SHA-1'|'SHA-256' $hash */
    public static function hmac(string $hash, string $key, string $data): string
    {
        if ($key === '') {
            // WebCrypto will not import an empty HMAC key.
            throw new \InvalidArgumentException('An HMAC key must not be empty');
        }
        return hash_hmac($hash === 'SHA-1' ? 'sha1' : 'sha256', $data, $key, true);
    }

    /** Compares two strings in time that does not depend on where they differ. */
    public static function sameText(string $a, string $b): bool
    {
        return self::sameBytes($a, $b);
    }

    /** A password hash, in the scrypt form the standalone server has always written. */
    public static function hashPassword(string $password): string
    {
        $salt = self::randomBytes(16);
        return 'scrypt$' . self::base64url($salt) . '$' . self::base64url(self::scrypt($password, $salt, 32));
    }

    /**
     * Whether a password matches a hash, scrypt or PBKDF2. A stored key under MIN_KEY_BYTES is refused, since an
     * empty or cut key would match too easily, or anything.
     *
     * @throws \InvalidArgumentException when a part of the hash is not base64, as the TypeScript rejects then
     */
    /** The shortest stored key accepted. Ours are 32 bytes. */
    public const MIN_KEY_BYTES = 16;

    public static function checkPassword(string $password, string $stored): bool
    {
        $parts = explode('$', $stored);
        // A stored hash whose salt or key is not base64url matches nothing, rather than failing the sign-in.
        $decode = static function (string $text): ?string {
            try {
                return self::fromBase64url($text);
            } catch (\InvalidArgumentException) {
                return null;
            }
        };
        if ($parts[0] === 'scrypt' && count($parts) === 3) {
            $expected = $decode($parts[2]);
            $salt = $decode($parts[1]);
            if ($expected === null || $salt === null || strlen($expected) < self::MIN_KEY_BYTES) {
                return false;
            }
            return self::sameBytes(self::scrypt($password, $salt, strlen($expected)), $expected);
        }
        if ($parts[0] === 'pbkdf2' && count($parts) === 4) {
            $rounds = Js::number($parts[1]);
            if (!is_int($rounds) || $rounds < 1 || $rounds > 10_000_000) {
                return false;
            }
            $expected = $decode($parts[3]);
            $salt = $decode($parts[2]);
            if ($expected === null || $salt === null || strlen($expected) < self::MIN_KEY_BYTES) {
                return false;
            }
            return self::sameBytes(self::pbkdf2($password, $salt, $rounds, strlen($expected)), $expected);
        }
        return false;
    }

    private static function scrypt(string $password, string $salt, int $length): string
    {
        return $length === 0 ? '' : Scrypt::derive($password, $salt, self::SCRYPT_N, self::SCRYPT_R, self::SCRYPT_P, $length);
    }

    private static function pbkdf2(string $password, string $salt, int $rounds, int $length): string
    {
        return $length === 0 ? '' : hash_pbkdf2('sha256', $password, $salt, $rounds, $length, true);
    }

    private static function sameBytes(string $a, string $b): bool
    {
        $diff = strlen($a) ^ strlen($b);
        $length = max(strlen($a), strlen($b));
        for ($i = 0; $i < $length; $i++) {
            $diff |= (isset($a[$i]) ? ord($a[$i]) : 0) ^ (isset($b[$i]) ? ord($b[$i]) : 0);
        }
        return $diff === 0;
    }

    private static function sealKey(string $secret): string
    {
        return self::sha256("totp:$secret");
    }

    /**
     * Seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
     * standalone server has always stored two-factor secrets in. `$iv` is for tests; leave it out.
     */
    public static function sealText(string $text, string $secret, ?string $iv = null): string
    {
        $iv ??= self::randomBytes(12);
        $tag = '';
        $body = openssl_encrypt($text, 'aes-256-gcm', self::sealKey($secret), OPENSSL_RAW_DATA, $iv, $tag, '', 16);
        if ($body === false) {
            throw new \RuntimeException('AES-GCM sealing failed');
        }
        return self::base64url($iv) . '.' . self::base64url($body) . '.' . self::base64url($tag);
    }

    public static function unsealText(string $sealed, string $secret): ?string
    {
        try {
            $parts = explode('.', $sealed);
            $iv = $parts[0];
            $body = $parts[1] ?? null;
            $tag = $parts[2] ?? null;
            if ($iv === '' || $body === null || $tag === null || $tag === '') {
                return null;
            }
            // WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell.
            $joined = self::fromBase64url($body) . self::fromBase64url($tag);
            $ivBytes = self::fromBase64url($iv);
            // WebCrypto refuses an IV shorter than 12 bytes.
            if (strlen($joined) < 16 || strlen($ivBytes) < 12) {
                return null;
            }
            $plain = openssl_decrypt(substr($joined, 0, -16), 'aes-256-gcm', self::sealKey($secret), OPENSSL_RAW_DATA, $ivBytes, substr($joined, -16));
            if ($plain === false) {
                return null;
            }
            return self::decodeUtf8($plain);
        } catch (\Throwable) {
            return null;
        }
    }

    /** TextDecoder's reading: bytes that are not UTF-8 become U+FFFD, and a leading byte order mark goes. */
    private static function decodeUtf8(string $bytes): string
    {
        if (str_starts_with($bytes, "\xEF\xBB\xBF")) {
            $bytes = substr($bytes, 3);
        }
        if (mb_check_encoding($bytes, 'UTF-8')) {
            return $bytes;
        }
        $before = mb_substitute_character();
        mb_substitute_character(0xFFFD);
        try {
            return mb_convert_encoding($bytes, 'UTF-8', 'UTF-8');
        } finally {
            mb_substitute_character($before);
        }
    }

    public static function base32(string $bytes): string
    {
        $bits = 0;
        $value = 0;
        $out = '';
        $length = strlen($bytes);
        for ($i = 0; $i < $length; $i++) {
            // Only the low bits are ever read, so the rest are dropped before they grow.
            $value = (($value << 8) | ord($bytes[$i])) & 0xffff;
            $bits += 8;
            while ($bits >= 5) {
                $out .= self::BASE32[($value >> ($bits - 5)) & 31];
                $bits -= 5;
            }
        }
        if ($bits > 0) {
            $out .= self::BASE32[($value << (5 - $bits)) & 31];
        }
        return $out;
    }

    /** Bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets come. */
    public static function unbase32(string $text): string
    {
        $bits = 0;
        $value = 0;
        $out = '';
        $upper = mb_strtoupper((string) preg_replace('/=+\z/', '', $text), 'UTF-8');
        foreach (mb_str_split($upper, 1, 'UTF-8') as $c) {
            $i = strlen($c) === 1 ? strpos(self::BASE32, $c) : false;
            if ($i === false) {
                continue;
            }
            $value = (($value << 5) | $i) & 0xffff;
            $bits += 5;
            if ($bits >= 8) {
                $out .= chr(($value >> ($bits - 8)) & 255);
                $bits -= 8;
            }
        }
        return $out;
    }

    /** The six-digit code for a secret at a time step. */
    public static function totp(string $secret, int $step): string
    {
        $mac = self::hmac('SHA-1', self::unbase32($secret), pack('J', $step));
        $at = ord($mac[19]) & 15;
        $n = ((ord($mac[$at]) & 127) << 24) | (ord($mac[$at + 1]) << 16) | (ord($mac[$at + 2]) << 8) | ord($mac[$at + 3]);
        return str_pad((string) ($n % 1_000_000), 6, '0', STR_PAD_LEFT);
    }

    /** The time step a code matches, one step either side for clocks that drift, newer than `after`; else null. */
    public static function matchStep(string $secret, string $code, int $now, int $after): ?int
    {
        $current = intdiv($now, self::STEP_MS) - ($now < 0 && $now % self::STEP_MS !== 0 ? 1 : 0);
        foreach ([$current, $current - 1, $current + 1] as $step) {
            if ($step > $after && self::totp($secret, $step) === $code) {
                return $step;
            }
        }
        return null;
    }

    /** The address an authenticator app reads from the QR code. */
    public static function otpauthUri(string $secret, string $email, string $host): string
    {
        $label = Js::encodeURIComponent("Runlight ($host):$email");
        return "otpauth://totp/$label?secret=$secret&issuer=" . Js::encodeURIComponent("Runlight ($host)") . '&algorithm=SHA1&digits=6&period=30';
    }

    /**
     * Ten one-use recovery codes, like "k7dq-2mfa".
     *
     * @return list<string>
     */
    public static function recoveryCodes(): array
    {
        $codes = [];
        for ($i = 0; $i < 10; $i++) {
            $raw = strtolower(self::base32(self::randomBytes(5)));
            $codes[] = substr($raw, 0, 4) . '-' . substr($raw, 4, 4);
        }
        return $codes;
    }

    /** What a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and case do not matter. */
    public static function recoveryHash(string $code): string
    {
        return self::hex(self::sha256(strtolower((string) preg_replace('/[^a-z0-9]/i', '', $code))));
    }

    /** The signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the install's secret. */
    public static function signature(string $secret, string $body, string $hash): string
    {
        return self::base64url(self::hmac('SHA-256', $secret, "$body.$hash"));
    }
}
