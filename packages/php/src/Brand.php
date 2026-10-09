<?php

declare(strict_types=1);

namespace Runlight;

final class Brand
{
    /** The Runlight mark for the dashboard's tab: an R in a rounded lamp housing, one corner lit. A data: URL. */
    public static function runlightIcon(): string
    {
        return (string) Version::build()['icon'];
    }
}
