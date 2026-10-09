<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Geo;
use Runlight\Http\Headers;
use Runlight\Mmdb;

/** Location from platform headers and MMDB files, replayed from the TypeScript SDK and server. */
final class GeoTest extends TestCase
{
    public function testHeaders(): void
    {
        foreach (Fixture::load('geo')['headers'] as $case) {
            $this->assertSame($case['location'], Geo::locationFromHeaders(new Headers($case['headers'])), Fixture::label($case['headers']));
        }
    }

    public function testLocate(): void
    {
        foreach (Fixture::load('geo')['located'] as $case) {
            $lookup = empty($case['noLookup']) ? function (string $ip) use ($case): ?array {
                if (!empty($case['throws'])) {
                    throw new \RuntimeException('broken');
                }
                return $case['found'];
            } : null;
            $this->assertSame($case['location'], Geo::locate(new Headers($case['headers']), $case['ip'], $lookup), Fixture::label($case));
        }
    }

    public function testMmdb(): void
    {
        foreach (Fixture::load('geo')['databases'] as $db) {
            $reader = new Mmdb(base64_decode($db['base64']));
            $this->assertSame($db['ipVersion'], $reader->metadata['ip_version']);
            $this->assertSame($db['recordSize'], $reader->metadata['record_size']);
            $this->assertSame(1759708800, $reader->metadata['build_epoch']);
            $this->assertSame(['en' => 'A test database'], $reader->metadata['description']);
            $lookup = Geo::lookupFrom($reader);
            foreach ($db['records'] as $case) {
                $label = "{$db['ipVersion']}/{$db['recordSize']} {$case['ip']}";
                $this->assertEquals($case['record'], $reader->get($case['ip']), $label);
                $this->assertSame(json_encode($case['record']), json_encode($reader->get($case['ip'])), $label);
                $this->assertSame($case['location'], $lookup($case['ip']), $label);
            }
        }
    }

    public function testAFileIsReadAPageAtATimeWithTheSameAnswers(): void
    {
        foreach (Fixture::load('geo')['databases'] as $db) {
            $file = tempnam(sys_get_temp_dir(), 'rl-mmdb');
            file_put_contents($file, base64_decode($db['base64']));
            try {
                $reader = Mmdb::open($file);
                $this->assertSame($db['ipVersion'], $reader->metadata['ip_version']);
                foreach ($db['records'] as $case) {
                    $this->assertSame(json_encode($case['record']), json_encode($reader->get($case['ip'])), "{$db['ipVersion']}/{$db['recordSize']} {$case['ip']}");
                }
            } finally {
                unlink($file);
            }
        }
        $this->expectException(\RuntimeException::class);
        Mmdb::open(sys_get_temp_dir() . '/no-such-runlight.mmdb');
    }

    public function testDbIpRecordsBecomeACountryCodeAReadableRegionAndAPlainCity(): void
    {
        $records = [
            '24.114.0.1' => ['country' => ['iso_code' => 'CA'], 'subdivisions' => [['names' => ['en' => 'Ontario']]], 'city' => ['names' => ['en' => 'Toronto (Old Toronto)']]],
            '8.8.8.8' => ['country' => ['iso_code' => 'US'], 'subdivisions' => [['iso_code' => 'CA', 'names' => ['en' => 'California']]], 'city' => ['names' => ['en' => 'Mountain View']]],
            '10.0.0.1' => null,
        ];
        $lookup = Geo::lookupFrom(new class ($records) {
            public function __construct(private array $records)
            {
            }

            public function get(string $ip): mixed
            {
                return $this->records[$ip] ?? null;
            }
        });
        $this->assertSame(['country' => 'CA', 'region' => 'Ontario', 'city' => 'Toronto'], $lookup('24.114.0.1'));
        $this->assertSame(['country' => 'US', 'region' => 'CA', 'city' => 'Mountain View'], $lookup('8.8.8.8'), 'a code wins when the database has one');
        $this->assertNull($lookup('10.0.0.1'));
        $broken = Geo::lookupFrom(new class () {
            public function get(string $ip): mixed
            {
                throw new \RuntimeException('bad address');
            }
        });
        $this->assertNull($broken('nonsense'));
    }

    public function testARealDatabaseWhenOneIsGiven(): void
    {
        $file = getenv('RUNLIGHT_TEST_MMDB');
        if ($file === false || $file === '') {
            $this->markTestSkipped('Set RUNLIGHT_TEST_MMDB to an MMDB file to read a real database.');
        }
        $reader = Mmdb::open($file);
        $this->assertNotNull($reader->get('8.8.8.8'));
        $this->assertNull($reader->get('127.0.0.1'));
    }
}
