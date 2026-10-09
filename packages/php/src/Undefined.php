<?php

declare(strict_types=1);

namespace Runlight;

/**
 * JavaScript's undefined, for the few answers that build an object with a
 * field that may be left out: Json::encode skips a field holding it.
 */
final class Undefined
{
    private static ?self $one = null;

    private function __construct()
    {
    }

    public static function value(): self
    {
        return self::$one ??= new self();
    }
}
