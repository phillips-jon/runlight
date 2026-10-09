<?php

declare(strict_types=1);

namespace Runlight\Tests;

use Runlight\Json;

/** Reads the fixtures scripts/php-fixtures-core.mts writes from the TypeScript SDK. */
final class Fixture
{
    /** @var array<string, mixed> */
    private static array $loaded = [];

    public static function load(string $name, bool $assoc = true): mixed
    {
        $key = $name . ($assoc ? ':a' : ':o');
        return self::$loaded[$key] ??= Json::decode((string) file_get_contents(__DIR__ . "/fixtures/$name.json"), $assoc);
    }

    /** A short label for a case, for messages. */
    public static function label(mixed $value): string
    {
        $text = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
        return mb_strlen((string) $text) > 160 ? mb_substr((string) $text, 0, 160) . '...' : (string) $text;
    }
}
