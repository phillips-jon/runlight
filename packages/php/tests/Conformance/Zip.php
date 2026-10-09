<?php

declare(strict_types=1);

namespace Runlight\Tests\Conformance;

use Runlight\Body;

/** ZIP reading as http-conformance.ts does it, and writing, for the fake that replays answers. */
final class Zip
{
    /**
     * The files in a ZIP, stored or deflated, by their local headers.
     *
     * @return list<array{name: string, text: string}>
     */
    public static function unzip(string $bytes): array
    {
        $files = [];
        $at = 0;
        $length = strlen($bytes);
        while ($at + 30 <= $length && unpack('V', $bytes, $at)[1] === 0x04034b50) {
            $method = unpack('v', $bytes, $at + 8)[1];
            $size = unpack('V', $bytes, $at + 18)[1];
            $nameLength = unpack('v', $bytes, $at + 26)[1];
            $extra = unpack('v', $bytes, $at + 28)[1];
            $name = Body::utf8(substr($bytes, $at + 30, $nameLength));
            $start = $at + 30 + $nameLength + $extra;
            $data = substr($bytes, $start, $size);
            if ($method === 8) {
                $inflated = @gzinflate($data);
                if ($inflated === false) {
                    throw new \RuntimeException("The ZIP's $name does not inflate");
                }
                $data = $inflated;
            }
            $files[] = ['name' => $name, 'text' => Body::utf8($data)];
            $at = $start + $size;
        }
        return $files;
    }

    /**
     * A ZIP of these files, each deflated or stored as `$deflate` says, with a central directory.
     *
     * @param list<array{name: string, text: string}> $files
     */
    public static function zip(array $files, bool $deflate = true): string
    {
        $local = '';
        $central = '';
        foreach ($files as $file) {
            $data = $deflate ? (string) gzdeflate($file['text']) : $file['text'];
            $method = $deflate ? 8 : 0;
            $crc = crc32($file['text']);
            $offset = strlen($local);
            $local .= pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, $method, 0, 0, $crc, strlen($data), strlen($file['text']), strlen($file['name']), 0)
                . $file['name'] . $data;
            $central .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, 20, 20, 0x0800, $method, 0, 0, $crc, strlen($data), strlen($file['text']), strlen($file['name']), 0, 0, 0, 0, 0, $offset)
                . $file['name'];
        }
        return $local . $central . pack('VvvvvVVv', 0x06054b50, 0, 0, count($files), count($files), strlen($central), strlen($local), 0);
    }
}
