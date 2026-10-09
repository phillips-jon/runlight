<?php

declare(strict_types=1);

namespace Runlight;

/** Environment variables, from getenv(), then $_ENV, then $_SERVER, as hosts set them differently. */
final class Env
{
    public static function get(string $name): ?string
    {
        $value = getenv($name);
        if ($value === false) {
            $value = $_ENV[$name] ?? $_SERVER[$name] ?? null;
        }
        if (!is_string($value)) {
            return null;
        }
        $value = trim($value);
        return $value === '' ? null : $value;
    }
}
