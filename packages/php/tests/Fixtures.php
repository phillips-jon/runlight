<?php

declare(strict_types=1);

namespace Runlight\Tests;

use Runlight\Json;

/** The parity fixtures scripts/php-fixtures-ai.mts writes from the TypeScript SDK. */
final class Fixtures
{
    /** @var array<string, mixed> */
    private static array $loaded = [];

    /** The fixture with objects as stdClass, so {} and [] stay apart, or as arrays when `$assoc`. */
    public static function load(string $name, bool $assoc = false): mixed
    {
        $key = $name . ($assoc ? ':assoc' : '');
        return self::$loaded[$key] ??= Json::decode((string) file_get_contents(__DIR__ . "/fixtures/$name.json"), $assoc);
    }
}
