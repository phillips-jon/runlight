<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Json;

/** conformance/http.json, read once, with objects as stdClass so {} and [] stay apart. */
final class Scenarios
{
    private static ?\stdClass $file = null;

    public static function file(): \stdClass
    {
        return self::$file ??= Json::decode((string) file_get_contents(dirname(__DIR__, 4) . '/conformance/http.json'));
    }

    /** @return list<\stdClass> */
    public static function all(): array
    {
        return self::file()->scenarios;
    }

    public static function named(string $name): \stdClass
    {
        foreach (self::all() as $scenario) {
            if ($scenario->name === $name) {
                return $scenario;
            }
        }
        throw new \InvalidArgumentException("No scenario is named $name");
    }
}
