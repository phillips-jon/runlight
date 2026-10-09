<?php

declare(strict_types=1);

namespace Runlight;

/**
 * A ZIP file of text files, stored without compression, and the CSV that
 * goes in it. Small and plain, so it needs no extension.
 */
final class Zip
{
    /** DOS date and time, as ZIP stores them. @return array{int, int} time and day */
    private static function dosTime(int $ms): array
    {
        $at = (new \DateTimeImmutable('@' . (intdiv($ms, 1000) - ($ms % 1000 < 0 ? 1 : 0))))->setTimezone(new \DateTimeZone('UTC'));
        [$y, $m, $d, $h, $i, $s] = array_map('intval', explode(' ', $at->format('Y n j G i s')));
        return [
            (($h << 11) | ($i << 5) | intdiv($s, 2)) & 0xFFFF,
            ((($y - 1980) << 9) | ($m << 5) | $d) & 0xFFFF,
        ];
    }

    /**
     * The ZIP's bytes. Every entry carries the time `$now` (epoch milliseconds, as the TypeScript's Date),
     * in UTC.
     *
     * @param list<array{name: string, text: string}> $files
     */
    public static function zip(array $files, ?int $now = null): string
    {
        [$time, $day] = self::dosTime($now ?? (int) floor(microtime(true) * 1000));
        $parts = '';
        $central = '';
        $offset = 0;
        foreach ($files as $file) {
            // TextEncoder writes UTF-8, with U+FFFD for anything that is not text.
            $name = Js::scrub($file['name']);
            $data = Js::scrub($file['text']);
            $crc = crc32($data);
            $parts .= pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, 0, $time, $day, $crc, strlen($data), strlen($data), strlen($name), 0) . $name . $data;
            $central .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, 20, 20, 0x0800, 0, $time, $day, $crc, strlen($data), strlen($data), strlen($name), 0, 0, 0, 0, 0, $offset) . $name;
            $offset += 30 + strlen($name) + strlen($data);
        }
        $end = pack('VvvvvVVv', 0x06054b50, 0, 0, count($files), count($files), strlen($central), $offset, 0);
        return $parts . $central . $end;
    }

    /** One CSV row, quoting what needs it; a leading =, +, -, or @ is escaped so a spreadsheet will not run it. */
    public static function csvRow(array $values): string
    {
        return implode(',', array_map(static function (mixed $v): string {
            $s = $v === null || $v instanceof Undefined ? '' : Js::string($v);
            if (preg_match('/^[=+\-@\t\r]/', $s) && !preg_match('/^-?\d+(\.\d+)?$/D', $s)) {
                $s = "'$s";
            }
            return preg_match('/[",\n\r]/', $s) ? '"' . str_replace('"', '""', $s) . '"' : $s;
        }, $values));
    }

    /**
     * @param list<string> $header
     * @param list<list<mixed>> $rows
     */
    public static function csv(array $header, array $rows): string
    {
        return implode("\r\n", [self::csvRow($header), ...array_map(self::csvRow(...), $rows)]) . "\r\n";
    }
}
