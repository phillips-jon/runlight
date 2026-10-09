<?php

declare(strict_types=1);

namespace Runlight;

/**
 * A reader for MaxMind DB files (the MMDB format that MaxMind's GeoLite2 and
 * DB-IP's free databases use), in plain PHP so location needs no extension or
 * library. It answers what the TypeScript server's mmdb-lib answers: the
 * record for an address, maps as arrays with string keys, or null when the
 * address is not in the database.
 *
 * A database opened from a file is read a page at a time as lookups need it,
 * so a 130 MB city database costs each request a few hundred kilobytes of reads.
 *
 * Format: https://maxmind.github.io/MaxMind-DB/
 */
final class Mmdb
{
    private const METADATA_MARKER = "\xAB\xCD\xEFMaxMind.com";
    /** The metadata sits in the file's last 128 KiB. */
    private const METADATA_MAX = 131072;
    private const PAGE = 4096;
    /** Pages kept from a file at once; a lookup reads a few dozen. */
    private const PAGES_KEPT = 256;

    /** @var array<string, mixed> */
    public readonly array $metadata;
    private readonly int $nodeCount;
    private readonly int $recordSize;
    private readonly int $nodeBytes;
    private readonly int $dataStart;
    private ?int $ipv4Start = null;

    private readonly int $size;
    /** @var array<int, string> pages read from the file, by number */
    private array $pages = [];

    /**
     * @param string $bytes the whole database, or '' with `$handle`
     * @param resource|null $handle an open file to read pages from instead
     */
    public function __construct(private readonly string $bytes, private readonly mixed $handle = null)
    {
        $this->size = $handle === null ? strlen($bytes) : (int) fstat($handle)['size'];
        $tailStart = max(0, $this->size - self::METADATA_MAX);
        $at = strrpos($this->read($tailStart, $this->size - $tailStart), self::METADATA_MARKER);
        if ($at === false) {
            throw new \InvalidArgumentException('Not a MaxMind DB file: no metadata');
        }
        $start = $tailStart + $at + strlen(self::METADATA_MARKER);
        [$metadata] = $this->decode($start, $start);
        if (!is_array($metadata) || !isset($metadata['node_count'], $metadata['record_size'], $metadata['ip_version'])) {
            throw new \InvalidArgumentException('Not a MaxMind DB file: bad metadata');
        }
        $this->metadata = $metadata;
        $this->nodeCount = (int) $metadata['node_count'];
        $this->recordSize = (int) $metadata['record_size'];
        if (!in_array($this->recordSize, [24, 28, 32], true)) {
            throw new \InvalidArgumentException("Unsupported record size {$this->recordSize}");
        }
        $this->nodeBytes = $this->recordSize / 4;
        $this->dataStart = $this->nodeCount * $this->nodeBytes + 16;
    }

    /** A database read from its file as lookups need it. */
    public static function open(string $file): self
    {
        $handle = is_file($file) ? @fopen($file, 'rb') : false;
        if ($handle === false) {
            throw new \RuntimeException("Could not read $file");
        }
        return new self('', $handle);
    }

    /** `$length` bytes from `$at`, fewer at the end of the database. */
    private function read(int $at, int $length): string
    {
        if ($this->handle === null) {
            return substr($this->bytes, $at, $length);
        }
        $out = '';
        $end = min($at + $length, $this->size);
        while ($at < $end) {
            $number = intdiv($at, self::PAGE);
            if (!isset($this->pages[$number])) {
                if (count($this->pages) >= self::PAGES_KEPT) {
                    $this->pages = [];
                }
                fseek($this->handle, $number * self::PAGE);
                $this->pages[$number] = (string) fread($this->handle, self::PAGE);
            }
            $offset = $at - $number * self::PAGE;
            $piece = substr($this->pages[$number], $offset, $end - $at);
            if ($piece === '') {
                break;
            }
            $out .= $piece;
            $at += strlen($piece);
        }
        return $out;
    }

    private function byte(int $at): int
    {
        $byte = $this->handle === null ? ($this->bytes[$at] ?? '') : $this->read($at, 1);
        if ($byte === '') {
            throw new \RuntimeException('Invalid MaxMind DB: read past the end');
        }
        return ord($byte);
    }

    /** The record for an address, or null. Throws \InvalidArgumentException for text that is not an IP address. */
    public function get(string $ip): mixed
    {
        $packed = @inet_pton($ip);
        if ($packed === false) {
            throw new \InvalidArgumentException("Not an IP address: $ip");
        }
        $v6 = strlen($packed) === 16;
        if ($v6 && (int) $this->metadata['ip_version'] === 4) {
            throw new \InvalidArgumentException("An IPv6 address cannot be looked up in an IPv4-only database: $ip");
        }
        $node = $v6 || (int) $this->metadata['ip_version'] === 4 ? 0 : $this->ipv4Start();
        $bits = strlen($packed) * 8;
        for ($i = 0; $i < $bits && $node < $this->nodeCount; $i++) {
            $bit = (ord($packed[$i >> 3]) >> (7 - ($i & 7))) & 1;
            $node = $this->record($node, $bit);
        }
        // The node count itself means no record, and so does a tree that ends before the address does.
        if ($node <= $this->nodeCount) {
            return null;
        }
        [$value] = $this->decode($this->dataStart + $node - $this->nodeCount - 16, $this->dataStart);
        return $value;
    }

