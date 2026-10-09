<?php

declare(strict_types=1);

namespace Runlight;

final class Hash
{
    public static function sha256(string $text): string
    {
        return hash('sha256', $text);
    }

    /** HMAC-SHA-256 of text under key, as hex. */
    public static function hmac(string $key, string $text): string
    {
        return hash_hmac('sha256', $text, $key);
    }

    /**
     * The day's visitor hash: SHA-256 of salt, site, IP, and user agent, cut to
     * 64 bits. The salt changes every day and old salts are deleted, so the hash
     * cannot be recomputed and does not follow anyone across days.
     */
    public static function visitorHash(string $salt, string $site, string $ip, string $ua): string
    {
        return substr(self::sha256("$salt\n$site\n$ip\n$ua"), 0, 16);
    }

    public static function randomId(int $bytes = 12): string
    {
        return bin2hex(random_bytes($bytes));
    }

    public static function randomSalt(): string
    {
        return self::randomId(32);
    }
}
