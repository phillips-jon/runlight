<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Brand;
use Runlight\Version;

final class VersionTest extends TestCase
{
    public function testTheVersionsAndIconAreTheTypeScriptSdks(): void
    {
        $fixture = Fixture::load('version');
        $this->assertSame($fixture['version'], Version::version());
        $this->assertSame($fixture['apiVersion'], Version::apiVersion());
        $this->assertSame($fixture['icon'], Brand::runlightIcon());
    }
}
