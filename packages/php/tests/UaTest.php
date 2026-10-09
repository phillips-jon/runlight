<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Runlight\Json;
use Runlight\Ua;

/** Replays conformance/ua.json, every case, and the wider fixture written from the TypeScript SDK. */
final class UaTest extends TestCase
{
    public static function conformance(): iterable
    {
        $cases = Json::decode((string) file_get_contents(__DIR__ . '/../../../conformance/ua.json'), true)['cases'];
        foreach ($cases as $i => $case) {
            yield "$i " . substr($case['ua'], 0, 90) => [$case];
        }
    }

    #[DataProvider('conformance')]
    public function testConformance(array $case): void
    {
        $agent = Ua::aiAgent($case['ua']);
        if (isset($case['agent'])) {
            $this->assertSame($case['agent']['name'], $agent['name'] ?? null);
            $this->assertSame($case['agent']['kind'], $agent['kind'] ?? null);
            return;
        }
        $this->assertNull($agent, 'not an AI agent');
        $this->assertSame((bool) ($case['bot'] ?? false), Ua::isBot($case['ua']), !empty($case['bot']) ? 'is a bot' : 'is a person');
        if (isset($case['client'])) {
            $this->assertSame($case['client'], Ua::parseClient($case['ua'], $case['hints'] ?? [], $case['screenWidth'] ?? null));
        }
    }

    public function testClientHintsMarkAMobileChromiumAsMobile(): void
    {
        $ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
        $this->assertSame('tablet', Ua::parseClient($ua)['device']);
        $this->assertSame('tablet', Ua::parseClient($ua, ['mobile' => '?1'])['device'], 'an Android UA without Mobile still reads as a tablet');
        $desktop = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
        $this->assertSame('mobile', Ua::parseClient($desktop, ['mobile' => '?1'])['device']);
    }

    public function testFixture(): void
    {
        $cases = Fixture::load('ua')['cases'];
        $failures = [];
        foreach ($cases as $case) {
            $got = [
                'agent' => Ua::aiAgent($case['ua']),
                'bot' => Ua::isBot($case['ua']),
                'client' => Ua::parseClient($case['ua'], $case['hints'] ?? [], $case['screenWidth'] ?? null),
            ];
            $want = ['agent' => $case['agent'], 'bot' => $case['bot'], 'client' => $case['client']];
            if ($got !== $want) {
                $failures[] = Fixture::label($case) . ' gave ' . Fixture::label($got);
            }
        }
        $this->assertGreaterThan(200, count($cases));
        $this->assertSame([], array_slice($failures, 0, 20));
    }
}
