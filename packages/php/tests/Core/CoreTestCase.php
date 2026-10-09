<?php

declare(strict_types=1);

namespace Runlight\Tests\Core;

use PHPUnit\Framework\TestCase;
use Runlight\Tests\Store\Databases;

/** Tests of the Runlight core that run on every database at hand (see Databases). */
abstract class CoreTestCase extends TestCase
{
    public const DAY = Harness::DAY;
    public const HOUR = Harness::HOUR;
    public const MIN = Harness::MIN;

    /** @return array<string, array{0: string}> */
    public static function kinds(): array
    {
        return Databases::kinds();
    }

    protected function tearDown(): void
    {
        Databases::cleanup();
    }

    /** Date.UTC with months counted from 1. */
    protected static function utc(int $y, int $m, int $d, int $h = 0, int $i = 0, int $s = 0): int
    {
        return gmmktime($h, $i, $s, $m, $d, $y) * 1000;
    }

    /** Date.parse of an ISO time. */
    protected static function at(string $iso): int
    {
        return (int) (new \DateTimeImmutable($iso))->format('U') * 1000;
    }
}
