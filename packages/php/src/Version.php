<?php

declare(strict_types=1);

namespace Runlight;

/**
 * The SDK's version and the HTTP API's, read from assets/build.json, which
 * scripts/php-assets.mts writes from the TypeScript SDK, so the two always
 * report the same.
 */
final class Version
{
    /** @var array<string, mixed>|null */
    private static ?array $build = null;

    /** Everything in assets/build.json: the versions, the asset hashes, and the icon. @return array<string, mixed> */
    public static function build(): array
    {
        if (self::$build === null) {
            $text = @file_get_contents(__DIR__ . '/../assets/build.json');
            if ($text === false) {
                throw new \RuntimeException('Runlight: assets/build.json is missing; run npm run php-assets.');
            }
            self::$build = Json::decode($text, true);
        }
        return self::$build;
    }

    public static function version(): string
    {
        return (string) self::build()['version'];
    }

    /** Bumped when the HTTP API changes shape, so the dashboard and the hub can tell. */
    public static function apiVersion(): int
    {
        return (int) self::build()['apiVersion'];
    }
}