    /** IPv4 addresses live under ::/96 in an IPv6 tree: the node 96 left turns down. */
    private function ipv4Start(): int
    {
        if ($this->ipv4Start === null) {
            $node = 0;
            for ($i = 0; $i < 96 && $node < $this->nodeCount; $i++) {
                $node = $this->record($node, 0);
            }
            $this->ipv4Start = $node;
        }
        return $this->ipv4Start;
    }

    private function record(int $node, int $right): int
    {
        $b = $this->read($node * $this->nodeBytes, $this->nodeBytes);
        if (strlen($b) < $this->nodeBytes) {
            throw new \RuntimeException('Invalid MaxMind DB: read past the end');
        }
        switch ($this->recordSize) {
            case 24:
                $at = $right * 3;
                return (ord($b[$at]) << 16) | (ord($b[$at + 1]) << 8) | ord($b[$at + 2]);
            case 28:
                if ($right === 0) {
                    return ((ord($b[3]) & 0xF0) << 20) | (ord($b[0]) << 16) | (ord($b[1]) << 8) | ord($b[2]);
                }
                return ((ord($b[3]) & 0x0F) << 24) | (ord($b[4]) << 16) | (ord($b[5]) << 8) | ord($b[6]);
            default:
                return unpack('N', $b, $right * 4)[1];
        }
    }

    /**
     * Decodes the value at `$at`; pointers are offsets from `$base`.
     *
     * @return array{mixed, int} the value and the offset just past it
     */
    private function decode(int $at, int $base): array
    {
        $control = $this->byte($at++);
        $type = $control >> 5;
        if ($type === 1) {
            // A pointer: up to four more bytes of offset, then the value found there.
            $ss = ($control >> 3) & 3;
            $vvv = $control & 7;
            $pointer = match ($ss) {
                0 => ($vvv << 8) | $this->byte($at),
                1 => (($vvv << 16) | ($this->byte($at) << 8) | $this->byte($at + 1)) + 2048,
                2 => (($vvv << 24) | ($this->byte($at) << 16) | ($this->byte($at + 1) << 8) | $this->byte($at + 2)) + 526336,
                default => self::unsigned($this->read($at, 4)),
            };
            [$value] = $this->decode($base + $pointer, $base);
            return [$value, $at + $ss + 1];
        }
        if ($type === 0) {
            $type = 7 + $this->byte($at++);
        }
        $size = $control & 0x1F;
        if ($size >= 29) {
            $extra = $size - 28;
            $n = 0;
            for ($i = 0; $i < $extra; $i++) {
                $n = ($n << 8) | $this->byte($at + $i);
            }
            $size = [29 => 29, 30 => 285, 31 => 65821][$size] + $n;
            $at += $extra;
        }
        switch ($type) {
            case 2: // UTF-8 string
                return [$this->read($at, $size), $at + $size];
            case 3: // double
                return [unpack('E', $this->read($at, 8))[1], $at + 8];
            case 4: // bytes
                return [$this->read($at, $size), $at + $size];
            case 5: // uint16
            case 6: // uint32
                return [self::unsigned($this->read($at, $size)), $at + $size];
            case 7: // map
                $map = [];
                for ($i = 0; $i < $size; $i++) {
                    [$key, $at] = $this->decode($at, $base);
                    [$value, $at] = $this->decode($at, $base);
                    $map[(string) $key] = $value;
                }
                return [$map, $at];
            case 8: // int32
                $n = self::unsigned($this->read($at, $size));
                if ($size === 4 && $n >= 0x80000000) {
                    $n -= 0x100000000;
                }
                return [$n, $at + $size];
            case 9: // uint64
            case 10: // uint128
                return [self::big($this->read($at, $size)), $at + $size];
            case 11: // array
                $list = [];
                for ($i = 0; $i < $size; $i++) {
                    [$list[], $at] = $this->decode($at, $base);
                }
                return [$list, $at];
            case 14: // boolean, its value in the size
                return [$size !== 0, $at];
            case 15: // float
                return [unpack('G', $this->read($at, 4))[1], $at + 4];
            default:
                throw new \RuntimeException("Invalid MaxMind DB: unknown data type $type");
        }
    }

    private static function unsigned(string $bytes): int
    {
        $n = 0;
        foreach (str_split($bytes) as $byte) {
            $n = ($n << 8) | ord($byte);
        }
        return $n;
    }

    /** An unsigned integer of up to 16 bytes: an int when it fits, else its decimal digits. */
    private static function big(string $bytes): int|string
    {
        $bytes = ltrim($bytes, "\0");
        if (strlen($bytes) < 8 || (strlen($bytes) === 8 && ord($bytes[0]) < 0x80)) {
            return self::unsigned($bytes);
        }
        $digits = '0';
        foreach (str_split($bytes) as $byte) {
            // digits = digits * 256 + byte, in decimal text.
            $carry = ord($byte);
            $out = '';
            for ($i = strlen($digits) - 1; $i >= 0; $i--) {
                $n = (int) $digits[$i] * 256 + $carry;
                $out = ($n % 10) . $out;
                $carry = intdiv($n, 10);
            }
            while ($carry > 0) {
                $out = ($carry % 10) . $out;
                $carry = intdiv($carry, 10);
            }
            $digits = ltrim($out, '0') ?: '0';
        }
        return $digits;
    }
}
