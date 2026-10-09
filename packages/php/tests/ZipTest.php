<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Undefined;
use Runlight\Zip;

/** CSV and ZIP output, byte for byte as the TypeScript SDK writes them. */
final class ZipTest extends TestCase
{
    /** A cell back from its fixture form: {"js": "NaN"} and the like become the values JSON cannot carry. */
    private static function cell(mixed $cell): mixed
    {
        if ($cell instanceof \stdClass && array_keys((array) $cell) === ['js']) {
            return match ($cell->js) {
                'undefined' => Undefined::value(),
                'NaN' => NAN,
                'Infinity' => INF,
                '-Infinity' => -INF,
                '-0' => -0.0,
            };
        }
        return is_array($cell) ? array_map(self::cell(...), $cell) : $cell;
    }

    public function testSpreadsheetFormulasAreDefused(): void
    {
        $this->assertSame("'=SUM(A1),'+1,-2,\"a,b\",\"say \"\"hi\"\"\",12", Zip::csvRow(['=SUM(A1)', '+1', '-2', 'a,b', 'say "hi"', 12]));
    }

    public function testRows(): void
    {
        foreach (Fixture::load('zip', false)->rows as $case) {
            $this->assertSame($case->row, Zip::csvRow([self::cell($case->cell)]), Fixture::label($case->cell));
        }
    }

    public function testCsvs(): void
    {
        foreach (Fixture::load('zip', false)->csvs as $case) {
            $rows = array_map(fn (array $row) => array_map(self::cell(...), $row), $case->rows);
            $this->assertSame($case->csv, Zip::csv($case->header, $rows));
        }
    }

    public function testZips(): void
    {
        foreach (Fixture::load('zip', true)['zips'] as $case) {
            $this->assertSame(bin2hex(base64_decode($case['base64'])), bin2hex(Zip::zip($case['files'], $case['now'])), Fixture::label($case['now']));
        }
    }

    public function testAZipStartsLikeOne(): void
    {
        $bytes = Zip::zip([['name' => 'overview.csv', 'text' => "a\r\n"]], 0);
        $this->assertSame("PK\x03\x04", substr($bytes, 0, 4));
        $this->assertStringContainsString('overview.csv', $bytes);
    }
}
