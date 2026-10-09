<?php

declare(strict_types=1);

namespace Runlight\Mail;

use Runlight\Body;

/**
 * Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
 * installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
 * `RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
 * The label says "mail" because mail came first; changing it would make every saved key unreadable.
 *
 * The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
 * by its 16 byte tag, so either implementation opens what the other sealed.
 */
final class Secret
{
    private static function keyFor(string $secret): string
    {
        return hash('sha256', "runlight-mail:$secret", true);
    }

    /** `v1:<iv>:<ciphertext>`, or `plain:<json>` when the server has no secret to encrypt with. */
    public static function seal(string $value, ?string $secret): string
    {
        if ($secret === null || $secret === '') {
            return "plain:$value";
        }
        $iv = random_bytes(12);
        $tag = '';
        $data = openssl_encrypt($value, 'aes-256-gcm', self::keyFor($secret), OPENSSL_RAW_DATA, $iv, $tag, '', 16);
        if ($data === false) {
            throw new \RuntimeException('AES-GCM is not available');
        }
        return 'v1:' . base64_encode($iv) . ':' . base64_encode($data . $tag);
    }

    /** The sealed value, or null when it cannot be opened (a different secret, or damaged). */
    public static function unseal(string $sealed, ?string $secret): ?string
    {
        if (str_starts_with($sealed, 'plain:')) {
            return substr($sealed, 6);
        }
        $parts = explode(':', $sealed);
        [$version, $iv, $data] = [$parts[0], $parts[1] ?? '', $parts[2] ?? ''];
        if ($version !== 'v1' || $iv === '' || $data === '' || $secret === null || $secret === '') {
            return null;
        }
        $iv = base64_decode($iv, true);
        $data = base64_decode($data, true);
        // Web Crypto refuses an AES-GCM IV under 12 bytes, so such a value opens nowhere.
        if ($iv === false || strlen($iv) < 12 || $data === false || strlen($data) < 16) {
            return null;
        }
        $plain = openssl_decrypt(substr($data, 0, -16), 'aes-256-gcm', self::keyFor($secret), OPENSSL_RAW_DATA, $iv, substr($data, -16));
        if ($plain === false) {
            return null;
        }
        return Body::utf8($plain);
    }
}
